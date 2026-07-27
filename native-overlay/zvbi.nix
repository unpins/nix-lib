# zvbi installs a second library next to `libzvbi`: `libzvbi-chains`, the
# LD_PRELOAD shim behind the `zvbi-chains` wrapper. It DEFINES `open`, `close`,
# `read`, `write`, `ioctl` and `fcntl` as globals and reaches the real ones
# through `dlsym(RTLD_NEXT, …)` — which is exactly what a preloaded `.so` needs
# and exactly what nothing static can survive. Nobody links it (`zvbi-0.2.pc`
# names `-lzvbi` alone) but the mega-link's auto-derive sweeps every `lib/*.a`
# in the closure, so the fold pulls `chains.o` in to satisfy its own undefined
# `ioctl`, ahead of musl's. `dlsym` in a static binary returns NULL, so the
# forwarding pointers stay zero: ffmpeg links clean, prints `-version` and
# `-codecs` fine, then jumps to address 0 the first time anything reaches a
# device or a terminal (`ioctl(0, TIOCGWINSZ, …)` — i.e. any real transcode).
#
# The static half of a preload shim is nonsense on its own, so drop it. The
# decoding API is untouched: `proxy-client.o`/`proxy-msg.o` are also in
# `libzvbi.a`, which defines no libc symbol at all.
#
# Auto-wired rather than left to consumers: the damage is done by the archive
# merely EXISTING in the closure, so a per-flake override would have to be
# written by whoever links ffmpeg, not by whoever names zvbi.
{ lib }:
{
  autoWire = "static";
  apply = pkgs:
    pkgs.zvbi.overrideAttrs (oa:
      lib.optionalAttrs pkgs.stdenv.hostPlatform.isStatic {
        postFixup = (oa.postFixup or "") + ''
          rm -f "$out"/lib/libzvbi-chains.a "$out"/lib/libzvbi-chains.la
        '';
      });
}
