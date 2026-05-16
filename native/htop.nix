# darwin: htop's configure.ac treats `--enable-static` as "pass -static globally
# to ld" (no libtool involved); libSystem.a doesn't exist → configure probes fail.
# Filter the flag.
# linux: htop's lm_sensors propagates perl+bash for sensors-detect (we don't
# ship it). Slim both and rm the script.
{ lib }:
pkgs:
let p = pkgs.pkgsStatic; in
if p.stdenv.hostPlatform.isDarwin then
  p.htop.overrideAttrs (old: {
    configureFlags = p.lib.filter
      (f: f != "--enable-static" && f != "--disable-shared")
      (old.configureFlags or [ ]);
  })
else if p.stdenv.hostPlatform.isLinux then
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
