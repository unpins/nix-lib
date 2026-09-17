# fontconfig on mingw static: `fontconfig.pc` declares `Requires.private:
# expat`, but cairo/pango/librsvg drive pkg-config without `--static`,
# dropping expat → cascading `XML_*` undef refs. Promote it to public
# `Requires` (same pattern as brotli.nix / libtiff.nix).
#
# Also drop nixpkgs' `--with-default-fonts` (a dejavu store path) and
# `--with-cache-dir=/var/cache/fontconfig`, so configure picks upstream's Windows
# defaults: the system and per-user font folders when no fonts.conf is found,
# and a cache under LOCALAPPDATA. With the store path a Windows binary knew no
# fonts — ffmpeg's `drawtext` without `fontfile=` found none (see
# native-overlay/fontconfig.nix).
{ lib }:
self: super:
super.fontconfig.overrideAttrs (oa: {
  configureFlags = builtins.filter
    (f: !(lib.hasPrefix "--with-default-fonts=" f || lib.hasPrefix "--with-cache-dir=" f))
    (oa.configureFlags or [ ]);
  postInstall = (oa.postInstall or "") + ''
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
  propagatedBuildInputs = (oa.propagatedBuildInputs or [ ]) ++ [ self.expat ];
})
