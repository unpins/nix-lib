//===-- unpin_musl.cpp - on-demand musl sysroot + driver front ------------===//
//
// Ports zig 0.16's musl recipe (src/libs/musl.zig) to drive the in-tree clang
// directly: the curated source list + per-arch override rule + CFLAGS live in
// musl_sources.inc / addCcArgs() below; the engine is clang (re-exec'd as
// `self` per source). The musl sources + headers are read from the in-binary
// VFS at VROOT/libc/... ; the built libc.a + CRTs land in an on-disk cache
// (a build product, not the embedded tree). Linux/de-risk only for now.
//
//===----------------------------------------------------------------------===//

#include "unpin_musl.h"
#include "unpin_clang_vfs.h" // unpin::VROOT
#include "unpin_vfs_core.h"  // unpin_vfs_count / unpin_vfs_entry

#include "llvm/ADT/StringExtras.h"
#include "llvm/ADT/StringRef.h"
#include "llvm/ADT/StringSet.h"
#include "llvm/Support/FileSystem.h"
#include "llvm/Support/Path.h"
#include "llvm/Support/Program.h"
#include "llvm/Support/raw_ostream.h"
#include "llvm/Support/xxhash.h"

// Recipe/version stamp baked by nix (postPatch generates unpin_build_tag.h over
// the recipe sources). Optional so the file still builds standalone; the cache
// then falls back to "dev". See cache key (Variant) below.
#if defined(__has_include)
#  if __has_include("unpin_build_tag.h")
#    include "unpin_build_tag.h"
#  endif
#endif
#ifndef UNPIN_CACHE_TAG
#define UNPIN_CACHE_TAG "dev"
#endif

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <string>
#include <sys/file.h>
#include <thread>
#include <unistd.h>
#include <vector>

#ifdef __APPLE__
#include <cstdint>
#include <mach-o/dyld.h> // _NSGetExecutablePath — macOS has no /proc/self/exe
#endif

using namespace llvm;

