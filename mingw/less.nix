# less on mingw doesn't use ncurses. Upstream ships Makefile.wng which targets
# the Win32 console API directly (defines.wn + -lshell32). Autotools' configure
# detects -ltinfo/-lncursesw via AC_CHECK_LIB but every subsequent
# AC_LINK_IFELSE on tgetent fails, killing the build before any source compiles.
# Switching to Makefile.wng bypasses configure entirely and produces a much
# smaller binary (no ncurses pulled into the static link).
#
# REGEX_PACKAGE=regcomp-local uses less's bundled Henry Spencer regex (regexp.c),
# avoiding the mingw libregex dep that's only shipped in MSYS2 environments.
#
# Cross from Linux: we have posix grep/sed in PATH, so WINGEN=1 is not needed
# (the C-based buildgen path is only required when building ON Windows without
# msys tools).
{ lib }:
pkgs:
let cross = lib.mingwStaticCross pkgs; in
cross.less.overrideAttrs (old: {
  dontConfigure = true;
  buildInputs = [ ];
  # nixpkgs less declares `outputs = [ "out" "man" ]`, but Makefile.wng installs
  # neither nroff man pages nor a `share/` tree, so drop the man output.
  outputs = [ "out" ];
  # Makefile.wng generates help.c via `perl mkhelp.pl || sh mkhelp.sh`.
  # The .sh fallback isn't shipped in the tarball, so perl is required.
  nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ pkgs.buildPackages.perl ];
  makeFlags = [
    "-f" "Makefile.wng"
    "SHELL=sh"
    "CC=${cross.stdenv.cc.targetPrefix}gcc"
    "REGEX_PACKAGE=regcomp-local"
  ];
  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    cp less.exe lesskey.exe lessecho.exe $out/bin/
    runHook postInstall
  '';
})
