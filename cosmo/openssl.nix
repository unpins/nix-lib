# openssl/default.nix maps hostPlatform.system → Configure target;
# x86_64-cosmo isn't in the map. linux-x86_64 works fine: cosmocc presents
# a glibc-shaped surface for OpenSSL's perspective.
#
# Disable -dso (cosmo libc has no working dlopen — Dl_info.dli_fname etc.
# don't compile). `static = true` (via .override) tells nixpkgs to drop
# "shared" from configureFlags and add the appropriate no-* flags.
#
# Gated on isCosmo so buildPackages.openssl (linux-gnu) keeps its
# cache.nixos.org hash — otherwise any cosmo build that pulls a
# build-side tool depending on openssl would trigger a full rebuild.
{ lib }:
final: prev:
if (prev.stdenv.hostPlatform.isCosmo or false) then {
  openssl = (prev.openssl.override { static = true; }).overrideAttrs (oa: {
    configureScript = "./Configure linux-x86_64 no-dso no-engine no-async no-legacy";
  });
} else { }
