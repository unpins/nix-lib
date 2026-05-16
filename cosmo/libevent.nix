# Two cosmo gaps libevent's evutil.c trips on (mirrors superconfigure's
# minimal.diff for libevent 2.1.12):
#
#   - if_nametoindex() isn't in cosmo's net/if.h. Stub to 0 — the only
#     consumer is IPv6 scope-id parsing (`fe80::1%eth0`), a rarely-used
#     edge case our consumers (tmux only) don't hit.
#   - epoll detection in config.h.in: cosmo says it has epoll but the
#     pieces libevent needs aren't all there. Mangling the HAVE_EPOLL*
#     names disables them at preprocessor time so libevent falls back to
#     select() (which cosmo translates to WSAPoll on Windows, kqueue on
#     BSD, etc.).
{ lib }:
final: prev:
if (prev.stdenv.hostPlatform.isCosmo or false) then {
  libevent = prev.libevent.overrideAttrs (oa: {
    postPatch = (oa.postPatch or "") + ''
      substituteInPlace evutil.c \
        --replace-fail 'if_index = if_nametoindex(cp + 1);' \
                       'if_index = 0; /* cosmo: no if_nametoindex */'
      # Order matters: longest match first so HAVE_EPOLL substitution
      # doesn't eat the prefix of HAVE_EPOLL_CREATE1 / HAVE_EPOLL_CTL.
      substituteInPlace config.h.in \
        --replace-fail '#undef HAVE_EPOLL_CREATE1' '#undef HAVE_EPOLL_CREATE1_DISABLED' \
        --replace-fail '#undef HAVE_EPOLL_CTL'     '#undef HAVE_EPOLL_CTL_DISABLED' \
        --replace-fail '#undef HAVE_EPOLL'         '#undef HAVE_EPOLL_DISABLED'
    '';
    # samples/ uses mkfifo + Unix-only system calls cosmo doesn't expose;
    # they aren't part of the library, so skip.
    configureFlags = (oa.configureFlags or [ ]) ++ [ "--disable-samples" ];
  });
} else { }
