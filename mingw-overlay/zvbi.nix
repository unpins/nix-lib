# zvbi configure probes `pthread_create` in `-lpthread` and
# `-lpthreadGC2`, both missing on mingw — winpthreads ships
# `libpthread.a` under `windows.pthreads` and isn't in zvbi's
# default buildInputs.
{ lib }:
self: super:
super.zvbi.overrideAttrs (old: {
  buildInputs = (old.buildInputs or [ ]) ++ [ self.windows.pthreads ];
})