namespace {

#include "musl_sources.inc"
#include "builtins_sources.inc"
#include "cxx_sources.inc"
#include "mingw_sources.inc"

// --- small helpers ---------------------------------------------------------

std::string vroot() { return std::string(unpin::VROOT); }
std::string libcRoot() { return vroot() + "/libc"; } // VROOT/libc
// VROOT/compiler-rt/builtins — the embedded compiler-rt builtins source tree.
std::string builtinsRoot() { return vroot() + "/compiler-rt/builtins"; }
// VROOT/cxx — the embedded libc++ / libc++abi / libunwind source trees (M4),
// laid out as cxx/{libcxx,libcxxabi,libunwind} + the llvm-libc shim cxx/libc.
std::string cxxRoot() { return vroot() + "/cxx"; }
// VROOT/cxx/win — holds the Windows __config_site (cxx_config_site_win.h). Placed
// on the include path before cxx/libcxx/include for Windows C++ compiles so
// `#include <__config_site>` picks the Windows knobs over the musl ones.
std::string winCxxConfigRoot() { return cxxRoot() + "/win"; }
// VROOT/cxx/darwin — holds the macOS __config_site (cxx_config_site_darwin.h),
// placed on the include path before cxx/libcxx/include for darwin C++ compiles
// (musl=0, no tzdb; pthread threads kept).
std::string darwinCxxConfigRoot() { return cxxRoot() + "/darwin"; }
// VROOT/libc/mingw — the embedded mingw-w64 runtime tree (crt/, gdtoa/, math/,
// misc/, stdio/, libsrc/, winpthreads/, lib64/+lib-common/ .def, def-include/).
std::string mingwRoot() { return libcRoot() + "/mingw"; }
// VROOT/libc/include/any-windows-any — the Windows + UCRT user-facing headers
// (stdio.h/windows.h/winsock2.h/_mingw.h/…), shared by all Windows arches.
std::string winHeaders() { return libcRoot() + "/include/any-windows-any"; }
// VROOT/libc/include/any-darwin-any — the macOS libc / POSIX / Darwin C headers
// (stdio.h/unistd.h/pthread.h/mach/*/…), vendored from Apple's open-source SDK;
// one arch-independent set for every macOS arch (no per-arch companion dir).
std::string darwinHeaders() { return libcRoot() + "/include/any-darwin-any"; }
// The libSystem TAPI stub (text-based .dylib) — a single umbrella .tbd that
// inlines all reexported sub-libs' symbols (libsystem_c/m/pthread/…). On darwin
// this IS the libc: linking -lSystem against it resolves the whole C/POSIX
// surface, so there is no libc.a to build (unlike musl). Lib-relative VFS path.
const char *const kDarwinTbdRel = "libc/darwin/libSystem.tbd";

bool vfsHas(const std::string &rel) {
  return unpin_vfs_find(rel.c_str(), rel.size()) >= 0;
}

// Materialise a VFS entry (lib-relative path) to a real on-disk file. The clang
// half reads the embedded tree through its llvm::vfs overlay, but external tools
// in the link step — ld64.lld reading the libSystem.tbd stub — read inputs from
// the real filesystem, so those assets must be copied out first.
bool copyVfsFile(const char *rel, const std::string &dest) {
  long idx = unpin_vfs_find(rel, std::strlen(rel));
  if (idx < 0) {
    errs() << "unpin-darwin: VFS missing " << rel << "\n";
    return false;
  }
  uint64_t len = 0;
  const void *data = unpin_vfs_data((size_t)idx, &len);
  if (!data) {
    errs() << "unpin-darwin: VFS read failed " << rel << "\n";
    return false;
  }
  std::error_code ec;
  raw_fd_ostream o(dest, ec);
  if (ec) {
    errs() << "unpin-darwin: write " << dest << ": " << ec.message() << "\n";
    return false;
  }
  o.write((const char *)data, (size_t)len);
  o.close();
  return !o.has_error();
}

std::string selfExe() {
#ifdef __APPLE__
  // macOS has no /proc/self/exe. Resolve our own image path via the dyld API,
  // then canonicalize it (the path is used to re-exec self as clang and to
  // symlink self as ld64.lld, so it must be a real, openable path — not the
  // Linux magic path). _NSGetExecutablePath can return an un-canonical path
  // (symlinks/".."); real_path cleans it, with the raw path as a fallback.
  char buf[4096];
  uint32_t bufsize = sizeof(buf);
  if (_NSGetExecutablePath(buf, &bufsize) != 0)
    return ""; // path > buffer — caller's sysroot/re-exec will fail loudly
  SmallString<256> Real;
  if (sys::fs::real_path(buf, Real))
    return std::string(buf); // real_path errored — raw path is still openable
  return std::string(Real);
#else
  // The reader/VFS already proves /proc/self/exe is the binary; reuse it as
  // the re-exec target. Resolve the symlink so a stable path is used.
  SmallString<256> Buf;
  if (sys::fs::real_path("/proc/self/exe", Buf))
    return "/proc/self/exe"; // fall back to the magic path
  return std::string(Buf);
#endif
}

std::string cacheBase() {
  if (const char *x = ::getenv("XDG_CACHE_HOME"); x && x[0])
    return std::string(x) + "/unpin-llvm";
  if (const char *h = ::getenv("HOME"); h && h[0])
    return std::string(h) + "/.cache/unpin-llvm";
  return "/tmp/unpin-llvm";
}

// A cache-key "manifest", in the spirit of zig's Cache.Manifest: the axes that
// change the built libc/libc++/builtins for a given triple. The recipe/version
// stamp UNPIN_CACHE_TAG is folded into the hash (so a new binary never reuses an
// old library — the version-safety property); cpuFlags/fast/pic are the
// per-compile codegen axes lifted from the user's command line. Sanitizers and
// single-threaded are deferred (they need instrumented runtimes we don't build).
struct Variant {
  std::string triple;                // as given (-target)
  std::vector<std::string> cpuFlags; // -march=/-mcpu=/-mtune=/-mabi= (last wins)
  bool fast = false;                 // opt class: fast (-O2/-O3) vs small (-Os)
  bool pic = false;  // build the libc/runtime objects position-independent
                     // (-fPIC/-fPIE, or implied by a -pie link). HASH axis.
  bool pie = false;  // final link is static-PIE (-pie) → pick rcrt1.o over
                     // crt1.o. NOT a hash axis: all three CRTs are always built,
                     // and a -fPIC libc is identical with or without -pie, so
                     // pie shares the pic variant's cache entry.
  bool lto = false;  // build the libc objects as LLVM BITCODE (-flto) so the
                     // consuming link folds libc into its whole-program LTO —
                     // uniform with every other engine object (standardization)
                     // and lets LTO inline/specialize hot libc paths (perf).
                     // Follows the link's own -flto: real engine links carry it
                     // (→ bitcode); autoconf conftest probes drop it (→ native,
                     // honest + fast). HASH axis: both libc.a's coexist in cache.
};

// 16-hex cache-dir token for a variant. Non-crypto xxh3 is plenty for a cache
// key; UNPIN_CACHE_TAG makes any recipe-source change invalidate every variant.
std::string variantHash(const Variant &V) {
  std::string s = UNPIN_CACHE_TAG;
  auto sep = [&] { s.push_back('\0'); };
  sep();
  s += V.triple;
  sep();
  for (auto &f : V.cpuFlags) { s += f; s.push_back(' '); }
  sep();
  s += V.fast ? "fast" : "small";
  sep();
  s += V.pic ? "pic" : "nopic";
  sep();
  s += V.lto ? "lto" : "nolto";
  uint64_t h = xxh3_64bits(
      ArrayRef<uint8_t>(reinterpret_cast<const uint8_t *>(s.data()), s.size()));
  return utohexstr(h, /*LowerCase=*/true, /*Width=*/16);
}

// Append a variant's codegen flags (cpu + PIC) to a recipe compile job. The opt
// level is handled per call-site because each library sets its own -O base.
void appendCpuPic(std::vector<std::string> &a, const Variant &V) {
  for (auto &f : V.cpuFlags) a.push_back(f);
  if (V.pic) a.push_back("-fPIC");
}

// musl arch folder name (zig std.zig.target.muslArchName), keyed off the arch
// token of the triple. Covers the catalog arches; unknown -> token as-is.
std::string muslArchName(StringRef archTok) {
  if (archTok == "aarch64" || archTok == "aarch64_be" || archTok == "arm64")
    return "aarch64"; // arm64 = Apple's spelling for the macOS aarch64 target
  if (archTok == "x86_64") return "x86_64";
  if (archTok == "riscv64") return "riscv64";
  if (archTok == "riscv32") return "riscv32";
  if (archTok == "i386" || archTok == "i486" || archTok == "i586" ||
      archTok == "i686" || archTok == "x86")
    return "i386";
  if (archTok == "arm" || archTok == "armv7" || archTok.starts_with("armv") ||
      archTok == "thumb")
    return "arm";
  if (archTok == "powerpc64le" || archTok == "powerpc64") return "powerpc64";
  if (archTok == "powerpc") return "powerpc";
  if (archTok == "mips64el" || archTok == "mips64") return "mips64";
  if (archTok == "mipsel" || archTok == "mips") return "mips";
  if (archTok == "s390x") return "s390x";
  if (archTok == "loongarch64") return "loongarch64";
  return std::string(archTok);
}

// macOS deployment-target flag to assume when the user's triple carries no
// explicit version (…-apple-macos vs …-apple-macos14). TLS (__thread, used by
// libc++abi's cxa_thread_atexit) and many libc++ features need a modern floor;
// without a version clang defaults to a very old macOS where __thread is
// rejected ("thread-local storage is not supported"). Pick a TLS-capable
// baseline per arch (arm64 starts at 11.0). Returns "" if the triple already
// pins a version (respect the user's choice).
std::string darwinVersionMinFlag(const std::string &triple,
                                 const std::string &muslArch) {
  StringRef t(triple);
  for (const char *os : {"macosx", "macos", "darwin"}) {
    size_t p = t.find(os);
    if (p != StringRef::npos) {
      size_t e = p + std::strlen(os);
      if (e < t.size() && llvm::isDigit(t[e])) return ""; // versioned already
    }
  }
  return std::string("-mmacosx-version-min=") +
         (muslArch == "aarch64" ? "11.0" : "10.13");
}

// Arch token zig uses to name the GENERATED header dir (include/<tok>-linux-musl)
// — std.zig.target arch name, NOT the musl folder name. They coincide for every
// catalog arch EXCEPT 32-bit x86: musl's folder is "i386" but zig names the
// generated headers "x86" (e.g. include/x86-linux-musl). Keep this the single
// source of truth for the header triple so i686 finds its headers.
std::string headerArchName(StringRef archTok) {
  if (archTok == "i386" || archTok == "i486" || archTok == "i586" ||
      archTok == "i686" || archTok == "x86")
    return "x86";
  return muslArchName(archTok);
}

// Linux kernel-UAPI header dir token (zig's <karch>-linux-any), which differs
// from muslArch: x86_64/i386 share "x86", riscv32/64 share "riscv", etc.
std::string kernelArchName(StringRef muslArch) {
  if (muslArch == "x86_64" || muslArch == "i386") return "x86";
  if (muslArch == "riscv64" || muslArch == "riscv32") return "riscv";
  if (muslArch == "powerpc64") return "powerpc";
  if (muslArch == "mips64") return "mips";
  if (muslArch == "loongarch64") return "loongarch";
  return std::string(muslArch); // aarch64, arm, powerpc, s390x, mips, m68k, …
}

bool isArchName(StringRef name) {
  static const char *const kArchNames[] = {
      "aarch64", "arm",     "generic",   "hexagon",     "i386",
      "loongarch64", "m68k", "microblaze", "mips",        "mips64",
      "mipsn32", "or1k",    "powerpc",   "powerpc64",   "riscv32",
      "riscv64", "s390x",   "sh",        "x32",         "x86_64"};
  for (const char *a : kArchNames)
    if (name == a) return true;
  return false;
}

bool isTime32Arch(StringRef muslArch) {
  for (const char *a : kTime32CompatArchList)
    if (muslArch == a) return true;
  return false;
}

bool isO3Path(StringRef p) {
  return p.starts_with("musl/src/string/") || p.starts_with("musl/src/internal/");
}

// zig addCcArgs(): the per-source musl CFLAGS, with includes pointing at the
// embedded VFS tree. `headerTriple` = "<archHeaders>-linux-musl".
void addCcArgs(std::vector<std::string> &a, const std::string &muslArch,
               const std::string &headerTriple, bool wantO3,
               const Variant &V) {
  std::string L = libcRoot();
  const char *base[] = {"-std=c99",
                        "-ffreestanding",
                        "-fexcess-precision=standard",
                        "-frounding-math",
                        "-ffp-contract=off",
                        "-fno-strict-aliasing",
                        "-Wa,--noexecstack",
                        "-D_XOPEN_SOURCE=700"};
  for (const char *f : base) a.push_back(f);
  auto I = [&](const std::string &d) { a.push_back("-I"); a.push_back(d); };
  I(L + "/musl/arch/" + muslArch);
  I(L + "/musl/arch/generic");
  I(L + "/musl/src/include");
  I(L + "/musl/src/internal");
  I(L + "/musl/include");
  I(L + "/include/" + headerTriple);
  I(L + "/include/generic-musl");
  // Opt base: the perf-critical string/internal sources keep -O3; otherwise the
  // variant's opt class picks -O2 (fast) or -Os (small, the default).
  a.push_back(wantO3 ? "-O3" : (V.fast ? "-O2" : "-Os"));
  a.push_back("-Qunused-arguments");
  a.push_back("-w");
  // build_crt_file opts shared by all musl objects.
  a.push_back("-fomit-frame-pointer");
  a.push_back("-fno-builtin");
  appendCpuPic(a, V);
}

int runSelf(const std::string &self, const std::vector<std::string> &args) {
  std::vector<StringRef> argv;
  argv.reserve(args.size());
  for (auto &s : args) argv.push_back(s);
  std::string err;
  int rc = sys::ExecuteAndWait(self, argv, /*Env=*/std::nullopt, /*Redirects=*/{},
                               /*SecondsToWait=*/0, /*MemoryLimit=*/0, &err);
  if (rc != 0 && !err.empty())
    errs() << "unpin-musl: exec failed: " << err << "\n";
  return rc;
}

// Compile the selected musl sources -> objDir/*.o (parallel), then `llvm-ar`.
bool buildLibc(const std::string &self, const std::string &triple,
               const std::string &muslArch, const std::string &headerTriple,
               const std::string &objDir, const std::string &outLib,
               const Variant &V) {
  // Source selection straight from the EMBEDDED musl tree, replicating musl's
  // own Makefile (SRC_DIRS = src/* src/malloc/mallocng crt ldso COMPAT; an
  // arch-subdir <stem>.{s,S,c} replaces the generic <stem>.c). We enumerate the
  // VFS rather than carry zig's curated subset: that subset omitted whole
  // subsystems zig provides differently (no malloc/, pruned math/string/…), so
  // only printf-class programs linked. oldmalloc is the unselected MALLOC_DIR
  // alternative (musl ships mallocng), so it is skipped. crt/ and the top-level
  // ldso/ are not under src/ (CRTs built separately; the dynamic linker is not
  // in a static libc.a), so walking src/ is exactly musl's LIBC_OBJS set.
  bool t32 = isTime32Arch(muslArch);
  StringSet<> table;
  std::vector<std::string> cand;
  size_t nodes = unpin_vfs_count();
  for (size_t i = 0; i < nodes; ++i) {
    const char *p = nullptr;
    size_t plen = 0;
    int isDir = 0;
    uint64_t sz = 0;
    if (unpin_vfs_entry(i, &p, &plen, &isDir, &sz) != 0 || isDir) continue;
    StringRef rel(p, plen);
    if (!rel.consume_front("libc/")) continue; // VFS paths are lib-relative
    bool inSrc = rel.starts_with("musl/src/");
    bool inCompat = t32 && rel.starts_with("musl/compat/");
    if (!inSrc && !inCompat) continue;
    if (!rel.ends_with(".c") && !rel.ends_with(".s") && !rel.ends_with(".S"))
      continue;
    if (rel.starts_with("musl/src/malloc/oldmalloc/")) continue;
    table.insert(rel);
    cand.push_back(rel.str()); // VFS nodes are pre-sorted → deterministic order
  }

  std::vector<std::string> sel;
  StringSet<> seen;
  auto consider = [&](StringRef f) {
    StringRef dir = sys::path::parent_path(f);
    StringRef stem = sys::path::stem(f);
    StringRef dirbase = sys::path::filename(dir);
    bool archSpecific = false;
    if (isArchName(dirbase)) {
      if (dirbase != muslArch) return;
      archSpecific = true;
    }
    if (!archSpecific) {
      for (const char *ext : {".s", ".S", ".c"}) {
        std::string ov = (dir + "/" + muslArch + "/" + stem + ext).str();
        if (table.count(ov)) return;
      }
    }
    if (!seen.insert(f).second) return;
    sel.push_back(f.str());
  };
  for (auto &f : cand) consider(f);

  if (sys::fs::create_directories(objDir)) {
    errs() << "unpin-musl: mkdir " << objDir << " failed\n";
    return false;
  }

  // Compile in parallel; UNPIN_NO_FRONT silences the front in the re-execs.
  ::setenv("UNPIN_NO_FRONT", "1", 1);
  std::atomic<size_t> next{0};
  std::atomic<bool> ok{true};
  std::vector<std::string> objs(sel.size());
  unsigned n = std::max(1u, std::thread::hardware_concurrency());
  if (n > 8) n = 8;
  std::vector<std::thread> pool;
  for (unsigned w = 0; w < n; ++w) {
    pool.emplace_back([&] {
      for (;;) {
        size_t i = next.fetch_add(1);
        if (i >= sel.size() || !ok.load()) return;
        std::string obj = objDir + "/" + utostr(i) + ".o";
        objs[i] = obj;
        std::vector<std::string> args = {"clang"};
        addCcArgs(args, muslArch, headerTriple, isO3Path(sel[i]), V);
        // Bitcode libc: -flto makes each object LLVM bitcode so the consuming
        // engine link folds libc into its whole-program LTO. asm/.s/.S sources and
        // the CRTs (buildCrt) stay native — LTO of CRTs is unsupported (llvm#43698)
        // and the linker resolves asm↔bitcode at the final link regardless.
        if (V.lto && StringRef(sel[i]).ends_with(".c")) args.push_back("-flto");
        args.push_back("-target");
        args.push_back(triple);
        args.push_back("-c");
        args.push_back(libcRoot() + "/" + sel[i]);
        args.push_back("-o");
        args.push_back(obj);
        if (runSelf(self, args) != 0) {
          errs() << "unpin-musl: compile failed: " << sel[i] << "\n";
          ok.store(false);
          return;
        }
      }
    });
  }
  for (auto &t : pool) t.join();
  ::unsetenv("UNPIN_NO_FRONT");
  if (!ok.load()) return false;

  // Archive: llvm-ar rcs libc.a <objs...>
  std::vector<std::string> ar = {"llvm-ar", "rcs", outLib};
  for (auto &o : objs) ar.push_back(o);
  return runSelf(self, ar) == 0;
}

bool buildCrt(const std::string &self, const std::string &triple,
              const std::string &muslArch, const std::string &headerTriple,
              const char *srcRel, const std::string &outObj, bool pic,
              const Variant &V) {
  ::setenv("UNPIN_NO_FRONT", "1", 1);
  std::vector<std::string> args = {"clang"};
  addCcArgs(args, muslArch, headerTriple, /*wantO3=*/false, V);
  args.push_back("-DCRT");
  if (pic) args.push_back("-fPIC");
  args.push_back("-target");
  args.push_back(triple);
  args.push_back("-c");
  args.push_back(libcRoot() + "/" + srcRel);
  args.push_back("-o");
  args.push_back(outObj);
  int rc = runSelf(self, args);
  ::unsetenv("UNPIN_NO_FRONT");
  return rc == 0;
}

// --- compiler-rt builtins (M3) --------------------------------------------

// Assemble the per-arch builtins source list (relative to builtinsRoot) and
// apply the CMake filter_builtin_sources override rule: an arch-subdir
// <stem>.{c,S} shadows the top-level generic <stem>.c.
void collectBuiltinSources(StringRef muslArch, std::vector<std::string> &out,
                           bool isWin = false, bool isDarwin = false) {
  std::vector<std::string> all;
  for (const char *f : kBuiltinsGeneric) all.push_back(f);
  // GENERIC_TF = the 128-bit quad-float (tf_float) soft-float routines. Skip them
  // where `long double` is not a 128-bit quad type, so the compiler never emits
  // __*tf* calls and the routines are dead weight (and miscompile): powerpc64
  // (64-bit musl long double — see below) and macOS arm64 (long double == double,
  // 64-bit). compiler-rt's int_types.h enables CRT_HAS_TF_MODE for those arches
  // WITHOUT CRT_HAS_IEEE_TF, so addtf3.c & friends reference undefined
  // absMask/infRep and fail to compile. macOS x86_64 keeps the 80-bit set below.
  bool noQuad = (muslArch == "powerpc64") || (isDarwin && muslArch == "aarch64");
  if (!noQuad)
    for (const char *f : kBuiltinsGenericTF) all.push_back(f);
  // Windows x86 needs chkstk (stack-probe for frames > 1 page); musl never does,
  // so chkstk.S is omitted from the generic x86 sets and added here per-OS. The
  // 80-bit/TF routines pulled below self-guard to empty TUs on Windows (long
  // double == double there), so reusing the x86_64/i386 selection is harmless.
  if (isWin && muslArch == "x86_64") {
    all.push_back("i386/chkstk.S");
    all.push_back("x86_64/chkstk.S");
  } else if (isWin && muslArch == "i386") {
    all.push_back("i386/chkstk.S");
  }
  if (muslArch == "x86_64") {
    for (const char *f : kBuiltins80Bit) all.push_back(f);
    for (const char *f : kBuiltinsX86_64) all.push_back(f);
  } else if (muslArch == "i386") {
    for (const char *f : kBuiltinsI386) all.push_back(f);
    for (const char *f : kBuiltins80Bit) all.push_back(f); // 80-bit XF long double
  } else if (muslArch == "aarch64") {
    for (const char *f : kBuiltinsAArch64) all.push_back(f);
  } else if (muslArch == "arm") {
    for (const char *f : kBuiltinsArm) all.push_back(f);
  } else if (muslArch == "riscv64") {
    for (const char *f : kBuiltinsRiscv64) all.push_back(f);
  }
  // else (e.g. powerpc64): GENERIC only (GENERIC_TF skipped above — 64-bit musl
  // long double, no quad type). Enough for integer/FP code (ppc64le has hw 64-bit
  // divide; double soft-float lives in GENERIC). The GCC double-double ppc/*.c
  // helpers are not ported (unused with a 64-bit long double).

  StringSet<> shadowed; // top-level generic <stem>.c shadowed by an arch file
  for (auto &f : all)
    if (StringRef(f).contains('/'))
      shadowed.insert((sys::path::stem(sys::path::filename(f)) + ".c").str());
  for (auto &f : all) {
    // clear_cache.c pulls <linux/unistd.h> (Linux kernel headers we don't ship)
    // on RISC-V for the __riscv_flush_icache syscall; that icache-flush fallback
    // is only reached by JITs/trampolines, never by AOT-compiled code.
    if (muslArch == "riscv64" && StringRef(f) == "clear_cache.c") continue;
    if (StringRef(f).contains('/') || !shadowed.count(f))
      out.push_back(f);
  }
}

// Compile the selected builtins -> objDir/*.o (parallel) + the aarch64
// outline-atomics helpers, then `llvm-ar` into libclang_rt.builtins.a. Unlike
// the musl objects, these compile with the FRONT ACTIVE (no UNPIN_NO_FRONT) so
// it injects -resource-dir + the public musl -isystem they need; we add only
// the builtins source dir (for "assembly.h") + the compiler-rt build flags.
bool buildBuiltins(const std::string &self, const std::string &triple,
                   const std::string &muslArch, const std::string &objDir,
                   const std::string &outLib, const Variant &V,
                   bool isWin = false, bool isDarwin = false) {
  std::vector<std::string> sel;
  collectBuiltinSources(muslArch, sel, isWin, isDarwin);
  std::string root = builtinsRoot();

  struct Job {
    std::string src;
    std::vector<std::string> extra;
  };
  std::vector<Job> jobs;
  for (auto &s : sel) jobs.push_back({root + "/" + s, {}});
  // AArch64 outline atomics: lse.S × (pattern,size,model), skipping size 16
  // for everything but `cas` (CMakeLists 642-662).
  if (muslArch == "aarch64") {
    for (const char *pat : kOutlineAtomicPats)
      for (int size : kOutlineAtomicSizes)
        for (int model : kOutlineAtomicModels) {
          if (StringRef(pat) != "cas" && size == 16) continue;
          jobs.push_back({root + "/aarch64/lse.S",
                          {std::string("-DL_") + pat, "-DSIZE=" + utostr(size),
                           "-DMODEL=" + utostr(model)}});
        }
  }

  if (sys::fs::create_directories(objDir)) {
    errs() << "unpin-musl: mkdir " << objDir << " failed\n";
    return false;
  }

  std::atomic<size_t> next{0};
  std::atomic<bool> ok{true};
  std::vector<std::string> objs(jobs.size());
  unsigned n = std::max(1u, std::thread::hardware_concurrency());
  if (n > 8) n = 8;
  std::vector<std::thread> pool;
  for (unsigned w = 0; w < n; ++w) {
    pool.emplace_back([&] {
      for (;;) {
        size_t i = next.fetch_add(1);
        if (i >= jobs.size() || !ok.load()) return;
        std::string obj = objDir + "/" + utostr(i) + ".o";
        objs[i] = obj;
        StringRef src(jobs[i].src);
        bool isCpp = src.ends_with(".cpp");
        bool isAsm = src.ends_with(".S") || src.ends_with(".s");
        std::vector<std::string> args = {"clang", "-I", root};
        if (isCpp) args.push_back("-std=c++17");
        else if (!isAsm) args.push_back("-std=c11");
        for (const char *f : {"-fno-builtin", "-fomit-frame-pointer",
                              "-fvisibility=hidden", "-Qunused-arguments", "-w"})
          args.push_back(f);
        if (!isAsm) args.push_back(V.fast ? "-O2" : "-Os");
        appendCpuPic(args, V);
        for (auto &e : jobs[i].extra) args.push_back(e);
        args.push_back("-target");
        args.push_back(triple);
        args.push_back("-c");
        args.push_back(jobs[i].src);
        args.push_back("-o");
        args.push_back(obj);
        if (runSelf(self, args) != 0) {
          errs() << "unpin-musl: builtins compile failed: " << jobs[i].src << "\n";
          ok.store(false);
          return;
        }
      }
    });
  }
  for (auto &t : pool) t.join();
  if (!ok.load()) return false;

  std::vector<std::string> ar = {"llvm-ar", "rcs", outLib};
  for (auto &o : objs) ar.push_back(o);
  return runSelf(self, ar) == 0;
}

// --- C++ runtime: libc++ / libc++abi / libunwind (M4) ----------------------

// Base flags every C++-runtime TU needs: embedded clang builtins + the public C
// headers (musl for linux, any-windows-any for mingw), no host include leakage.
// Compiled with UNPIN_NO_FRONT (like buildLibc), so the front injects nothing —
// we supply the full environment.
void addCxxBaseArgs(std::vector<std::string> &a, const std::string &muslArch,
                    const std::string &headerTriple, bool isWin = false,
                    bool isDarwin = false) {
  a.push_back("-resource-dir");
  a.push_back(vroot() + "/clang-resource");
  a.push_back("-nostdlibinc");
  if (isWin) {
    // The Win32 + UCRT user headers; the target's own _WIN32/__SEH__ defines
    // drive the platform conditionals in the runtime sources.
    a.push_back("-isystem");
    a.push_back(winHeaders());
    return;
  }
  if (isDarwin) {
    // The clang builtin headers FIRST, then the macOS libc / Darwin headers.
    // Apple's <stddef.h> delegates size_t/ptrdiff_t to the compiler (uses them
    // before defining), so clang's builtin <stddef.h> must precede it in the
    // -isystem group: else libc++'s <stddef.h> wrapper #include_next's straight
    // to Apple's and size_t is undefined. (musl/mingw stddef are self-contained,
    // so only darwin needs this.) The target's __APPLE__/__MACH__ defines drive
    // the platform conditionals in the runtime sources.
    a.push_back("-isystem");
    a.push_back(vroot() + "/clang-resource/include");
    a.push_back("-isystem");
    a.push_back(darwinHeaders());
    return;
  }
  a.push_back("-isystem");
  a.push_back(libcRoot() + "/include/" + headerTriple);
  a.push_back("-isystem");
  a.push_back(libcRoot() + "/include/generic-musl");
  a.push_back("-isystem");
  a.push_back(libcRoot() + "/include/" + kernelArchName(muslArch) + "-linux-any");
  a.push_back("-isystem");
  a.push_back(libcRoot() + "/include/any-linux-any");
}

// Compile a batch of clang jobs (each a full argv ending at "-c <src>") in
// parallel into objDir/<i>.o, then `llvm-ar rcs` them into outLib.
bool buildArchive(const std::string &self,
                  const std::vector<std::vector<std::string>> &jobs,
                  const std::string &objDir, const std::string &outLib) {
  if (sys::fs::create_directories(objDir)) {
    errs() << "unpin-musl: mkdir " << objDir << " failed\n";
    return false;
  }
  std::atomic<size_t> next{0};
  std::atomic<bool> ok{true};
  std::vector<std::string> objs(jobs.size());
  unsigned n = std::min(8u, std::max(1u, std::thread::hardware_concurrency()));
  std::vector<std::thread> pool;
  for (unsigned w = 0; w < n; ++w) {
    pool.emplace_back([&] {
      for (;;) {
        size_t i = next.fetch_add(1);
        if (i >= jobs.size() || !ok.load()) return;
        std::string obj = objDir + "/" + utostr(i) + ".o";
        objs[i] = obj;
        std::vector<std::string> args = jobs[i];
        args.push_back("-o");
        args.push_back(obj);
        if (runSelf(self, args) != 0) {
          errs() << "unpin-musl: cxx compile failed: " << jobs[i].back() << "\n";
          ok.store(false);
          return;
        }
      }
    });
  }
  for (auto &t : pool) t.join();
  if (!ok.load()) return false;
  std::vector<std::string> ar = {"llvm-ar", "rcs", outLib};
  for (auto &o : objs) ar.push_back(o);
  return runSelf(self, ar) == 0;
}

// Build libunwind.a + libc++abi.a + libc++.a for `triple` into libDir. The
// recipe (file lists, flags) is zig 0.16's libcxx.zig / libunwind.zig; the
// config knobs live in the embedded __config_site so __config is upstream-clean.
bool buildCxxRuntime(const std::string &self, const std::string &triple,
                     const std::string &muslArch,
                     const std::string &headerTriple, const std::string &libDir,
                     const std::string &objBase, const Variant &V,
                     bool isWin = false, bool isDarwin = false) {
  ::setenv("UNPIN_NO_FRONT", "1", 1);
  std::string cx = cxxRoot();
  auto target = [&](std::vector<std::string> &a) {
    a.push_back("-target");
    a.push_back(triple);
    // Compiled with UNPIN_NO_FRONT, so the deployment target the front would add
    // is set here: libc++abi's cxa_thread_atexit uses __thread (needs a TLS-
    // capable macOS floor).
    if (isDarwin) {
      std::string vm = darwinVersionMinFlag(triple, muslArch);
      if (!vm.empty()) a.push_back(vm);
    }
  };
  // The platform __config_site (cxx/win for Windows, cxx/darwin for macOS) must
  // precede cxx/libcxx/include on the include path so `#include <__config_site>`
  // finds the platform knobs instead of the musl copy in libcxx/include.
  auto addConfigSite = [&](std::vector<std::string> &a) {
    if (isWin) { a.push_back("-I"); a.push_back(winCxxConfigRoot()); }
    else if (isDarwin) { a.push_back("-I"); a.push_back(darwinCxxConfigRoot()); }
  };
  // Match the user's codegen axes (cpu/PIC) + opt class on the runtime objects
  // too, so the cached libc++/abi/unwind belong to the same variant as the TU.
  auto addVariant = [&](std::vector<std::string> &a) {
    appendCpuPic(a, V);
    a.push_back(V.fast ? "-O2" : "-Os");
  };

  // Build-only macros + warnings shared by libc++ and libc++abi. The config-site
  // knobs (ABI version, threads, musl, hardening, …) are NOT here — they come
  // from the embedded __config_site. Only build-time switches remain.
  auto addCxxCommon = [&](std::vector<std::string> &a) {
    for (const char *f :
         {"-DNDEBUG", "-D_LIBCPP_DISABLE_VISIBILITY_ANNOTATIONS",
          "-D_LIBCXXABI_DISABLE_VISIBILITY_ANNOTATIONS", "-fvisibility=hidden",
          "-fvisibility-inlines-hidden", "-nostdinc++", "-std=c++23",
          "-Wno-user-defined-literals", "-Wno-covered-switch-default",
          "-Wno-suggest-override"})
      a.push_back(f);
  };

  // --- libunwind ---
  // Skipped on darwin: libSystem.dylib exports the full _Unwind_* API, so a
  // darwin C++ link gets the unwinder from the system (no libunwind.a built or
  // linked). On linux/mingw we build & link our own.
  std::vector<std::vector<std::string>> uw;
  for (const char *rel : kLibunwindFiles) {
    if (isDarwin) break;
    std::string r = std::string("libunwind/") + rel;
    if (!vfsHas("cxx/" + r)) continue; // e.g. gcc_personality_v0.c (removed)
    std::vector<std::string> a = {"clang"};
    addCxxBaseArgs(a, muslArch, headerTriple, isWin, isDarwin);
    StringRef s(rel);
    bool isAsm = s.ends_with(".S") || s.ends_with(".s");
    bool isCpp = s.ends_with(".cpp");
    if (isCpp) {
      a.push_back("-fno-exceptions");
      a.push_back("-fno-rtti");
    } else if (!isAsm) {
      a.push_back("-std=c99");
      a.push_back("-fexceptions");
    }
    a.push_back("-I");
    a.push_back(cx + "/libunwind/include");
    for (const char *f :
         {"-D_LIBUNWIND_HIDE_SYMBOLS", "-Wa,--noexecstack",
          "-fvisibility=hidden", "-fvisibility-inlines-hidden",
          "-fvisibility-global-new-delete=force-hidden",
          "-D_LIBUNWIND_IS_NATIVE_ONLY", "-fasynchronous-unwind-tables",
          "-Wno-bitwise-conditional-parentheses", "-Wno-visibility",
          "-Wno-incompatible-pointer-types", "-Qunused-arguments", "-w"})
      a.push_back(f);
    // mingw headers redeclare some libunwind symbols with dllimport attrs.
    if (isWin) a.push_back("-Wno-dll-attribute-on-redeclaration");
    addVariant(a);
    target(a);
    a.push_back("-c");
    a.push_back(cx + "/" + r);
    uw.push_back(std::move(a));
  }

  // --- libc++abi ---
  std::vector<std::vector<std::string>> ab;
  for (const char *rel : kLibcxxabiFiles) {
    std::string r = std::string("libcxxabi/") + rel;
    if (!vfsHas("cxx/" + r)) continue;
    std::vector<std::string> a = {"clang"};
    addCxxBaseArgs(a, muslArch, headerTriple, isWin, isDarwin);
    addCxxCommon(a);
    for (const char *f : {"-D_LIBCPP_BUILDING_LIBRARY",
                          "-D_LIBCXXABI_BUILDING_LIBRARY", "-fstrict-aliasing",
                          "-fasynchronous-unwind-tables", "-Qunused-arguments",
                          "-w"})
      a.push_back(f);
    // mingw is a GNU ABI with __cxa_thread_atexit_impl in the CRT (zig adds this
    // for every non-old-glibc GNU target); routes cxa_thread_atexit through it.
    if (isWin) a.push_back("-DHAVE___CXA_THREAD_ATEXIT_IMPL");
    addConfigSite(a);
    a.push_back("-I");
    a.push_back(cx + "/libcxxabi/include");
    a.push_back("-I");
    a.push_back(cx + "/libcxx/include");
    a.push_back("-I");
    a.push_back(cx + "/libcxx/src");
    addVariant(a);
    target(a);
    a.push_back("-c");
    a.push_back(cx + "/" + r);
    ab.push_back(std::move(a));
  }

  // --- libc++ ---
  std::vector<std::vector<std::string>> cxx;
  std::vector<const char *> cxxFiles;
  for (const char *f : kLibcxxBaseFiles) cxxFiles.push_back(f);
  for (const char *f : kLibcxxThreadFiles) cxxFiles.push_back(f);
  if (isWin) {
    for (const char *f : kLibcxxWin32Files) cxxFiles.push_back(f);
    for (const char *f : kLibcxxWin32ThreadFiles) cxxFiles.push_back(f);
  }
  for (const char *rel : cxxFiles) {
    std::string r = std::string("libcxx/") + rel;
    if (!vfsHas("cxx/" + r)) continue;
    std::vector<std::string> a = {"clang"};
    addCxxBaseArgs(a, muslArch, headerTriple, isWin, isDarwin);
    addCxxCommon(a);
    for (const char *f :
         {"-D_LIBCPP_BUILDING_LIBRARY", "-DLIBCXX_BUILDING_LIBCXXABI",
          "-D_LIBCPP_HAS_NO_PRAGMA_SYSTEM_HEADER",
          "-DLIBC_NAMESPACE=__llvm_libc_common_utils", "-faligned-allocation",
          "-fasynchronous-unwind-tables", "-Qunused-arguments", "-w"})
      a.push_back(f);
    addConfigSite(a);
    a.push_back("-I");
    a.push_back(cx + "/libcxx/include");
    a.push_back("-I");
    a.push_back(cx + "/libcxxabi/include");
    a.push_back("-I");
    a.push_back(cx + "/libcxx/src");
    a.push_back("-I");
    a.push_back(cx + "/libc"); // llvm-libc shim (shared/fp_bits.h, …)
    addVariant(a);
    target(a);
    a.push_back("-c");
    a.push_back(cx + "/" + r);
    cxx.push_back(std::move(a));
  }

  // darwin: no libunwind.a (system unwinder). uw is empty there anyway.
  bool ok = isDarwin ||
            buildArchive(self, uw, objBase + "/uw", libDir + "/libunwind.a");
  ok = ok && buildArchive(self, ab, objBase + "/ab", libDir + "/libc++abi.a");
  ok = ok && buildArchive(self, cxx, objBase + "/cxx", libDir + "/libc++.a");
  ::unsetenv("UNPIN_NO_FRONT");
  return ok;
}

// Build (or reuse) the per-target C++ runtime. Returns the lib dir
// (<cache>/<triple>/<hash>/cxx/lib) holding libc++.a / libc++abi.a /
// libunwind.a, or "" on failure. Keyed by the same variant hash as the sysroot
// (the runtime matches the TU's codegen), but independent of it (needs only VFS
// headers).
std::string ensureCxxRuntime(const std::string &triple,
                             const std::string &muslArch,
                             const std::string &headerTriple, const Variant &V,
                             bool isWin = false, bool isDarwin = false) {
  std::string self = selfExe();
  std::string base = cacheBase() + "/" + triple;
  std::string h = variantHash(V);
  std::string dir = base + "/" + h + "/cxx";
  std::string done = dir + "/.complete";
  if (sys::fs::exists(done)) return dir + "/lib";

  sys::fs::create_directories(base);
  std::string lockPath = base + "/" + h + ".cxx.lock";
  int lockFd = ::open(lockPath.c_str(), O_CREAT | O_RDWR, 0644);
  if (lockFd >= 0) ::flock(lockFd, LOCK_EX);
  if (sys::fs::exists(done)) {
    if (lockFd >= 0) ::close(lockFd);
    return dir + "/lib";
  }

  std::string tmp = dir + ".tmp";
  sys::fs::remove_directories(tmp);
  sys::fs::create_directories(tmp + "/lib");

  errs() << "unpin-musl: building C++ runtime for " << triple << " ...\n";
  bool ok = buildCxxRuntime(self, triple, muslArch, headerTriple, tmp + "/lib",
                            tmp + "/obj", V, isWin, isDarwin);
  if (!ok) {
    errs() << "unpin-musl: C++ runtime build FAILED for " << triple << "\n";
    if (lockFd >= 0) ::close(lockFd);
    return "";
  }
  { std::error_code ec; raw_fd_ostream m(tmp + "/.complete", ec); m << "1\n"; }
  sys::fs::remove_directories(tmp + "/obj");
  sys::fs::create_directories(base + "/" + h);
  sys::fs::rename(tmp, dir);
  if (lockFd >= 0) ::close(lockFd);
  return sys::fs::exists(done) ? dir + "/lib" : "";
}

// Build (or reuse) the per-target sysroot. Returns the cache dir
// (<cache>/<triple>/<hash>), or "" on failure. Layout: <dir>/lib/{libc.a,
// libclang_rt.builtins.a,crt1.o,Scrt1.o,rcrt1.o}, <dir>/bin/ld.lld. The <hash>
// segment is the variant key so distinct flag sets (cpu/opt/PIC) and recipe
// versions never collide.
std::string ensureSysroot(const std::string &triple,
                          const std::string &muslArch,
                          const std::string &headerTriple, const Variant &V) {
  std::string self = selfExe();
  std::string base = cacheBase() + "/" + triple;
  std::string h = variantHash(V);
  std::string dir = base + "/" + h;
  std::string done = dir + "/.complete";
  if (sys::fs::exists(done)) return dir;

  // Serialize concurrent builders via a per-variant lock file under the triple.
  sys::fs::create_directories(base);
  std::string lockPath = base + "/" + h + ".lock";
  int lockFd = ::open(lockPath.c_str(), O_CREAT | O_RDWR, 0644);
  if (lockFd >= 0) ::flock(lockFd, LOCK_EX);
  if (sys::fs::exists(done)) { // someone else finished while we waited
    if (lockFd >= 0) ::close(lockFd);
    return dir;
  }

  std::string tmp = dir + ".tmp";
  sys::fs::remove_directories(tmp);
  sys::fs::create_directories(tmp + "/lib");
  sys::fs::create_directories(tmp + "/bin");

  errs() << "unpin-musl: building sysroot for " << triple << " ...\n";
  bool ok = buildLibc(self, triple, muslArch, headerTriple, tmp + "/obj",
                      tmp + "/lib/libc.a", V);
  ok = ok && buildCrt(self, triple, muslArch, headerTriple, "musl/crt/crt1.c",
                      tmp + "/lib/crt1.o", /*pic=*/false, V);
  ok = ok && buildCrt(self, triple, muslArch, headerTriple, "musl/crt/Scrt1.c",
                      tmp + "/lib/Scrt1.o", /*pic=*/true, V);
  ok = ok && buildCrt(self, triple, muslArch, headerTriple, "musl/crt/rcrt1.c",
                      tmp + "/lib/rcrt1.o", /*pic=*/true, V);
  // M3: compiler-rt builtins (soft-float TF/XF, int128, outline atomics, …) so
  // printf and general arithmetic resolve at the static link.
  ok = ok && buildBuiltins(self, triple, muslArch, tmp + "/obj-rt",
                           tmp + "/lib/libclang_rt.builtins.a", V);
  if (!ok) {
    errs() << "unpin-musl: sysroot build FAILED for " << triple << "\n";
    if (lockFd >= 0) ::close(lockFd);
    return "";
  }
  // musl keeps libm/libpthread/librt/libdl/libresolv/libutil/libxnet/libcrypt
  // EMPTY — every symbol lives in libc.a. Ship empty archives (a bare
  // `!<arch>\n` header, which lld accepts) so a package's `-lm`/`-lpthread`/…
  // resolves to our sysroot via the appended `-L<sysroot>/lib`, instead of
  // leaking the host's glibc libm.a (or failing "cannot find -lm" in a clean
  // sandbox). Real musl does exactly this — its split libs are empty .a stubs.
  for (const char *stub : {"libm", "libpthread", "librt", "libdl", "libresolv",
                           "libutil", "libxnet", "libcrypt"}) {
    std::error_code ec;
    raw_fd_ostream s(tmp + "/lib/" + std::string(stub) + ".a", ec);
    if (!ec) s << "!<arch>\n";
  }
  // A multicall face so clang can invoke the embedded ld.lld with argv[0]
  // basename "ld.lld" (the driver dispatches on argv[0]). Symlink (not hard
  // link: the cache and the binary are usually on different filesystems).
  ::symlink(self.c_str(), (tmp + "/bin/ld.lld").c_str());
  sys::fs::remove(done); // ensure clean
  { std::error_code ec; raw_fd_ostream m(tmp + "/.complete", ec); m << "1\n"; }
  sys::fs::remove_directories(tmp + "/obj");
  sys::fs::remove_directories(tmp + "/obj-rt");
  sys::fs::rename(tmp, dir);
  if (lockFd >= 0) ::close(lockFd);
  return sys::fs::exists(done) ? dir : "";
}

// --- Windows / mingw-w64 on-demand sysroot ---------------------------------
//
// Recipe ported from zig 0.16 src/libs/mingw.zig (file lists + flags only). One
// static libmingw32.a (mingw32 startup + mingwex + winpthreads) + crt2.o + the
// compiler-rt builtins, plus DLL import libs generated on demand from the
// embedded .def files via llvm-dlltool (NOT zig's bespoke def/implib code). The
// runtime TUs compile FRONT-ACTIVE (like the builtins): the front injects
// -resource-dir + -nostdlibinc + -isystem any-windows-any, and these add only
// the mingw-specific defines/includes on top. Scope: x86_64-windows-gnu.

// dlltool COFF machine name for an arch token.
std::string coffMachine(StringRef archTok) {
  if (archTok == "x86_64") return "i386:x86-64";
  if (archTok == "i386" || archTok == "i686" || archTok == "x86") return "i386";
  if (archTok == "aarch64") return "arm64";
  if (archTok == "arm" || archTok == "armv7" || archTok == "thumb") return "arm";
  return archTok.str();
}

// Extra flags for a mingw runtime TU, on top of the front's header injection.
// `crt` selects the CRT/mingwex define set (zig addCrtCcArgs); the winpthreads
// objects use the base set (zig addCcArgs) plus -DIN_WINPTHREAD at the callsite.
void addMingwExtra(std::vector<std::string> &a, bool crt, const Variant &V) {
  a.push_back("-std=gnu11");
  a.push_back("-D__USE_MINGW_ANSI_STDIO=0");
  a.push_back("-Qunused-arguments");
  a.push_back("-w");
  a.push_back(V.fast ? "-O2" : "-Os");
  if (crt) {
    // Per Martin Storsjö, mingw-w64-crt is always built with these.
    for (const char *d :
         {"-D__MSVCRT_VERSION__=0x700", "-D_CRTBLD", "-D_SYSCRT=1",
          "-D_WIN32_WINNT=0x0f00", "-DCRTDLL=1", "-DHAVE_CONFIG_H"})
      a.push_back(d);
    a.push_back("-I");
    a.push_back(mingwRoot() + "/include"); // build-only internal headers
  }
  appendCpuPic(a, V);
}

// Compile the union of generic + x86 + winpthreads into one libmingw32.a (zig's
// buildCrtFile(.libmingw32_lib)). LTO stays off (we pass no -flto; llvm#43698).
bool buildMingwArchive(const std::string &self, const std::string &triple,
                       const std::string &objDir, const std::string &outLib,
                       const Variant &V) {
  struct Job { std::string src; bool crt; bool wpt; };
  std::vector<Job> jobs;
  for (const char *f : kMingwGeneric) jobs.push_back({mingwRoot() + "/" + f, true, false});
  for (const char *f : kMingwX86)     jobs.push_back({mingwRoot() + "/" + f, true, false});
  for (const char *f : kMingwWinpthreads) jobs.push_back({mingwRoot() + "/" + f, false, true});

  if (sys::fs::create_directories(objDir)) {
    errs() << "unpin-mingw: mkdir " << objDir << " failed\n";
    return false;
  }
  std::atomic<size_t> next{0};
  std::atomic<bool> ok{true};
  std::vector<std::string> objs(jobs.size());
  unsigned n = std::min(8u, std::max(1u, std::thread::hardware_concurrency()));
  std::vector<std::thread> pool;
  for (unsigned w = 0; w < n; ++w) {
    pool.emplace_back([&] {
      for (;;) {
        size_t i = next.fetch_add(1);
        if (i >= jobs.size() || !ok.load()) return;
        std::string obj = objDir + "/" + utostr(i) + ".o";
        objs[i] = obj;
        std::vector<std::string> args = {"clang"};
        addMingwExtra(args, jobs[i].crt, V);
        if (jobs[i].wpt) {
          args.push_back("-DIN_WINPTHREAD");
          // winpthreads wrongly assumes clang has -Wprio-ctor-dtor.
          args.push_back("-Wno-unknown-warning-option");
        }
        args.push_back("-target");
        args.push_back(triple);
        args.push_back("-c");
        args.push_back(jobs[i].src);
        args.push_back("-o");
        args.push_back(obj);
        if (runSelf(self, args) != 0) {
          errs() << "unpin-mingw: compile failed: " << jobs[i].src << "\n";
          ok.store(false);
          return;
        }
      }
    });
  }
  for (auto &t : pool) t.join();
  if (!ok.load()) return false;
  std::vector<std::string> ar = {"llvm-ar", "rcs", outLib};
  for (auto &o : objs) ar.push_back(o);
  return runSelf(self, ar) == 0;
}

// crt2.o (the exe entry, zig crt2_o) from crt/crtexe.c. x86_64 SEH needs async
// unwind tables (zig sets unwind_tables=.async for non-x86(32)).
bool buildMingwCrt(const std::string &self, const std::string &triple,
                   const std::string &outObj, const Variant &V) {
  std::vector<std::string> args = {"clang"};
  addMingwExtra(args, /*crt=*/true, V);
  args.push_back("-fasynchronous-unwind-tables");
  args.push_back("-target");
  args.push_back(triple);
  args.push_back("-c");
  args.push_back(mingwRoot() + "/crt/crtexe.c");
  args.push_back("-o");
  args.push_back(outObj);
  return runSelf(self, args) == 0;
}

// VFS path of the .def/.def.in for an import lib (zig findDef order: arch lib64,
// then lib-common .def, then .def.in). Returns "" if none ship.
std::string findMingwDef(const std::string &name) {
  for (const std::string &p : {std::string("lib64/") + name + ".def",
                               std::string("lib-common/") + name + ".def",
                               std::string("lib-common/") + name + ".def.in"})
    if (vfsHas("libc/mingw/" + p)) return mingwRoot() + "/" + p;
  return "";
}

// Generate the DLL import libraries for the always-link set. dlltool reads from
// the REAL filesystem (not clang's VFS), so each .def is first materialised to
// disk by clang -E (which DOES read the VFS) — this also expands the .def.in
// macros (func.def.in) for the arch. Output libNAME.a so -lNAME resolves it.
bool buildImportLibs(const std::string &self, const std::string &triple,
                     const std::string &archTok, const std::string &implibDir,
                     const std::string &defDir) {
  if (sys::fs::create_directories(implibDir) ||
      sys::fs::create_directories(defDir)) {
    errs() << "unpin-mingw: mkdir implib/def failed\n";
    return false;
  }
  std::string mach = coffMachine(archTok);
  for (const char *nm : kMingwAlwaysLink) {
    std::string name = nm;
    std::string def = findMingwDef(name);
    if (def.empty()) continue; // zig: no .def → let the linker try its paths
    std::string realDef = defDir + "/" + name + ".def";
    ::setenv("UNPIN_NO_FRONT", "1", 1);
    std::vector<std::string> pp = {
        "clang", "-E", "-P", "-x", "c", "-nostdinc", "-I",
        mingwRoot() + "/def-include", "-target", triple, def, "-o", realDef};
    int rc = runSelf(self, pp);
    ::unsetenv("UNPIN_NO_FRONT");
    if (rc != 0) {
      errs() << "unpin-mingw: preprocess .def failed: " << name << "\n";
      return false;
    }
    std::string out = implibDir + "/lib" + name + ".a";
    std::vector<std::string> dt = {"dlltool", "-m", mach, "-d", realDef, "-l", out};
    if (runSelf(self, dt) != 0) {
      errs() << "unpin-mingw: dlltool failed: " << name << "\n";
      return false;
    }
  }
  return true;
}

// Build (or reuse) the per-target Windows sysroot. Same variant-keyed cache as
// the linux path (<cache>/<triple>/<hash>). Layout: <dir>/lib/{libmingw32.a,
// crt2.o,libclang_rt.builtins.a}, <dir>/implib/lib*.a, <dir>/bin/{ld.lld,lld}.
std::string ensureWinSysroot(const std::string &triple,
                             const std::string &archTok, const Variant &V) {
  std::string self = selfExe();
  std::string base = cacheBase() + "/" + triple;
  std::string h = variantHash(V);
  std::string dir = base + "/" + h;
  std::string done = dir + "/.complete";
  if (sys::fs::exists(done)) return dir;

  sys::fs::create_directories(base);
  std::string lockPath = base + "/" + h + ".lock";
  int lockFd = ::open(lockPath.c_str(), O_CREAT | O_RDWR, 0644);
  if (lockFd >= 0) ::flock(lockFd, LOCK_EX);
  if (sys::fs::exists(done)) {
    if (lockFd >= 0) ::close(lockFd);
    return dir;
  }

  std::string tmp = dir + ".tmp";
  sys::fs::remove_directories(tmp);
  sys::fs::create_directories(tmp + "/lib");
  sys::fs::create_directories(tmp + "/bin");

  errs() << "unpin-mingw: building Windows sysroot for " << triple << " ...\n";
  std::string muslArch = muslArchName(archTok); // x86_64 → x86_64
  bool ok = buildMingwArchive(self, triple, tmp + "/obj",
                              tmp + "/lib/libmingw32.a", V);
  ok = ok && buildMingwCrt(self, triple, tmp + "/lib/crt2.o", V);
  ok = ok && buildBuiltins(self, triple, muslArch, tmp + "/obj-rt",
                           tmp + "/lib/libclang_rt.builtins.a", V, /*isWin=*/true);
  ok = ok && buildImportLibs(self, triple, archTok, tmp + "/implib", tmp + "/def");
  if (!ok) {
    errs() << "unpin-mingw: Windows sysroot build FAILED for " << triple << "\n";
    if (lockFd >= 0) ::close(lockFd);
    return "";
  }
  // lld faces: clang's MinGW driver invokes the linker as ld.lld (lld's ELF
  // driver re-dispatches the PE emulations to its COFF/MinGW driver); ship lld
  // too as a fallback name.
  ::symlink(self.c_str(), (tmp + "/bin/ld.lld").c_str());
  ::symlink(self.c_str(), (tmp + "/bin/lld").c_str());
  sys::fs::remove(done);
  { std::error_code ec; raw_fd_ostream m(tmp + "/.complete", ec); m << "1\n"; }
  sys::fs::remove_directories(tmp + "/obj");
  sys::fs::remove_directories(tmp + "/obj-rt");
  sys::fs::remove_directories(tmp + "/def");
  sys::fs::rename(tmp, dir);
  if (lockFd >= 0) ::close(lockFd);
  return sys::fs::exists(done) ? dir : "";
}

// On-demand macOS SDK + builtins for `triple`. Unlike musl/mingw there is no
// libc to build — libSystem.tbd (materialised from the VFS) is the whole C
// library; we only build compiler-rt builtins. The dir doubles as the linker's
// -isysroot: usr/lib/libSystem.tbd + SDKSettings.json at the root let clang's
// Darwin driver resolve -lSystem and the deployment SDK version.
std::string ensureDarwinSysroot(const std::string &triple,
                                const std::string &archTok, const Variant &V) {
  std::string self = selfExe();
  std::string base = cacheBase() + "/" + triple;
  std::string h = variantHash(V);
  std::string dir = base + "/" + h;
  std::string done = dir + "/.complete";
  if (sys::fs::exists(done)) return dir;

  sys::fs::create_directories(base);
  std::string lockPath = base + "/" + h + ".lock";
  int lockFd = ::open(lockPath.c_str(), O_CREAT | O_RDWR, 0644);
  if (lockFd >= 0) ::flock(lockFd, LOCK_EX);
  if (sys::fs::exists(done)) {
    if (lockFd >= 0) ::close(lockFd);
    return dir;
  }

  std::string tmp = dir + ".tmp";
  sys::fs::remove_directories(tmp);
  sys::fs::create_directories(tmp + "/usr/lib");
  sys::fs::create_directories(tmp + "/lib");
  sys::fs::create_directories(tmp + "/bin");

  errs() << "unpin-darwin: building macOS sysroot for " << triple << " ...\n";
  std::string muslArch = muslArchName(archTok);
  bool ok = copyVfsFile(kDarwinTbdRel, tmp + "/usr/lib/libSystem.tbd");
  // No SDKSettings.json: zig's stub one (only "MinimalDisplayName") fails clang's
  // SDK-settings parse and warns; its absence is clean and the driver falls back
  // to a default deployment target, which links and runs fine.
  ok = ok && buildBuiltins(self, triple, muslArch, tmp + "/obj-rt",
                           tmp + "/lib/libclang_rt.builtins.a", V,
                           /*isWin=*/false, /*isDarwin=*/true);
  if (!ok) {
    errs() << "unpin-darwin: macOS sysroot build FAILED for " << triple << "\n";
    if (lockFd >= 0) ::close(lockFd);
    return "";
  }
  // ld64.lld: clang's Darwin driver invokes the Mach-O linker as `ld64.lld`.
  ::symlink(self.c_str(), (tmp + "/bin/ld64.lld").c_str());
  sys::fs::remove(done);
  { std::error_code ec; raw_fd_ostream m(tmp + "/.complete", ec); m << "1\n"; }
  sys::fs::remove_directories(tmp + "/obj-rt");
  sys::fs::rename(tmp, dir);
  if (lockFd >= 0) ::close(lockFd);
  return sys::fs::exists(done) ? dir : "";
}

// --- arg inspection --------------------------------------------------------

struct TargetInfo {
  bool isMusl = false;
  bool isDarwin = false;   // *-apple-darwin / *-apple-macos[x] (Mach-O)
  bool isWindows = false;  // *-windows-gnu / *-w64-mingw32 (NOT msvc)
  std::string triple;      // as given
  std::string archTok;     // first component
};

TargetInfo parseTarget(ArrayRef<const char *> Args) {
  TargetInfo ti;
  StringRef t;
  for (size_t i = 1; i < Args.size(); ++i) {
    StringRef a = Args[i];
    if (a == "-target" && i + 1 < Args.size()) t = Args[i + 1];
    else if (a.starts_with("--target=")) t = a.substr(9);
  }
  if (t.empty()) return ti;
  // A mingw-w64 (GNU ABI) Windows target: on-demand mingw runtime + import libs.
  // The MSVC ABI (*-windows-msvc) is a different world (no mingw CRT) — not ours.
  if ((t.contains("windows") || t.contains("mingw")) && !t.contains("msvc") &&
      (t.contains("gnu") || t.contains("mingw"))) {
    ti.isWindows = true;
    ti.triple = t.str();
    ti.archTok = t.substr(0, t.find('-')).str();
    return ti;
  }
  // macOS / Darwin (Mach-O): apple vendor or a darwin/macos OS token. libSystem
  // stub + on-demand builtins; no musl. (iOS/tvOS/watchOS share the Mach-O path
  // in principle, but only macOS is wired — libSystem.tbd targets macos.)
  if (t.contains("apple") || t.contains("darwin") || t.contains("macos")) {
    ti.isDarwin = true;
    ti.triple = t.str();
    ti.archTok = t.substr(0, t.find('-')).str();
    return ti;
  }
  if (!t.contains("musl")) return ti;
  ti.isMusl = true;
  ti.triple = t.str();
  ti.archTok = t.substr(0, t.find('-')).str();
  return ti;
}

// Lift the codegen axes that change the on-demand libc/libc++/builtins from the
// user's command line into a cache-key Variant. Last value wins per axis (clang
// semantics). cpu flags are recorded verbatim (no synonym canonicalisation — a
// different spelling just builds a harmless extra variant). Opt collapses to a
// {fast,small} class, mirroring zig's compilerRtOptMode (there is never an "-O0"
// libc). Sanitizers / single-threaded are deliberately ignored (deferred).
Variant parseVariant(ArrayRef<const char *> Args, const std::string &triple) {
  Variant V;
  V.triple = triple;
  std::string march, mcpu, mtune, mabi, optLast;
  int pic = 0; // 0 unset, 1 pic, -1 no-pic
  int pie = 0; // 0 unset, 1 -pie, -1 -no-pie
  int lto = 0; // 0 unset, 1 -flto, -1 -fno-lto
  for (size_t i = 1; i < Args.size(); ++i) {
    StringRef a = Args[i];
    if (a.starts_with("-march=")) march = a.str();
    else if (a.starts_with("-mcpu=")) mcpu = a.str();
    else if (a.starts_with("-mtune=")) mtune = a.str();
    else if (a.starts_with("-mabi=")) mabi = a.str();
    else if (a == "-O0" || a == "-O1" || a == "-O2" || a == "-O3" ||
             a == "-O" || a == "-Os" || a == "-Oz" || a == "-Ofast" ||
             a == "-Og")
      optLast = a.str();
    else if (a == "-fPIC" || a == "-fpic" || a == "-fPIE" || a == "-fpie")
      pic = 1;
    else if (a == "-fno-pic" || a == "-fno-PIC" || a == "-fno-pie" ||
             a == "-fno-PIE")
      pic = -1;
    else if (a == "-pie") pie = 1;
    else if (a == "-no-pie" || a == "-nopie") pie = -1;
    else if (a == "-flto" || a == "-flto=full" || a == "-flto=thin" ||
             a.starts_with("-flto="))
      lto = 1;
    else if (a == "-fno-lto") lto = -1;
  }
  for (auto *s : {&march, &mcpu, &mtune, &mabi})
    if (!s->empty()) V.cpuFlags.push_back(*s);
  V.fast = (optLast == "-O2" || optLast == "-O3" || optLast == "-Ofast");
  V.pie = (pie == 1);
  // A -pie link needs position-independent objects, so it implies pic unless the
  // user explicitly disabled it.
  V.pic = (pic == 1) || (V.pie && pic != -1);
  // Bitcode libc follows the link's own -flto: every real engine link is -flto
  // (the cc-shim appends it), so libc is bitcode and folds into the whole-program
  // LTO — uniform with all other engine objects. Autoconf conftest probes have
  // -flto stripped by the shim, so they fall to the native libc (honest + fast).
  V.lto = (lto == 1);
  return V;
}

// A link step = produces an executable: no -c/-S/-E/-fsyntax-only, and not a
// pure query (--version/-###/-print-*). Conservative: treat as link unless an
// obvious compile/query-only flag is present.
bool isLinkStep(ArrayRef<const char *> Args) {
  for (size_t i = 1; i < Args.size(); ++i) {
    StringRef a = Args[i];
    if (a == "-c" || a == "-S" || a == "-E" || a == "-fsyntax-only" ||
        a == "--version" || a == "-###" || a == "-v" || a == "-dumpversion" ||
        a.starts_with("-print"))
      return false;
  }
  return true;
}

// C++ mode? Mirror clang's own detection: a "++" driver face (clang++/c++/g++),
// --driver-mode=g++, an explicit `-x c++…`, -stdlib=libc++/-lc++, or any
// positional input with a C++ source extension. Drives libc++ include + link.
bool wantsCxx(ArrayRef<const char *> Args) {
  if (sys::path::filename(StringRef(Args[0])).contains("++")) return true;
  for (size_t i = 1; i < Args.size(); ++i) {
    StringRef a = Args[i];
    if (a.starts_with("--driver-mode=")) return a.ends_with("g++");
    if (a == "-x" && i + 1 < Args.size() &&
        StringRef(Args[i + 1]).starts_with("c++"))
      return true;
    if (a == "-stdlib=libc++" || a == "--stdlib=libc++" || a == "-lc++")
      return true;
    if (!a.starts_with("-")) {
      StringRef e = sys::path::extension(a);
      if (e == ".cpp" || e == ".cc" || e == ".cxx" || e == ".c++" ||
          e == ".C" || e == ".cppm" || e == ".ixx" || e == ".mm")
        return true;
    }
  }
  return false;
}

// A user-supplied macOS SDK, if any: the value of -isysroot <dir> / --sysroot
// <dir> / --sysroot=<dir> in the argv (or the SDKROOT env, like clang). Returns
// "" if none. When present, we link against THAT SDK (its libSystem + its
// System/Library/Frameworks) instead of our bundled minimal SDK, so frameworks
// (CoreFoundation/Foundation/…) resolve. Mirrors zig: zig forwards --sysroot as
// -isysroot and never bundles frameworks.
std::string darwinSdkArg(ArrayRef<const char *> Args) {
  for (size_t i = 1; i < Args.size(); ++i) {
    StringRef a = Args[i];
    if ((a == "-isysroot" || a == "--sysroot") && i + 1 < Args.size())
      return StringRef(Args[i + 1]).str();
    if (a.starts_with("--sysroot="))
      return a.substr(std::strlen("--sysroot=")).str();
    if (a.starts_with("-isysroot=")) // tolerate the joined spelling too
      return a.substr(std::strlen("-isysroot=")).str();
  }
  if (const char *e = ::getenv("SDKROOT"); e && e[0]) return e;
  return "";
}

// Native macOS SDK auto-detection, exactly like zig's std.zig.system.darwin:
// check `xcode-select --print-path` first (so we never trigger the CLT install
// popup from a bare xcrun), then `xcrun --sdk macosx --show-sdk-path`. Returns ""
// on any failure — including a non-Apple host (xcrun/xcode-select absent), so on
// Linux this is a quick no-op and we fall back to the bundled minimal SDK.
std::string detectDarwinSdk() {
  auto run = [](const char *cmd) -> std::string {
    FILE *p = ::popen(cmd, "r");
    if (!p) return "";
    std::string out;
    char buf[512];
    size_t n;
    while ((n = std::fread(buf, 1, sizeof buf, p)) > 0) out.append(buf, n);
    int rc = ::pclose(p);
    if (rc != 0) return "";
    while (!out.empty() &&
           (out.back() == '\n' || out.back() == '\r' || out.back() == ' '))
      out.pop_back();
    return out;
  };
  if (run("xcode-select --print-path 2>/dev/null").empty()) return "";
  return run("xcrun --sdk macosx --show-sdk-path 2>/dev/null");
}

// macOS/darwin front: inject the embedded any-darwin-any headers always, and on
// a link step the on-demand darwin sysroot (libSystem.tbd + builtins) plus a
// self-contained Mach-O link via ld64.lld. libSystem IS the libc — no libc.a is
// built. With a real macOS SDK (user -isysroot/--sysroot or native xcrun
// detection) we link against the SDK's libSystem + frameworks so CoreFoundation/
// Foundation/etc. resolve, keeping only our own compiler-rt builtins (+ static
// libc++ for C++); without one we use the bundled minimal SDK (C/C++ only, no
// frameworks). Mirrors zig: it never bundles frameworks — they come from the SDK.
void frontRewriteDarwin(SmallVectorImpl<const char *> &Args, StringSaver &Saver,
                        const TargetInfo &ti) {
  auto add = [&](const Twine &s) { Args.push_back(Saver.save(s.str()).data()); };
  add("-resource-dir");
  add(vroot() + "/clang-resource");

  // Pick the SDK: an explicit user -isysroot/--sysroot wins; otherwise try native
  // xcrun detection (no-op off a Mac). A real SDK enables frameworks; with none
  // we use the bundled minimal SDK (C/C++ only). userSdk!="" means the argv
  // already carries -isysroot, so we must NOT add our own.
  std::string userSdk = darwinSdkArg(Args);
  std::string sdk = userSdk.empty() ? detectDarwinSdk() : userSdk;
  bool haveSdk = !sdk.empty();
  // The SDK supplies the system C headers (and framework headers); only force the
  // bundled any-darwin-any when there is no SDK.
  if (!haveSdk) add("-nostdlibinc");
  if (haveSdk && userSdk.empty()) { // auto-detected: make it visible to clang
    add("-isysroot");
    add(sdk);
  }
  // A TLS-capable deployment target when the triple pins no version (covers both
  // user C/C++ TLS and codegen consistency with the runtime build).
  {
    std::string vm = darwinVersionMinFlag(ti.triple, muslArchName(ti.archTok));
    if (!vm.empty()) add(vm);
  }

  // C++ TU: embedded libc++ headers, with the darwin __config_site dir first so
  // upstream __config picks the darwin knobs (musl=0, no tzdb). These precede the
  // C system headers so libc++'s C-compat wrappers shadow the SDK ones. We keep
  // OUR version-matched libc++ even with a real SDK (we link it statically).
  bool cxx = wantsCxx(Args);
  if (cxx) {
    add("-nostdinc++");
    add("-isystem");
    add(darwinCxxConfigRoot());
    add("-isystem");
    add(Twine(cxxRoot()) + "/libcxx/include");
    add("-isystem");
    add(Twine(cxxRoot()) + "/libcxxabi/include");
    // clang builtin headers before the Apple SDK headers: libc++'s <stddef.h>
    // wrapper #include_next's to the compiler's, whose <stddef.h> defines
    // size_t/ptrdiff_t that Apple's <stddef.h> then uses. (See addCxxBaseArgs.)
    add("-isystem");
    add(vroot() + "/clang-resource/include");
  }
  // With a real SDK, its System/usr headers come via -isysroot (clang's Darwin
  // toolchain adds <sdk>/usr/include + framework search automatically). Without
  // one, fall back to our embedded any-darwin-any.
  if (!haveSdk) {
    add("-isystem");
    add(darwinHeaders());
  }

  if (!isLinkStep(Args)) return;

  Variant V = parseVariant(Args, ti.triple);
  std::string dir = ensureDarwinSysroot(ti.triple, ti.archTok, V);
  if (dir.empty()) return; // build failed; let clang error naturally

  std::string muslArch = muslArchName(ti.archTok);
  std::string cxxLib;
  if (cxx) cxxLib = ensureCxxRuntime(ti.triple, muslArch, /*headerTriple=*/"", V,
                                     /*isWin=*/false, /*isDarwin=*/true);

  // Self-contained Mach-O link. clang's Darwin driver supplies the Mach-O
  // essentials (-arch / -platform_version / -syslibroot / entry _main). -isysroot
  // points it at the SDK so -lSystem resolves to usr/lib/libSystem.tbd (the
  // umbrella stub inlines every reexported sub-lib's symbols) and frameworks
  // resolve from <sdk>/System/Library/Frameworks. -nostdlib drops the driver's
  // default -lSystem and its auto compiler-rt (it would look for
  // lib/darwin/libclang_rt.osx.a, absent here); we re-add libSystem + our
  // on-demand builtins. Our -L paths go FIRST so our static libc++/builtins win
  // over any SDK copy; the SDK's usr/lib follows (libSystem + framework fallback).
  // C++: -lc++ -lc++abi (ours, static); the unwinder (_Unwind_*) comes from
  // libSystem, so no -lunwind. The group lets libc++ ↔ libc++abi ↔ builtins
  // iterate. A user's -framework Foo flows through untouched.
  std::string libRoot = haveSdk ? sdk : dir; // where libSystem.tbd lives
  if (userSdk.empty()) { // not already in argv
    add("-isysroot");
    add(haveSdk ? sdk : dir);
  }
  add("-nostdlib");
  if (!cxxLib.empty()) add(Twine("-L") + cxxLib);
  add(Twine("-L") + dir + "/lib"); // our builtins
  add(Twine("-L") + libRoot + "/usr/lib");
  if (haveSdk) add(Twine("-F") + sdk + "/System/Library/Frameworks");
  add("-Wl,-search_paths_first");
  add("-lSystem");
  if (!cxxLib.empty()) {
    add("-lc++");
    add("-lc++abi");
  }
  add("-lclang_rt.builtins");
  add("-fuse-ld=lld");
  add(Twine("-B") + dir + "/bin");
}

// Windows/mingw front: inject the embedded Windows headers always (plus the
// libc++ headers for a C++ TU), and on a link step the on-demand mingw sysroot
// (crt2.o + libmingw32.a + builtins + import libs) plus the C++ runtime
// (libc++/libc++abi/libunwind) when C++. Mirrors the musl branch.
void frontRewriteWin(SmallVectorImpl<const char *> &Args, StringSaver &Saver,
                     const TargetInfo &ti) {
  auto add = [&](const Twine &s) { Args.push_back(Saver.save(s.str()).data()); };
  add("-resource-dir");
  add(vroot() + "/clang-resource");
  add("-nostdlibinc");

  // C++ TU: embedded libc++ headers, with the Windows __config_site dir first so
  // upstream __config picks the Windows knobs. These precede the Win32 C headers
  // so libc++'s C-compat wrappers shadow the UCRT ones.
  bool cxx = wantsCxx(Args);
  if (cxx) {
    add("-nostdinc++");
    add("-isystem");
    add(winCxxConfigRoot());
    add("-isystem");
    add(Twine(cxxRoot()) + "/libcxx/include");
    add("-isystem");
    add(Twine(cxxRoot()) + "/libcxxabi/include");
  }
  add("-isystem");
  add(winHeaders());

  if (!isLinkStep(Args)) return;

  Variant V = parseVariant(Args, ti.triple);
  std::string dir = ensureWinSysroot(ti.triple, ti.archTok, V);
  if (dir.empty()) return; // build failed; let clang error naturally

  std::string muslArch = muslArchName(ti.archTok);
  std::string cxxLib;
  if (cxx) cxxLib = ensureCxxRuntime(ti.triple, muslArch, /*headerTriple=*/"", V,
                                     /*isWin=*/true);

  // Self-contained link: our crt2.o + libmingw32.a + builtins, then the UCRT /
  // Win32 import libs. -nostdlib suppresses clang's MinGW auto-CRT/default libs;
  // we supply the full set. The C++ runtime + mingw + builtins are mutually
  // referential, so one --start-group covers them; the import libs follow
  // (resolve UCRT/kernel).
  add("-nostdlib");
  add(Twine(dir) + "/lib/crt2.o");
  add(Twine("-L") + dir + "/lib");
  add(Twine("-L") + dir + "/implib");
  if (!cxxLib.empty()) add(Twine("-L") + cxxLib);
  add("-Wl,--start-group");
  if (!cxxLib.empty()) {
    add("-lc++");
    add("-lc++abi");
    add("-lunwind");
  }
  add("-lmingw32");
  add("-lclang_rt.builtins");
  add("-Wl,--end-group");
  for (const char *l : kMingwAlwaysLink) add(Twine("-l") + l);
  add("-fuse-ld=lld");
  add(Twine("-B") + dir + "/bin");
}

} // namespace

