# unpin-llvm: the standalone LLVM C/C++ suite (clang + clang++ + lld + llvm-*)
# as ONE self-contained static-musl multicall binary, with an on-demand,
# variant-aware musl/libc++ sysroot embedded as an in-binary VFS.
#
# Versioned together with nix-lib (zero new flake inputs): LLVM monorepo source
# is `origPkgs.llvmPackages_21.libllvm.monorepoSrc`, the recipe (unpin_*.cpp/.h,
# *_sources.inc, cxx_config_site*.h) is committed alongside this file, and the
# VFS packer is nix-lib's own `lib.unpinPackTool`.
#
# Build LOCALLY only (static LLVM 21 is a >120 G / multi-hour uncached build).
# Lazy: nothing forces this unless a consumer calls `lib.mkUnpinStdenv`.
{ origPkgs, unpinPackTool }:
        let
          pkgs = origPkgs.pkgsStatic;
          version = "21.1.8";
          major = pkgs.lib.versions.major version; # "21"
          # Platform-independent source, so take it from the non-static set.
          monorepoSrc = origPkgs.llvmPackages_21.libllvm.monorepoSrc;
          hostCfg = pkgs.stdenv.hostPlatform.config; # x86_64-unknown-linux-musl
          isDarwin = pkgs.stdenv.hostPlatform.isDarwin;

          # The embedded musl libc tree (M2 payload):
          #   * zig 0.16's lib/libc = the GENERATED per-arch musl headers
          #     (alltypes.h/syscall.h/version.h in include/<triple>) + the Linux
          #     kernel UAPI headers — the hard-to-regenerate parts.
          #   * upstream musl 1.2.5 tarball = the COMPLETE committed musl tree
          #     (src/arch/crt/include/compat), overlaid UPSTREAM-WINS below so the
          #     on-demand libc is full (malloc/thread/… not just printf-class).
          # buildLibc selects by replicating musl's Makefile.
          zigLibc = "${origPkgs.zig_0_16.src}/lib/libc";
          muslTar = origPkgs.musl.src;

          # Recipe/version stamp baked in as UNPIN_CACHE_TAG and folded into the
          # on-demand cache key (Variant in unpin_musl.cpp). Must change whenever
          # anything affecting the built libc/libc++/builtins changes, so a new
          # binary never reuses a stale cached library — hence hashing the recipe
          # plus the embedded source store paths.
          cacheTag = builtins.substring 0 16 (builtins.hashString "sha256"
            (builtins.concatStringsSep ":" [
              version
              (builtins.hashFile "sha256" ./unpin_musl.cpp)
              (builtins.hashFile "sha256" ./musl_sources.inc)
              (builtins.hashFile "sha256" ./builtins_sources.inc)
              (builtins.hashFile "sha256" ./cxx_sources.inc)
              (builtins.hashFile "sha256" ./mingw_sources.inc)
              (builtins.hashFile "sha256" ./cxx_config_site.h)
              (builtins.hashFile "sha256" ./cxx_config_site_win.h)
              (builtins.hashFile "sha256" ./cxx_config_site_darwin.h)
              (toString monorepoSrc)
              (toString zigLibc)
              (toString muslTar)
            ]));

          # Build-host-native packer (zstd-in-zip, ZIP method 93). Build-only;
          # never linked in. Driven DIRECTLY (no dict) because our in-binary
          # reader is one-shot ZSTD_decompress.
          packTool = unpinPackTool origPkgs;
        in
        (pkgs.stdenv.mkDerivation {
          pname = "unpin-llvm";
          inherit version;
          src = monorepoSrc;
          sourceRoot = "${monorepoSrc.name}/llvm";

          # M1: unpins in-binary VFS — clang half. cwd is the `llvm` sourceRoot,
          # so clang is the sibling `../clang`.
          postPatch = ''
            # Only the `llvm` sourceRoot is unpacked writable; the sibling
            # clang/ subtree keeps read-only store perms. Make the driver dir
            # writable so we can drop files in and substituteInPlace them.
            chmod -R u+w ../clang/tools/driver

            cp ${./unpin_clang_vfs.cpp} ../clang/tools/driver/unpin_clang_vfs.cpp
            cp ${./unpin_clang_vfs.h}   ../clang/tools/driver/unpin_clang_vfs.h
            cp ${./unpin_vfs_core.cpp}  ../clang/tools/driver/unpin_vfs_core.cpp
            cp ${./unpin_vfs_core.h}    ../clang/tools/driver/unpin_vfs_core.h
            # M2: on-demand musl sysroot builder + driver front.
            cp ${./unpin_musl.cpp}        ../clang/tools/driver/unpin_musl.cpp
            cp ${./unpin_musl.h}          ../clang/tools/driver/unpin_musl.h
            cp ${./musl_sources.inc}      ../clang/tools/driver/musl_sources.inc
            # M3: compiler-rt builtins recipe (#included by unpin_musl.cpp).
            cp ${./builtins_sources.inc}  ../clang/tools/driver/builtins_sources.inc
            # M4: C++ runtime recipe (libc++/libc++abi/libunwind file lists).
            cp ${./cxx_sources.inc}       ../clang/tools/driver/cxx_sources.inc
            # Windows: mingw-w64 runtime recipe (#included by unpin_musl.cpp).
            cp ${./mingw_sources.inc}     ../clang/tools/driver/mingw_sources.inc
            # Recipe/version stamp for the on-demand cache key (UNPIN_CACHE_TAG).
            echo '#define UNPIN_CACHE_TAG "${cacheTag}"' \
              > ../clang/tools/driver/unpin_build_tag.h

            # Register the TUs into the driver target (folds into `llvm`).
            substituteInPlace ../clang/tools/driver/CMakeLists.txt \
              --replace-fail '  cc1gen_reproducer_main.cpp' \
                '  cc1gen_reproducer_main.cpp
  unpin_clang_vfs.cpp
  unpin_vfs_core.cpp
  unpin_musl.cpp'

            # Patch 1 — cc1: diagnostics on the overlay + pre-create the
            # FileManager on it before ExecuteCompilerInvocation (else the action
            # recreates it on RealFS and the embedded headers are invisible).
            substituteInPlace ../clang/tools/driver/cc1_main.cpp \
              --replace-fail '#include "llvm/Support/VirtualFileSystem.h"' \
                '#include "llvm/Support/VirtualFileSystem.h"
#include "unpin_clang_vfs.h"' \
              --replace-fail 'Clang->createDiagnostics(*llvm::vfs::getRealFileSystem());' \
                'Clang->createDiagnostics(*unpin::overlayBaseFS());' \
              --replace-fail '  if (!Clang->hasDiagnostics())
    return 1;' \
                '  if (!Clang->hasDiagnostics())
    return 1;

  // unpins VFS: expose the embedded resource/sysroot tree to clang lookups.
  Clang->createFileManager(createVFSFromCompilerInvocation(
      Clang->getInvocation(), Clang->getDiagnostics(), unpin::overlayBaseFS()));'

            # Patch 2 — driver: construct the Driver on the overlay so input
            # existence + toolchain lookups see VROOT, AND run the M2 musl front
            # at the top of clang_main (right after the StringSaver is set up,
            # before the -cc1 dispatch; the front itself bails on -cc1/native).
            substituteInPlace ../clang/tools/driver/driver.cpp \
              --replace-fail '#include "llvm/Support/VirtualFileSystem.h"' \
                '#include "llvm/Support/VirtualFileSystem.h"
#include "unpin_clang_vfs.h"
#include "unpin_musl.h"' \
              --replace-fail 'auto VFS = llvm::vfs::getRealFileSystem();' \
                'auto VFS = unpin::overlayBaseFS();' \
              --replace-fail '  llvm::StringSaver Saver(A);' \
                '  llvm::StringSaver Saver(A);
  unpin::frontRewriteMusl(Args, Saver);'

            # Patch 3 — cc1as: read assembler inputs (embedded musl crti/crtn .s)
            # through the overlay; keep stdin ("-").
            substituteInPlace ../clang/tools/driver/cc1as_main.cpp \
              --replace-fail '#include "llvm/Support/MemoryBuffer.h"' \
                '#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Support/VirtualFileSystem.h"
#include "unpin_clang_vfs.h"' \
              --replace-fail 'MemoryBuffer::getFileOrSTDIN(Opts.InputFile, /*IsText=*/true);' \
                '(Opts.InputFile == "-")
          ? MemoryBuffer::getFileOrSTDIN(Opts.InputFile, /*IsText=*/true)
          : unpin::overlayBaseFS()->getBufferForFile(Opts.InputFile);'

            # Patch 4 — fold the REAL upstream `opt` + `llvm-link` into the `llvm`
            # multicall driver (GENERATE_DRIVER). They are the two IR tools the
            # bitcode-LTO module-folding pipeline needs: llvm-link merges a
            # program's .bc objects + internal archives into one module, then
            # `opt -internalize -internalize-public-api-list=<renamed-main>`
            # localizes everything but the entry. The toolchain is user-installable
            # so these MUST be the genuine upstream tools, not bespoke subcommands.
            #
            # The single binary links ALL tools' objects into one process, so every
            # tool's GLOBAL cl::opt registers at static init into a SubCommand's
            # OptionsMap; a duplicate name in the same SubCommand aborts the binary
            # (report_fatal_error). opt and llvm-link share -o/-S/-f/-disable-verify,
            # so they cannot both sit in TopLevel. opt must stay in TopLevel (it
            # needs the IPO-registered -internalize-public-api-list and the pass/
            # codegen knobs that live there); llvm-link gets every option scoped
            # under a dedicated cl::SubCommand instead. The driver invokes each tool
            # as `<tool> <args>` with no subcommand keyword, so llvm_link_main
            # splices the subcommand name in as argv[1] to activate it.

            # opt: drop the standalone LLVMOptDriver lib + host-tool wiring; compile
            # optdriver.cpp/NewPMDriver.cpp straight into obj.opt so optMain is
            # defined in the driver objlib (the lib was only reachable via the
            # standalone exe's target_link_libraries, which GENERATE_DRIVER skips).
            # SUPPORT_PLUGINS/EXPORT_SYMBOLS are add_llvm_executable-only and would
            # be mis-parsed as source files by generate_llvm_objects — drop them.
            substituteInPlace tools/opt/CMakeLists.txt \
              --replace-fail '# We don'"'"'t want to link this into libLLVM
add_llvm_library(LLVMOptDriver
  STATIC
  NewPMDriver.cpp
  optdriver.cpp
  PARTIAL_SOURCES_INTENDED
  DEPENDS
  intrinsics_gen
)

add_llvm_tool(opt
  PARTIAL_SOURCES_INTENDED
  opt.cpp
  DEPENDS
  intrinsics_gen
  SUPPORT_PLUGINS

  EXPORT_SYMBOLS
  )
target_link_libraries(opt PRIVATE LLVMOptDriver)

setup_host_tool(opt OPT opt_exe opt_target)' \
                'add_llvm_tool(opt
  PARTIAL_SOURCES_INTENDED
  opt.cpp
  optdriver.cpp
  NewPMDriver.cpp
  DEPENDS
  intrinsics_gen
  GENERATE_DRIVER
  )'

            # opt.cpp: entry becomes opt_main(argc,argv,ToolContext); the driver
            # template provides main + InitLLVM.
            substituteInPlace tools/opt/opt.cpp \
              --replace-fail '#include "llvm/ADT/ArrayRef.h"
#include <functional>' \
                '#include "llvm/ADT/ArrayRef.h"
#include "llvm/Support/LLVMDriver.h"
#include <functional>' \
              --replace-fail 'int main(int argc, char **argv) { return optMain(argc, argv, {}); }' \
                'int opt_main(int argc, char **argv, const llvm::ToolContext &) {
  return optMain(argc, argv, {});
}'

            # optdriver.cpp: (1) the driver's main already ran InitLLVM; a second
            # here would nest a redundant llvm_shutdown over the driver's. (2)
            # PluginLoader.h instantiates a `-load` cl::opt in an anon namespace
            # per-TU (it is the ONLY header-instantiated cl::opt in the tree, and
            # its own comment says "include by a program ONCE"). lld.cpp already
            # instantiates it in the shared `llvm` binary, so opt's copy collides
            # at static init ("Option 'load' registered more than once"), aborting
            # EVERY invocation. opt only needs it to register that legacy
            # pass-plugin flag, which the internalize pipeline never uses — define
            # DONT_GET_PLUGIN_LOADER_OPTION to drop opt's copy; lld keeps -load.
            substituteInPlace tools/opt/optdriver.cpp \
              --replace-fail '  InitLLVM X(argc, argv);

  // Enable debug stream buffering.' \
                '  // InitLLVM is performed by the llvm multicall driver (opt is folded
  // into `llvm` via GENERATE_DRIVER); doing it again here would nest a
  // second llvm_shutdown over the driver'"'"'s.

  // Enable debug stream buffering.' \
              --replace-fail '#include "llvm/Support/PluginLoader.h"' \
                '#define DONT_GET_PLUGIN_LOADER_OPTION
#include "llvm/Support/PluginLoader.h"'

            # NewPMDriver.cpp (folded into obj.opt): clang's BackendUtil.cpp
            # (clangCodeGen, linked into the driver via cc1) registers an IDENTICAL
            # `-pgo-cold-func-opt` cl::opt (its own comment: "Experiment ... TODO:
            # remove once exposed as a proper driver flag"). Two copies in TopLevel
            # → static-init "registered more than once" abort. Keep clang's as the
            # sole owner and demote opt's duplicate to a plain default-valued
            # variable: opt's pipeline code still reads it, the Hidden experimental
            # knob is one the internalize pipeline never sets, and
            # `clang -mllvm -pgo-cold-func-opt` keeps working.
            substituteInPlace tools/opt/NewPMDriver.cpp \
              --replace-fail 'static cl::opt<PGOOptions::ColdFuncOpt> PGOColdFuncAttr(
    "pgo-cold-func-opt", cl::init(PGOOptions::ColdFuncOpt::Default), cl::Hidden,
    cl::desc(
        "Function attribute to apply to cold functions as determined by PGO"),
    cl::values(clEnumValN(PGOOptions::ColdFuncOpt::Default, "default",
                          "Default (no attribute)"),
               clEnumValN(PGOOptions::ColdFuncOpt::OptSize, "optsize",
                          "Mark cold functions with optsize."),
               clEnumValN(PGOOptions::ColdFuncOpt::MinSize, "minsize",
                          "Mark cold functions with minsize."),
               clEnumValN(PGOOptions::ColdFuncOpt::OptNone, "optnone",
                          "Mark cold functions with optnone.")));' \
                '// -pgo-cold-func-opt is owned by clang BackendUtil.cpp in the folded
