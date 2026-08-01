# x86_64-cosmo isn't in openssl's system→Configure-target map; linux-x86_64
# works (cosmocc presents a glibc-shaped surface). no-dso because cosmo libc has
# no working dlopen. `static = true` drops "shared" and adds the no-* flags.
{ lib }:
final: prev:
(prev.openssl.override { static = true; }).overrideAttrs (oa: {
  configureScript = "./Configure linux-x86_64 no-dso no-engine no-async no-legacy";
})