namespace unpin {

void frontRewriteMusl(SmallVectorImpl<const char *> &Args, StringSaver &Saver) {
  if (const char *x = ::getenv("UNPIN_NO_FRONT"); x && x[0]) return;
  if (Args.size() >= 2) {
    StringRef a1 = Args[1];
    if (a1 == "-cc1" || a1 == "-cc1as" || a1.starts_with("-cc1")) return;
  }
  TargetInfo ti = parseTarget(Args);
  if (ti.isWindows) { frontRewriteWin(Args, Saver, ti); return; }
  if (ti.isDarwin) { frontRewriteDarwin(Args, Saver, ti); return; }
  if (!ti.isMusl) return;

  std::string muslArch = muslArchName(ti.archTok);
  // Header dir uses zig's arch token (headerArchName), not the musl folder name
  // — they differ for 32-bit x86 (musl "i386" vs header "x86"). Linux only.
  std::string headerTriple = headerArchName(ti.archTok) + "-linux-musl";

  auto add = [&](const Twine &s) { Args.push_back(Saver.save(s.str()).data()); };

  // Always: embedded clang builtins + musl headers, no host include leakage.
  add("-resource-dir");
  add(Twine(VROOT) + "/clang-resource");
  add("-nostdlibinc");

  // C++ TU: the embedded libc++ headers (+ libc++abi.h, pulled by <typeinfo> &
  // <exception>). __config_site is embedded too, so upstream __config is clean.
  // These MUST precede the musl C -isystem dirs: libc++'s C-compat wrappers
  // (<cmath>/<cstring>/<cerrno> → <math.h>/<string.h>/<errno.h>) must shadow
  // musl's so the macro-undef dance runs (else `std::isinf` hits musl's macro).
  bool cxx = wantsCxx(Args);
  if (cxx) {
    add("-nostdinc++");
    add("-isystem");
    add(Twine(cxxRoot()) + "/libcxx/include");
    add("-isystem");
    add(Twine(cxxRoot()) + "/libcxxabi/include");
  }

  add("-isystem");
  add(Twine(libcRoot()) + "/include/" + headerTriple);
  add("-isystem");
  add(Twine(libcRoot()) + "/include/generic-musl");
  // Linux kernel UAPI headers (<linux/...>, <asm/...>): arch-specific first,
  // then the arch-independent set.
  add("-isystem");
  add(Twine(libcRoot()) + "/include/" + kernelArchName(muslArch) + "-linux-any");
  add("-isystem");
  add(Twine(libcRoot()) + "/include/any-linux-any");

  if (!isLinkStep(Args)) return;

  // Cache-key variant (cpu/opt/PIC + recipe-version tag): the on-demand libc /
  // libc++ / builtins are built and cached per variant.
  Variant V = parseVariant(Args, ti.triple);

  std::string dir = ensureSysroot(ti.triple, muslArch, headerTriple, V);
  if (dir.empty()) return; // build failed; let clang error naturally

  std::string cxxLib;
  if (cxx) cxxLib = ensureCxxRuntime(ti.triple, muslArch, headerTriple, V);

  // Self-contained static link: our crt1.o + libc.a + embedded ld.lld. We
  // bypass clang's auto-CRT (which wants crti/crtn/crtbegin we don't ship;
  // modern musl uses .init_array, so crt1.o + libc.a suffice). A -pie link is a
  // static-PIE: -static-pie (not plain -static, which would ignore -pie and
  // emit ET_EXEC) drives lld to an ET_DYN, self-relocating image — exactly what
  // musl's rcrt1.o startup expects (plain crt1.o otherwise).
  add(V.pie ? "-static-pie" : "-static");
  add("-nostdlib");
  add(Twine(dir) + "/lib/" + (V.pie ? "rcrt1.o" : "crt1.o"));
  add(Twine("-L") + dir + "/lib");
  if (!cxxLib.empty()) add(Twine("-L") + cxxLib);
  // One group: libc++ → libc++abi → libunwind → libc → builtins are mutually
  // referential (exceptions → unwind → libc; vfprintf → __divtf3; …), so let
  // the linker iterate the whole set.
  add("-Wl,--start-group");
  if (!cxxLib.empty()) {
    add("-lc++");
    add("-lc++abi");
    add("-lunwind");
  }
  add("-lc");
  add("-lclang_rt.builtins");
  add("-Wl,--end-group");
  add("-fuse-ld=lld");
  add(Twine("-B") + dir + "/bin");
}

} // namespace unpin
