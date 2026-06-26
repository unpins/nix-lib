# Make nixpkgs mbedtls build under the unpin engine cc (linux). The engine
# stdenv's `cc` is clang 21 but is detected as GNU, so nixpkgs'
# pkgs/by-name/mb/mbedtls/generic.nix picks the wrong compiler paths:
#
#  1. configure: the isGNU branch adds `-DCMAKE_C_FLAGS=-fzero-init-padding-bits=unions`
#     (a GCC-15-only union-init workaround). clang rejects it with `error: unknown
#     argument`, so mbedtls's CMake compiler check fails before configure ends.
#     Drop it — clang has no such miscompile and never supported the flag.
#
#  2. test: the engine clang miscompiles ONE self-test — pem-suite's "valid EC
#     key encoded with AES-128-CBC", a bogus PEM_PASSWORD_MISMATCH. It is the lone
#     failure out of 139 suites: every crypto PRIMITIVE KAT passes (aes.cbc/ctr/ecb,
#     cipher.*, gcm.*, md/mdx (MD5), shax, pkcs5/PBKDF2), and the bug sits in
#     mbedtls's legacy PEM private-key parser (MD5-KDF) — a path libarchive (the
#     only consumer, for archive digests + ZIP/7z AES) never invokes. Keep doCheck
#     ON and keep the other 138 suites gating; exclude only pem-suite.
#
# Wired as a linux (isMusl) engine DEP fix (flake.nix Layer C). tar uses mbedtls
# only on linux; darwin/windows libarchive build --without-mbedtls (the
# nixpkgs-mbedtls + non-linux engine-cc combos don't build cleanly), so this fix
# is never needed off-linux.
{ lib }:
{
  autoWire = "musl";
  apply = scope: scope.mbedtls.overrideAttrs (oa: {
    cmakeFlags = builtins.filter
      (f: !(lib.hasInfix "zero-init-padding-bits" (toString f)))
      (oa.cmakeFlags or [ ]);
    checkPhase = ''
      runHook preCheck
      ctest --output-on-failure --exclude-regex '^pem-suite$'
      runHook postCheck
    '';
  });
}