// `llvm` binary; this demoted copy avoids a duplicate cl::opt registration.
static PGOOptions::ColdFuncOpt PGOColdFuncAttr = PGOOptions::ColdFuncOpt::Default;'

            # llvm-link: fold into the driver too.
            substituteInPlace tools/llvm-link/CMakeLists.txt \
              --replace-fail 'add_llvm_tool(llvm-link
  llvm-link.cpp

  DEPENDS
  intrinsics_gen
  )

setup_host_tool(llvm-link LLVM_LINK llvm_link_exe llvm_link_target)' \
                'add_llvm_tool(llvm-link
  llvm-link.cpp

  DEPENDS
  intrinsics_gen
  GENERATE_DRIVER
  )'

            # llvm-link.cpp: (1) pull in ToolContext + <vector>; (2) declare the
            # LinkSub subcommand right after LinkCategory (before the options that
            # reference it); (3) scope EVERY option under LinkSub (all but one
            # carry cl::cat(LinkCategory) — append cl::sub there; patch the lone
            # IgnoreNonBitcode separately); (4) entry becomes llvm_link_main, drop
            # InitLLVM, splice the subcommand name as argv[1] before parsing.
            substituteInPlace tools/llvm-link/llvm-link.cpp \
              --replace-fail '#include "llvm/Support/InitLLVM.h"' \
                '#include "llvm/Support/InitLLVM.h"
