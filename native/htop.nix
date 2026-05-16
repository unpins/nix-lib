# linux: htop's lm_sensors propagates perl+bash for sensors-detect (we don't
# ship it). Slim both and rm the script.
#
# darwin: pkgsStatic.htop's `--enable-static` translates to `LDFLAGS=-static`
# which breaks libSystem probes (no libSystem.a). That filter now lives
# centrally in `mkStandaloneFlake`'s pipeline as `filterEnableStaticOnDarwin`,
# so this file no longer needs a darwin branch — the default
# `pkgs.pkgsStatic.htop` lookup goes through the filter automatically.
{ lib }:
pkgs:
let p = pkgs.pkgsStatic; in
if p.stdenv.hostPlatform.isLinux then
  p.htop.override {
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
  p.htop
