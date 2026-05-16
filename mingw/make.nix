# Same `gnumake` → `make` name bridge as native/make.nix, plus a mingw quirk:
# src/job.c:378 calls `O (fatal, NILF, error_string)` (a fatal-error macro
# whose argument is a *runtime* string), which trips -Werror=format-security
# under mingw cross. Demoting it to a warning lets the build finish — the
# call site only fires inside Windows-specific batch-file creation, and
# `error_string` is the output of `map_windows32_error_to_string`, not
# attacker-controlled input.
{ lib }:
pkgs:
let cross = lib.mingwStaticCross pkgs; in
cross.gnumake.overrideAttrs (old: {
  env = (old.env or { }) // {
    NIX_CFLAGS_COMPILE = builtins.concatStringsSep " " (
      (lib.optional (old ? env && old.env ? NIX_CFLAGS_COMPILE)
        old.env.NIX_CFLAGS_COMPILE)
      ++ [ "-Wno-error=format-security" ]);
  };
})
