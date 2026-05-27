# fontconfig on mingw static: `fontconfig.pc` declares
# `Requires.private: expat`, but cairo/pango/librsvg drive
# pkg-config without `--static` and the transitive expat dep
# is dropped, causing the cairo link to fail with cascading
# `XML_*` undefined references (`XML_ParserCreate`,
# `XML_SetCharacterDataHandler`, `XML_Parse`, …).
#
# Same fix pattern as `brotli.nix` / `libtiff.nix`: promote
# `Requires.private` to public `Requires` so consumers pick
# expat up regardless of `--static` flag.
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
  # expat moves from buildInputs (private) to propagatedBuildInputs
  # (public) — keeps the .pc claim honest now that we promoted
  # `Requires.private: expat` to public `Requires:`. Without this,
  # cairo (and any other consumer) sees `pkg-config glib-2.0`
  # cascade through to expat and aborts.
  propagatedBuildInputs = (old.propagatedBuildInputs or [ ]) ++ [ self.expat ];
})
