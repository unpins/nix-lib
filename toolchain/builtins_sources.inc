//===-- builtins_sources.inc - compiler-rt builtins recipe ---------------===//
//
// Transcribed from compiler-rt/lib/builtins/CMakeLists.txt (LLVM 21.1.8) for
// the de-risk config: Linux / musl, NOT Apple / Windows / MSVC / Android /
// Fuchsia / baremetal / GPU; COMPILER_RT_ENABLE_SOFTWARE_INT128=OFF. BF16, SME,
// emupac and the int128-software path are omitted (niche; their absence only
// yields an undefined ref if actually used, never a miscompile). atomic.c IS
// included (compiler-rt EXCLUDE_ATOMIC_BUILTIN=ON omits it by default): as the
// sole static runtime we must provide the generic __atomic_load/store libcalls
// that 32-bit targets emit for 8-byte/misaligned atomics (openssl on
// i686/armv7l). Dead in the archive on 64-bit, where those atomics are
// lock-free inline — so 64-bit output stays byte-identical.
//
// The per-arch list is GENERIC + GENERIC_TF (+ x86 80-bit) + arch-specific
// files; the CMake `filter_builtin_sources` rule (an arch-subdir <stem>.{c,S}
// shadows the top-level generic <stem>.c) is applied at runtime in
// collectBuiltinSources(). Paths are relative to VROOT/compiler-rt/builtins.
//
//===----------------------------------------------------------------------===//

// GENERIC_SOURCES (CMakeLists 71-192) + the non-Apple/non-Fuchsia additions:
// emutls/enable_execute_stack/eprintf (239), gcc_personality_v0 (HAVE_UNWIND_H,
// 275 — clang ships unwind.h in its resource dir), clear_cache (282).
static const char *const kBuiltinsGeneric[] = {
    "absvdi2.c",      "absvsi2.c",       "absvti2.c",       "adddf3.c",
    "addsf3.c",       "addvdi3.c",       "addvsi3.c",       "addvti3.c",
    "apple_versioning.c", "ashldi3.c",   "ashlti3.c",       "ashrdi3.c",
    "ashrti3.c",      "bswapdi2.c",      "bswapsi2.c",      "clzdi2.c",
    "clzsi2.c",       "clzti2.c",        "cmpdi2.c",        "cmpti2.c",
    "comparedf2.c",   "comparesf2.c",    "ctzdi2.c",        "ctzsi2.c",
    "ctzti2.c",       "divdc3.c",        "divdf3.c",        "divdi3.c",
    "divmoddi4.c",    "divmodsi4.c",     "divmodti4.c",     "divsc3.c",
    "divsf3.c",       "divsi3.c",        "divti3.c",        "extendsfdf2.c",
    "extendhfsf2.c",  "extendhfdf2.c",   "ffsdi2.c",        "ffssi2.c",
    "ffsti2.c",       "fixdfdi.c",       "fixdfsi.c",       "fixdfti.c",
    "fixsfdi.c",      "fixsfsi.c",       "fixsfti.c",       "fixunsdfdi.c",
    "fixunsdfsi.c",   "fixunsdfti.c",    "fixunssfdi.c",    "fixunssfsi.c",
    "fixunssfti.c",   "floatdidf.c",     "floatdisf.c",     "floatsidf.c",
    "floatsisf.c",    "floattidf.c",     "floattisf.c",     "floatundidf.c",
    "floatundisf.c",  "floatunsidf.c",   "floatunsisf.c",   "floatuntidf.c",
    "floatuntisf.c",  "fp_mode.c",       "int_util.c",      "lshrdi3.c",
    "lshrti3.c",      "moddi3.c",        "modsi3.c",        "modti3.c",
    "muldc3.c",       "muldf3.c",        "muldi3.c",        "mulodi4.c",
    "mulosi4.c",      "muloti4.c",       "mulsc3.c",        "mulsf3.c",
    "multi3.c",       "mulvdi3.c",       "mulvsi3.c",       "mulvti3.c",
    "negdf2.c",       "negdi2.c",        "negsf2.c",        "negti2.c",
    "negvdi2.c",      "negvsi2.c",       "negvti2.c",       "os_version_check.c",
    "paritydi2.c",    "paritysi2.c",     "parityti2.c",     "popcountdi2.c",
    "popcountsi2.c",  "popcountti2.c",   "powidf2.c",       "powisf2.c",
    "subdf3.c",       "subsf3.c",        "subvdi3.c",       "subvsi3.c",
    "subvti3.c",      "trampoline_setup.c", "truncdfhf2.c",  "truncdfsf2.c",
    "truncsfhf2.c",   "ucmpdi2.c",       "ucmpti2.c",       "udivdi3.c",
    "udivmoddi4.c",   "udivmodsi4.c",    "udivmodti4.c",    "udivsi3.c",
    "udivti3.c",      "umoddi3.c",       "umodsi3.c",       "umodti3.c",
    // non-Apple / non-Fuchsia additions
    "emutls.c",       "enable_execute_stack.c", "eprintf.c", "gcc_personality_v0.c",
    "clear_cache.c",
    // generic __atomic_* libcalls (compiler-rt omits by default); 32-bit needs
    // them for 8-byte/misaligned atomics. See header. No arch-subdir shadow.
    "atomic.c",
};

