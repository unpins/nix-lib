# Pin ncurses' compiled-in DEFAULT terminfo dir to an FHS path. nixpkgs sets
# `--with-terminfo-dirs` to the FHS search list for static builds (so the binary
# doesn't depend on a store terminfo db) but leaves `--with-default-terminfo-dir`
# at `${out}/share/terminfo` — a /nix/store path baked into libtinfo's .rodata,
# which is a runtime-closure leak (and useless on the target host). Pinning it to
# `/usr/share/terminfo` (already in the search list) drops the leak with zero
# behavior change. Wired as an engine DEP fix so readline/libedit/htop all pick
# the fixed ncurses transitively (see flake.nix Layer C).
#
# `--disable-db-install` is REQUIRED alongside it: the default-terminfo-dir also
# governs where `make install` (`misc/run_tic.sh`) populates the compiled terminfo
# database. With it set to `/usr/share/terminfo`, run_tic does `mkdir -p
# /usr/share/terminfo` against the literal absolute path → "cannot create
# directory '/usr': Permission denied" in the build sandbox → install aborts.
# (Locally that mkdir failure was tolerated and produced an output with no
# terminfo db at all; in a clean CI sandbox it's fatal — every linux arch went
# red.) Our static tools resolve terminfo from the FHS search path at runtime and
# never use the in-output db, so suppressing the db install is behavior-neutral
# and makes the build deterministic everywhere. The .a libs are unaffected → the
# folded mega binary stays byte-identical.
{ lib }:
{
  autoWire = "musl";
  apply = scope: scope.ncurses.overrideAttrs (oa: {
    configureFlags = (oa.configureFlags or [ ]) ++ [
      "--with-default-terminfo-dir=/usr/share/terminfo"
      "--disable-db-install"
    ];
  });
}
