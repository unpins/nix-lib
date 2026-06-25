# Two cosmo gaps in libevent 2.1.12 (mirrors superconfigure's minimal.diff):
#   - if_nametoindex() isn't in cosmo's net/if.h. Stub to 0 — only consumer is
#     IPv6 scope-id parsing, which tmux doesn't hit.
#   - cosmo claims epoll but lacks the pieces libevent needs; mangle the
#     HAVE_EPOLL* names so it falls back to select().
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