// GENERIC_TF_SOURCES (203-230) — the 128-bit IEEE-quad (TFmode) soft-float
// routines printf needs where `long double` is binary128 (aarch64, riscv64).
static const char *const kBuiltinsGenericTF[] = {
    "addtf3.c",     "comparetf2.c", "divtc3.c",     "divtf3.c",
    "extenddftf2.c", "extendhftf2.c", "extendsftf2.c", "fixtfdi.c",
    "fixtfsi.c",    "fixtfti.c",    "fixunstfdi.c", "fixunstfsi.c",
    "fixunstfti.c", "floatditf.c",  "floatsitf.c",  "floattitf.c",
    "floatunditf.c", "floatunsitf.c", "floatuntitf.c", "multc3.c",
    "multf3.c",     "powitf2.c",    "subtf3.c",     "trunctfdf2.c",
    "trunctfhf2.c", "trunctfsf2.c",
};

// x86_80_BIT_SOURCES (303-320) — the 80-bit (XFmode) routines for x86 where
// `long double` is the 80-bit extended type (printf on x86_64 musl).
static const char *const kBuiltins80Bit[] = {
    "divxc3.c",     "extendhfxf2.c", "extendxftf2.c", "fixxfdi.c",
    "fixxfti.c",    "fixunsxfdi.c", "fixunsxfsi.c", "fixunsxfti.c",
    "floatdixf.c",  "floattixf.c",  "floatundixf.c", "floatuntixf.c",
    "mulxc3.c",     "powixf2.c",    "trunctfxf2.c", "truncxfhf2.c",
};

// x86_ARCH_SOURCES (290-299) + x86_64_SOURCES additions (323-350). chkstk.S is
// WIN32-only and omitted. floatdixf.c override comes from the 80-bit set.
static const char *const kBuiltinsX86_64[] = {
    "cpu_model/x86.c",   "i386/fp_mode.c",
    "x86_64/floatdidf.c", "x86_64/floatdisf.c",
    "x86_64/floatundidf.S", "x86_64/floatundisf.S",
    "x86_64/floatdixf.c", "x86_64/floatundixf.S",
};

// i386_SOURCES: x86_ARCH_SOURCES (cpu_model/x86.c + i386/fp_mode.c). The
// i386/*.S asm helpers (ashldi3/divdi3/…) are arch-tuned versions of GENERIC
// and are deliberately omitted — the generic C versions are functionally
// identical and this mirrors compiler-rt's own MSVC i386 set (GENERIC +
// x86_ARCH). 80-bit (XF) long double on i386 comes from kBuiltins80Bit.
static const char *const kBuiltinsI386[] = {
    "cpu_model/x86.c", "i386/fp_mode.c",
};