#include "llvm/Support/LLVMDriver.h"' \
              --replace-fail '#include <memory>
#include <utility>' \
                '#include <memory>
#include <utility>
#include <vector>' \
              --replace-fail 'static cl::OptionCategory LinkCategory("Link Options");' \
                'static cl::OptionCategory LinkCategory("Link Options");

// Folded into the `llvm` multicall driver: scope every llvm-link option under a
// dedicated subcommand so its names (-o/-S/-f/-disable-verify/...) do not collide
// at static init with opt'"'"'s identically-named options in the shared binary.
static constexpr const char *LinkSubName = "__unpin_llvm_link";
static cl::SubCommand LinkSub(LinkSubName, "Link LLVM bitcode/IR modules");' \
              --replace-fail 'cl::cat(LinkCategory)' 'cl::cat(LinkCategory), cl::sub(LinkSub)' \
              --replace-fail 'cl::desc("Do not report an error for non-bitcode files in archives"),
    cl::Hidden);' \
                'cl::desc("Do not report an error for non-bitcode files in archives"),
    cl::Hidden, cl::sub(LinkSub));' \
              --replace-fail 'int main(int argc, char **argv) {
  InitLLVM X(argc, argv);
  ExitOnErr.setBanner(std::string(argv[0]) + ": ");

  cl::HideUnrelatedOptions({&LinkCategory, &getColorCategory()});
  cl::ParseCommandLineOptions(argc, argv, "llvm linker\n");' \
                'int llvm_link_main(int argc, char **argv, const llvm::ToolContext &) {
  // InitLLVM is done by the llvm multicall driver. Our options live under the
  // LinkSub subcommand; the driver hands us `llvm-link <args...>` with no
  // subcommand keyword, so splice LinkSubName in as argv[1] to activate it.
  const char *Argv0 = argc > 0 ? argv[0] : "llvm-link";
  ExitOnErr.setBanner(std::string(Argv0) + ": ");

  std::vector<const char *> LinkArgv;
  LinkArgv.reserve(argc + 1);
  LinkArgv.push_back(Argv0);
  LinkArgv.push_back(LinkSubName);
  for (int I = 1; I < argc; ++I)
    LinkArgv.push_back(argv[I]);

  cl::HideUnrelatedOptions({&LinkCategory, &getColorCategory()});
  cl::ParseCommandLineOptions(static_cast<int>(LinkArgv.size()),
                              LinkArgv.data(), "llvm linker\n");'
          '';

          nativeBuildInputs = [
            origPkgs.buildPackages.cmake
            origPkgs.buildPackages.ninja
            origPkgs.buildPackages.python3
          ];
          # Static deps only. zstd is needed at final link for the M1 VFS reader.
          # No libxml2 (static-link breakage upstream), no ncurses, no libffi.
          buildInputs = [ pkgs.zlib pkgs.zstd ];

          cmakeBuildType = "Release";

          # NOTE: semicolons are CMake list separators — keep each as ONE arg.
          cmakeFlags = [
            "-DLLVM_ENABLE_PROJECTS=clang;lld"
            "-DLLVM_TOOL_LLVM_DRIVER_BUILD=ON"
            # All catalog backends: X86 (x86_64+i686), AArch64, ARM (armv7l),
            # PowerPC (ppc64le), RISCV (riscv64).
            "-DLLVM_TARGETS_TO_BUILD=X86;AArch64;ARM;PowerPC;RISCV"
            "-DLLVM_HOST_TRIPLE=${hostCfg}"
            "-DLLVM_DEFAULT_TARGET_TRIPLE=${hostCfg}"
          ]
          # Static link (mirrors nixpkgs' isStatic branch). Skipped on darwin:
          # no static libSystem, and LLVM_BUILD_STATIC=ON appends `-static` which
          # ld64 rejects → every link probe fails. Darwin still links
          # libc++/zlib/zstd from pkgsStatic .a's (only libSystem dynamic).
          ++ pkgs.lib.optionals (!isDarwin) [
            "-DLLVM_ENABLE_PIC=OFF"
            "-DLLVM_BUILD_STATIC=ON"
          ] ++ [
            "-DCMAKE_SKIP_INSTALL_RPATH=ON"
            "-DLLVM_ENABLE_LIBXML2=OFF"
            "-DLLVM_ENABLE_TERMINFO=OFF"
            "-DLLVM_ENABLE_ZSTD=FORCE_ON"
            "-DLLVM_ENABLE_ZLIB=FORCE_ON"
            "-DLLVM_ENABLE_RTTI=ON"
            "-DLLVM_ENABLE_FFI=OFF"
            # trim everything we don't ship
            "-DLLVM_INCLUDE_TESTS=OFF"
            "-DLLVM_BUILD_TESTS=OFF"
            "-DLLVM_INCLUDE_BENCHMARKS=OFF"
            "-DLLVM_INCLUDE_EXAMPLES=OFF"
            "-DLLVM_ENABLE_BINDINGS=OFF"
            "-DLLVM_INSTALL_UTILS=OFF"
            "-DCLANG_INCLUDE_TESTS=OFF"
            "-DCLANG_INCLUDE_DOCS=OFF"
            "-DLLVM_INCLUDE_DOCS=OFF"
          ];

          hardeningDisable = [ "trivialautovarinit" "shadowstack" ];

          # Build ONLY the multicall driver + clang resource headers. The default
          # `all` target also builds peripheral clang tools needing a shared
          # libclang, which doesn't exist in a PIC=OFF static build → `all` fails
          # at `-llibclang_static`; we ship none of them anyway.
          ninjaFlags = [ "llvm-driver" "clang-resource-headers" ];

          # The driver binary is `bin/llvm` (dispatches on argv[0]). The
          # clang/clang++/ld.lld/llvm-* faces are embedded as `unpin/aliases` ZIP
          # entries, not materialized in $out/bin — unpin recreates them as
          # argv[0] symlinks at install. The resource dir stays on disk here;
          # postFixup embeds it into the VFS and deletes it.
          installPhase = ''
            runHook preInstall
            mkdir -p "$out/bin" "$out/lib"
            cp bin/llvm "$out/bin/llvm"
            cp -r lib/clang "$out/lib/clang"
            runHook postInstall
          '';

          # postFixup runs AFTER stdenv strip, so the ZIP we append survives.
          # (1) nuke-refs the ELF (in place, same length); (2) stage the embedded
          # tree (M1 resource headers + M2 musl + `unpin/aliases`); (3) pack it
          # into the binary's single EOF ZIP (NO --dict; --deflate for
          # `unpin/aliases` so pre-zstd readers decode it); (4) drop the on-disk
          # resource dir so the VFS is the only source. VROOT = /__unpin_ziglib__;
          # the M2 front adds -resource-dir VROOT/clang-resource and -I VROOT/libc.
          postFixup = ''
            chmod +w "$out/bin/llvm"
            ${origPkgs.buildPackages.nukeReferences}/bin/nuke-refs "$out/bin/llvm"

            __stage=$(mktemp -d)

            # M1 — clang builtin + compiler-rt headers (this build's resource dir).
            mkdir -p "$__stage/clang-resource"
            cp -r "$out/lib/clang/${major}/include" "$__stage/clang-resource/include"

            # M2 — the musl libc tree: the whole zig lib/libc/musl subtree
            # (arch/, src/, include/, crt/) + the per-target & generic-musl
            # header sets. unpin_musl.cpp's libcRoot() = VROOT/libc and
            # addCcArgs() -I's into exactly these dirs.
            mkdir -p "$__stage/libc/include"
            cp -r "${zigLibc}/musl" "$__stage/libc/musl"
            chmod -R u+w "$__stage/libc/musl"
            # Full-libc: overlay the COMPLETE upstream musl 1.2.5 committed tree,
            # UPSTREAM WINS. zig's embedded subset omits malloc/ entirely and
            # *patches* internal headers for its malloc-less world (e.g.
            # src/include/stdlib.h drops the hidden __libc_free/__libc_malloc_impl
            # decls), so the curated tree only linked printf-class programs.
            # Overwriting src/arch/crt/include/compat with pure upstream restores
            # a consistent libc that buildLibc selects from by replicating musl's
            # Makefile (walks the VFS, picks mallocng, arch-shadows generics). The
            # GENERATED headers (libc/include/<triple>, generic-musl —
            # alltypes.h/syscall.h/version.h) live outside musl/ and stay zig's.
            __up=$(mktemp -d)
            tar xf "${muslTar}" -C "$__up" --strip-components=1
            for __sub in src arch crt include compat; do
              [ -d "$__up/$__sub" ] || continue
              ( cd "$__up/$__sub" && find . -type f \
                  \( -name '*.c' -o -name '*.s' -o -name '*.S' \
                     -o -name '*.h' -o -name '*.in' \) ) | \
              while read -r __rel; do
                __rel=''${__rel#./}
                __dst="$__stage/libc/musl/$__sub/$__rel"
                mkdir -p "$(dirname "$__dst")"; cp "$__up/$__sub/$__rel" "$__dst"
              done
            done
            rm -rf "$__up"
            cp -r "${zigLibc}/include/generic-musl" "$__stage/libc/include/generic-musl"
            # Header arch tokens are zig's std.zig.target names (headerArchName in
            # unpin_musl.cpp): 32-bit x86 is "x86" (not musl's "i386"); arm and
            # powerpc64 match the musl folder name.
            for __t in x86_64 x86 aarch64 arm riscv64 powerpc64; do
              cp -r "${zigLibc}/include/$__t-linux-musl" "$__stage/libc/include/$__t-linux-musl"
            done
            # Linux kernel UAPI headers (<linux/futex.h>, <asm/…>) — needed by
            # libc++'s atomic.cpp (futex) and user code talking to the kernel.
            # zig's arch token differs from muslArch (x86_64→x86, riscv64→riscv);
            # any-linux-any is the arch-independent set. addKernelIncludes() maps.
            for __k in x86-linux-any aarch64-linux-any arm-linux-any riscv-linux-any powerpc-linux-any any-linux-any; do
              cp -r "${zigLibc}/include/$__k" "$__stage/libc/include/$__k"
            done

            # M3 — the compiler-rt builtins source tree (compiled on demand per
            # target into libclang_rt.builtins.a: soft-float TF/XF, int128,
            # aarch64 outline atomics, …). Sourced from the same monorepo.
            mkdir -p "$__stage/compiler-rt"
            cp -r "${monorepoSrc}/compiler-rt/lib/builtins" "$__stage/compiler-rt/builtins"

            # M4 — the C++ runtime source trees (libc++/libc++abi/libunwind),
            # compiled on demand per target into libc++.a/libc++abi.a/
            # libunwind.a. Sourced from OUR monorepo (version-matched), recipe
            # from zig. cxx/libc is the llvm-libc shim libc++ src pulls in
            # (shared/fp_bits.h, …). __config_site + __assertion_handler are the
            # two CMake-generated headers — we ship a resolved __config_site and
            # a verbatim default __assertion_handler so upstream __config /
            # __assert stay unpatched.
            mkdir -p "$__stage/cxx"
            cp -r "${monorepoSrc}/libcxx"    "$__stage/cxx/libcxx"
            cp -r "${monorepoSrc}/libcxxabi" "$__stage/cxx/libcxxabi"
            cp -r "${monorepoSrc}/libunwind" "$__stage/cxx/libunwind"
            mkdir -p "$__stage/cxx/libc/src"
            cp -r "${monorepoSrc}/libc/shared"        "$__stage/cxx/libc/shared"
            cp -r "${monorepoSrc}/libc/hdr"           "$__stage/cxx/libc/hdr"
            cp -r "${monorepoSrc}/libc/include"       "$__stage/cxx/libc/include"
            cp -r "${monorepoSrc}/libc/src/__support" "$__stage/cxx/libc/src/__support"
            chmod -R u+w "$__stage/cxx"
            cp ${./cxx_config_site.h} "$__stage/cxx/libcxx/include/__config_site"
            cp "${monorepoSrc}/libcxx/vendor/llvm/default_assertion_handler.in" \
               "$__stage/cxx/libcxx/include/__assertion_handler"
            # Windows libc++ __config_site (musl=0, win32 threads, no tzdb) on its
            # own dir, put ahead of the musl copy for Windows C++ compiles.
            mkdir -p "$__stage/cxx/win"
            cp ${./cxx_config_site_win.h} "$__stage/cxx/win/__config_site"
            # macOS libc++ __config_site (musl=0, no tzdb; pthread threads) on its
            # own dir, ahead of the musl copy for darwin C++ compiles.
            mkdir -p "$__stage/cxx/darwin"
            cp ${./cxx_config_site_darwin.h} "$__stage/cxx/darwin/__config_site"

            # Windows/mingw-w64: runtime tree (→ libmingw32.a + crt2.o on demand;
            # import libs from the embedded .def via dlltool) + any-windows-any
            # user headers. lib32/libarm32 (i386/arm .def) skipped — x86_64 only.
            mkdir -p "$__stage/libc/mingw"
            for __d in crt complex gdtoa intrincs cfguard libsrc math misc stdio \
                       string winpthreads include def-include lib64 lib-common; do
              [ -d "${zigLibc}/mingw/$__d" ] && \
                cp -r "${zigLibc}/mingw/$__d" "$__stage/libc/mingw/$__d"
            done
            cp -r "${zigLibc}/include/any-windows-any" \
               "$__stage/libc/include/any-windows-any"

            # macOS/darwin: the any-darwin-any user headers (libc/POSIX/Darwin C
            # surface, vendored from Apple's open-source SDK) + the libSystem.tbd
            # umbrella stub (the whole libc — linked via -lSystem; it inlines
            # every reexported sub-lib's symbols). No libc.a is built; only
            # compiler-rt builtins per arch on demand. zig's SDKSettings.json is
            # skipped — its minimal content only fails clang's SDK-settings parse.
            cp -r "${zigLibc}/include/any-darwin-any" \
               "$__stage/libc/include/any-darwin-any"
            mkdir -p "$__stage/libc/darwin"
            cp "${zigLibc}/darwin/libSystem.tbd" "$__stage/libc/darwin/libSystem.tbd"

            # Aliases — argv[0] faces unpin materializes at install. Newline-
            # separated, no trailing newline (matches withUnpinEmbed's writer).
            mkdir -p "$__stage/unpin"
            printf 'clang\nclang++\ncc\nc++\nld.lld\nllvm-ar\nllvm-ranlib\nllvm-nm\nllvm-objcopy\nllvm-strip\nopt\nllvm-link' \
              > "$__stage/unpin/aliases"

            chmod -R u+w "$__stage"
            __vfs_base=$(wc -c < "$out/bin/llvm")
            __vfs_zip=$(mktemp -d)
            ${packTool}/bin/unpin-vfs-pack "$__vfs_zip/payload.zip" "$__stage" \
              --base "$__vfs_base" --deflate unpin/aliases >/dev/null
            cat "$__vfs_zip/payload.zip" >> "$out/bin/llvm"
            rm -rf "$__stage" "$__vfs_zip"

            # Prove the VFS is the only source.
            rm -rf "$out/lib/clang"
            rmdir "$out/lib" 2>/dev/null || true

            # Collapse the runtime closure to just this binary. The stripped ELF
            # has ZERO store references (nuke-refs above; the static zlib/zstd are
            # linked in — their bytes live in the binary, not as deps), but stdenv
            # leaves a nix-support/propagated-build-inputs listing the zlib/zstd
            # -dev inputs, which drags their whole closures (musl/pcre2/bash/…) into
            # the runtime closure — ~22 paths for a "self-contained" binary. Same
            # self-contained-vs-metadata gap as the lsof recipe; drop it.
            rm -f "$out/nix-support/propagated-build-inputs"
            rmdir "$out/nix-support" 2>/dev/null || true
          '';

          meta = {
            description = "LLVM C/C++ suite (clang, lld, llvm-tools) as a single self-contained binary";
            license = origPkgs.lib.licenses.ncsa; # placeholder; real: Apache-2.0 WITH LLVM-exception
            platforms = origPkgs.lib.platforms.linux ++ origPkgs.lib.platforms.darwin;
          };
        }).overrideAttrs (_: { stripAllList = [ "bin" "out" ]; })
