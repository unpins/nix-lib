# x264's configure runs an endianness probe that greps `${STRINGS} -a conftest.o`
# for byte-order markers (`EGIB`/`naidnePF` little-endian, `BIGE`/`FPendian`
# big). `STRINGS` defaults to `${cross_prefix}strings`, but the engine bintools
# is an `llvm` multitool that ships no `strings`/`llvm-strings` subcommand — and
# even `buildPackages.binutils` resolves to that engine wrapper (also strings-
# less) — so the probe dies `strings: command not found → endian test failed`.
# `conftest.o` is a NATIVE ELF (the engine cc drops `-flto` for any `*conftest*`
# command), so any tool that extracts printable ASCII runs works. Point
# `STRINGS` at a dependency-free shim (grep printable sequences ≥4 chars) rather
# than dragging a pristine binutils past the engine swap. Every unpin target is
# little-endian, so the probe then resolves correctly. autoWire "static" folds
# it into the engine pkgsStatic on linux-musl + darwin.
{ lib }:
{
  autoWire = "static";
  apply = pkgs:
    let
      stringsShim = pkgs.buildPackages.runCommand "unpin-strings-shim" { } ''
        mkdir -p $out/bin
        cat > $out/bin/strings <<'EOF'
        #!/bin/sh
        # minimal `strings`: ignore flags, print printable ASCII runs (len >= 4)
        for a in "$@"; do
          case "$a" in -*) continue ;; esac
          LC_ALL=C grep -aoE '[ -~]{4,}' "$a" || true
        done
        EOF
        chmod +x $out/bin/strings
      '';
    in
    pkgs.x264.overrideAttrs (oa: {
      preConfigure = (oa.preConfigure or "")
        + ''export STRINGS=${stringsShim}/bin/strings'' + "\n";
    });
}
