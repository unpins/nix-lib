# Darwin-only fix. Apple's libiconv-113 carries `atf` as a checkInput, and our
# static gnugrep pulls that libiconv into every engine darwin build. atf's
# self-test `dynstr_test:init_rep` expects a huge malloc to FAIL; on overcommit
# macOS (notably the aarch64 CI runners) it succeeds, so the test — and the
# whole darwin build — fails nondeterministically (a cache miss on atf is a coin
# flip). atf runs that test in the INSTALLCHECK phase (doInstallCheck = true;
# doCheck is already false), and it is a build tool we never ship, so skip it.
# Wired as a LEAF overlay on enginePkgsStatic (Layer D in mkStandaloneFlake), not
# on the nixpkgs import — an import overlay would join the stdenv-bootstrap
# fixpoint and re-hash the cached macOS SDK. Self-gates to darwin so the linux
# static host is a no-op (byte-identical).
{ lib }:
{
  autoWire = "static";
  apply = pkgs:
    if pkgs.stdenv.hostPlatform.isDarwin
    then pkgs.atf.overrideAttrs (_: { doInstallCheck = false; })
    else pkgs.atf;
}
