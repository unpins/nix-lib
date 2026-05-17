# busybox is already a single-binary multicall by design — `bin/busybox`
# plus 394 argv[0]-dispatch symlinks (`ls`, `sh`, `vi`, `mount`, …) covering
# every configured applet. Mirrors the kmod/coreutils pattern: ship only
# the multicall, embed the applet names as an UNPIN_META block so unpin's
# installer can recreate the symlinks at install time.
#
# Linux-only: busybox upstream targets the Linux kernel (Linux-specific
# syscalls, /proc, /sys, namespaces, mount, switch_root). nixpkgs
# `meta.platforms` lists every Linux arch and nothing else.
#
# nixpkgs also drops a `sbin → bin` symlink, a `linuxrc → bin/busybox`
# symlink, and a `default.script` initramfs helper at the package root.
# Those are convenience artifacts for embedded/initramfs usage, harmless
# in `result/` and not shipped by action-build (which tars only the bin).
#
# Why the preInstall hop: busybox installs ~395 applets across two dirs
# (`bin/` and `sbin/` from `busybox.links` — 265 + 130 in the current
# nixpkgs build). The standard `_moveSbinToBin` fixupOutputHook merges
# them into `bin/`, BUT it runs in fixupPhase — AFTER `lib.withAliases`'
# postInstall scan. Without intervention `withAliases` would see only the
# 265 bin/-installed names; the 130 sbin/-side applets (depmod, mount,
# fdisk, lsmod, …) would never make it into UNPIN_META, and `unpin install
# busybox` would materialise only ~265 aliases. Merging sbin→bin in our
# postInstall — BEFORE withAliases appends its own scan-then-delete pass
# — gets all 395 picked up. `_moveSbinToBin` then no-ops because sbin is
# already a symlink.
{ lib }:
pkgs:
let
  prepared = pkgs.pkgsStatic.busybox.overrideAttrs (old: {
    postInstall = (old.postInstall or "") + ''
      # Merge sbin/ into bin/ so lib.withAliases (appended below) harvests
      # every applet, not just the bin/-installed subset. Idempotent —
      # noop when sbin is already a symlink (re-runs, cached builds).
      if [ -d "$out/sbin" ] && [ ! -L "$out/sbin" ]; then
        echo "unpins(busybox): merging $out/sbin/* into $out/bin"
        for f in "$out/sbin"/*; do
          mv "$f" "$out/bin/" 2>/dev/null || true
        done
        rmdir "$out/sbin" 2>/dev/null || true
        ln -s bin "$out/sbin"
      fi
      # `linuxrc` is the initramfs PID-1 entry name the kernel runs when
      # the root device is an initrd. Upstream busybox install drops it at
      # the package root (`$out/linuxrc → bin/busybox`); we hoist it into
      # bin/ so lib.withAliases picks it up alongside the other applets.
      if [ -L "$out/linuxrc" ] && [ ! -e "$out/bin/linuxrc" ]; then
        ln -s busybox "$out/bin/linuxrc"
      fi
    '';
  });
in
lib.withAliases pkgs
  {
    primary = "busybox";
    aliasesFromSymlinksIn = "bin";
  }
  prepared
