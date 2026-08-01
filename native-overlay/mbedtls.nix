# Make nixpkgs mbedtls build under the unpin engine cc. The engine stdenv's `cc`
# is clang 21 but is detected as GNU, so nixpkgs'
# pkgs/by-name/mb/mbedtls/generic.nix picks the wrong compiler paths:
#
#  1. configure: the isGNU branch adds
#     `-DCMAKE_C_FLAGS=-fzero-init-padding-bits=unions` (a GCC-15-only union-init
#     workaround). clang rejects it with `error: unknown argument`, so mbedtls's
#     CMake compiler check fails before configure ends. Drop it — clang has no
#     such miscompile and never supported the flag. Gated on the engine cc so a
#     set built by a REAL gcc keeps the hardening flag it legitimately asked for.
#
#  2. test: the engine clang miscompiles ONE self-test — pem-suite's "valid EC
#     key encoded with AES-128-CBC", a bogus PEM_PASSWORD_MISMATCH. It is the lone
#     failure out of 139 suites: every crypto PRIMITIVE KAT passes (aes.cbc/ctr/ecb,
#     cipher.*, gcm.*, md/mdx (MD5), shax, pkcs5/PBKDF2), and the bug sits in
#     mbedtls's legacy PEM private-key parser (MD5-KDF) — a path the consumers
#     never invoke. Keep doCheck ON and keep the other 138 suites gating; exclude
#     only pem-suite.
#
#  3. postConfigure (darwin): nixpkgs runs `perl scripts/config.pl set …` to turn
#     threading on. Under the darwin engine cmake builds OUT of source (CWD =
#     build/, `scripts/` one level up) whereas linux builds in-source, so the
#     relative path misses. Run it from wherever `config.pl` actually is.
#
# Wired on `isStatic`, not `isMusl`: the fix was written for tar (linux-only, since
# darwin/windows libarchive build --without-mbedtls), but ffmpeg links mbedtls on
# DARWIN too, where the musl gate left the engine cc facing the gcc-only flag. The
# compiler is the same clang on both, so the gate belongs on the property that
# actually selects the engine scope. Linux keeps its hash (musl-static is static).
#
# NOT here: disabling ENABLE_PROGRAMS/ENABLE_TESTING on darwin. mbedtls' demos and
# tests build with -Werror and used to die on the inert `-static-libgcc` darwin
# pkgsStatic injected — that flag is now dropped at the stdenv (flake.nix,
# dropStaticLibgccHook), so the programs build and the suite runs on darwin too.
# librist/srt still carry their own copy of the old workaround: they build mbedtls
# from the PRISTINE pkgsStatic with only the stdenv swapped, so they never pass
# through this scope OR that hook.
{ lib }:
{
  autoWire = "static";
  apply = pkgs:
    let
      isEngine = lib.isUnpinEngine pkgs;
      isDarwin = pkgs.stdenv.hostPlatform.isDarwin or false;
    in
    pkgs.mbedtls.overrideAttrs (oa: {
      cmakeFlags =
        if isEngine
        then
          builtins.filter
            (f: !(lib.hasInfix "zero-init-padding-bits" (toString f)))
            (oa.cmakeFlags or [ ])
        else oa.cmakeFlags or [ ];
      checkPhase = ''
        runHook preCheck
        ctest --output-on-failure --exclude-regex '^pem-suite$'
        runHook postCheck
      '';
    } // lib.optionalAttrs isDarwin {
      postConfigure = ''
        __d=$PWD
        [ -f scripts/config.pl ] || cd ..
        ${oa.postConfigure or ""}
        cd "$__d"
      '';
    });
}