// arm_SOURCES for a Linux EABI target = arm_or_thumb2_base + arm_sync +
// arm_EABI. Critically the __aeabi_*divmod helpers (32/64-bit integer divide
// the hardware can't do) — without them lz4/xxhash's 64-bit arithmetic fails to
// link. The Thumb1/VFP alternates are omitted (armv7-a + VFP codegen inlines FP
// and uses the base/EABI integer helpers). 128-bit TF builtins self-guard to
// empty TUs on arm (long double == double), so kBuiltinsGenericTF is harmless.
static const char *const kBuiltinsArm[] = {
    // arm_or_thumb2_base_SOURCES
    "arm/fp_mode.c",     "arm/bswapdi2.S",  "arm/bswapsi2.S",
    "arm/clzdi2.S",      "arm/clzsi2.S",    "arm/comparesf2.S",
    "arm/divmodsi4.S",   "arm/divsi3.S",    "arm/modsi3.S",
    "arm/udivmodsi4.S",  "arm/udivsi3.S",   "arm/umodsi3.S",
    // arm_sync_SOURCES
    "arm/sync_fetch_and_add_4.S",  "arm/sync_fetch_and_add_8.S",
    "arm/sync_fetch_and_and_4.S",  "arm/sync_fetch_and_and_8.S",
    "arm/sync_fetch_and_max_4.S",  "arm/sync_fetch_and_max_8.S",
    "arm/sync_fetch_and_min_4.S",  "arm/sync_fetch_and_min_8.S",
    "arm/sync_fetch_and_nand_4.S", "arm/sync_fetch_and_nand_8.S",
    "arm/sync_fetch_and_or_4.S",   "arm/sync_fetch_and_or_8.S",
    "arm/sync_fetch_and_sub_4.S",  "arm/sync_fetch_and_sub_8.S",
    "arm/sync_fetch_and_umax_4.S", "arm/sync_fetch_and_umax_8.S",
    "arm/sync_fetch_and_umin_4.S", "arm/sync_fetch_and_umin_8.S",
    "arm/sync_fetch_and_xor_4.S",  "arm/sync_fetch_and_xor_8.S",
    // arm_EABI_RT_SOURCES + arm_EABI_CLIB_SOURCES
    "arm/aeabi_cdcmp.S",   "arm/aeabi_cdcmpeq_check_nan.c",
    "arm/aeabi_cfcmp.S",   "arm/aeabi_cfcmpeq_check_nan.c",
    "arm/aeabi_dcmp.S",    "arm/aeabi_div0.c",
    "arm/aeabi_drsub.c",   "arm/aeabi_fcmp.S",
    "arm/aeabi_frsub.c",   "arm/aeabi_idivmod.S",
    "arm/aeabi_ldivmod.S", "arm/aeabi_uidivmod.S",
    "arm/aeabi_uldivmod.S", "arm/aeabi_memcmp.S",
    "arm/aeabi_memcpy.S",  "arm/aeabi_memmove.S",
    "arm/aeabi_memset.S",
};

// aarch64_SOURCES (590-596). emupac.cpp (needs C++/siphash) and the SME ABI
// routines are omitted; outline-atomics helpers from lse.S are generated
// programmatically (see kOutlineAtomic* below).
static const char *const kBuiltinsAArch64[] = {
    "cpu_model/aarch64.c", "aarch64/fp_mode.c",
};

// riscv64_SOURCES (783-798): riscv_SOURCES + riscv/muldi3.S.
static const char *const kBuiltinsRiscv64[] = {
    "cpu_model/riscv.c", "riscv/fp_mode.c",
    "riscv/save.S",      "riscv/restore.S",
    "riscv/muldi3.S",
};

// AArch64 outline-atomics: lse.S is compiled once per (pattern,size,model)
// combination, skipping size 16 for everything but `cas` (CMakeLists 642-662).
static const char *const kOutlineAtomicPats[] = {
    "cas", "swp", "ldadd", "ldclr", "ldeor", "ldset",
};
static const int kOutlineAtomicSizes[] = {1, 2, 4, 8, 16};
static const int kOutlineAtomicModels[] = {1, 2, 3, 4, 5};
