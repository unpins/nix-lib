# fontconfig on mingw static: `fontconfig.pc` declares `Requires.private:
# expat`, but cairo/pango/librsvg drive pkg-config without `--static`,
# dropping expat → cascading `XML_*` undef refs. Promote it to public
# `Requires` (same pattern as brotli.nix / libtiff.nix).
{ lib }:
self: super:
super.fontconfig.overrideAttrs (old: {
  postInstall = (old.postInstall or "") + ''
    # Merge `Requires.private: expat` INTO the existing
    # `Requires: freetype2 ...` line. A naive
    # `s/Requires\.private:/Requires:/` would leave two separate
    # `Requires:` lines — pkg-config only honors the LAST one,
    # silently dropping freetype2 from the consumer's transitive
    # graph. ffmpeg's `check_pkg_config libfontconfig fontconfig`
    # then produces `-lfontconfig -lexpat` (no `-lfreetype`), and
    # the test link fails with `FT_Get_Char_Index` undef from
    # `libfontconfig.a(fcfreetype.o)`.
    sed -i \
      -e 's/^Requires\.private:[ \t]*expat[ \t]*$//' \
      -e 's/^Requires:\([ \t]*freetype2[^\n]*\)$/Requires:\1, expat/' \
      $dev/lib/pkgconfig/fontconfig.pc
  '';
  # Propagate expat to match the now-public `Requires:` (else consumers'
  # transitive pkg-config probe can't find `expat.pc`).
  propagatedBuildInputs = (old.propagatedBuildInputs or [ ]) ++ [ self.expat ];
})
