# zstd's recipe puts `bashNonInteractive` in buildInputs and writes
# `${gnugrep}/bin/grep` into its `zstdgrep` script. Under pkgsStatic both
# resolve to HOST packages, so every engine build that links libzstd first
# compiles a static bash, grep and pcre2 with the engine — for two shell
# scripts in zstd's `bin` output that no consumer ships. Drop the bash (the
# only use, `patchShebangs` in the check phase, never runs in a static build)
# and point the script at the build machine's grep, which is already there.
# Only libzstd reaches a shipped binary, and it is unchanged.
# Wired as a LEAF on the engine set (like atf.nix): the toolchain's own zstd
# comes from the pristine pkgsStatic and keeps its hash.
{ lib }:
{
  autoWire = "static";
  apply = pkgs:
    (pkgs.zstd.override { gnugrep = pkgs.buildPackages.gnugrep; }).overrideAttrs (_: {
      # bash is the recipe's only buildInput (`optional isUnix`), and the
      # static adapter has already moved it to propagatedBuildInputs by the
      # time overrideAttrs runs; the recipe propagates nothing of its own.
      buildInputs = [ ];
      propagatedBuildInputs = [ ];
    });
}
