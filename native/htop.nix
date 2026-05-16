# linux: htop's lm_sensors propagates perl+bash for sensors-detect (we
# don't ship it). Slim both and rm the script.
#
# All platforms: bake the curated terminfo fallback list into
# ncurses → libtinfo.a so htop renders correctly on hosts without
# `/usr/share/terminfo` (scratch/Alpine/minimal). Host terminfo still
# wins when present.
#
# darwin's old `--enable-static`-via-LDFLAGS issue is handled centrally
# now (see `filterEnableStaticOnDarwin` in `mkStandaloneFlake`); no
# darwin branch here.
{ lib }:
pkgs:
let
  p = pkgs.pkgsStatic;
  ncursesFB = lib.embedFallbackTerminfo p.ncurses;
in
if p.stdenv.hostPlatform.isLinux then
  p.htop.override {
    ncurses = ncursesFB;
    lm_sensors = p.lm_sensors.overrideAttrs (old: {
      propagatedBuildInputs = p.lib.filter
        (i: !builtins.elem (i.pname or "") [ "perl" "bash" ])
        (old.propagatedBuildInputs or [ ]);
      postInstall = (old.postInstall or "") + ''
        rm -f $out/bin/sensors-detect $out/bin/sensors-conf-convert
        rm -f $out/sbin/sensors-detect $out/sbin/sensors-conf-convert
      '';
    });
  }
else
  p.htop.override { ncurses = ncursesFB; }
