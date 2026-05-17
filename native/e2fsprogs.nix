# Upstream e2fsprogs is multi-binary — mke2fs/tune2fs/dumpe2fs/e2fsck are
# four separate executables (each plus its own argv[0]-aliased symlinks:
# mkfs.ext2/3/4, e2label, fsck.ext2/3/4...). To honour the unpins one-pkg-
# one-bin rule we post-link them into a single multicall ELF.
#
# Why a post-link route (no source patch): every tool keeps its own
# `int main()` and several share helpers under the same global names but
# with INCOMPATIBLE signatures (misc/util.c and e2fsck/util.c both define
# `dump_mmp_msg` with different arg lists; misc/util.c and e2fsck/util.c
# both define their own `util.o`; recovery.o/revoke.o are compiled by
# both subdirs from the same e2fsck/*.c). Renaming via source-rewriting
# is fragile and high-noise. Instead we use the binutils-level recipe:
#
#   1. Let `make` run upstream normally — all .o files land in misc/* and
#      e2fsck/*, all archives in lib/{support,ext2fs,e2p,et}/.
#   2. For each entry point (mke2fs, tune2fs, dumpe2fs, e2fsck):
#        a. `ld -r` collects its .o set into a single partial-link object.
#        b. `objcopy --redefine-syms=…` runs ONE pass that renames every
#           defined global: the tool's `main` → `<tool>_main` (the
#           dispatcher target) and every other global `foo` →
#           `<tool>__foo` (privately scoped to this combined object).
#           Internal cross-refs are already resolved by step (a), so the
#           rename propagates through relocations as well. The prefix
#           dissolves the collision set wholesale — no per-collision
#           rename, no per-version maintenance.
#           (We avoid `--localize-symbols` because it is functionally a
#           no-op for Mach-O in llvm-objcopy: localized symbols remain
#           externally visible to ld64, which then errors out with
#           `duplicate symbol` whenever two combined objects share an
#           upstream helper such as `misc/util.o`.)
#   3. A small dispatcher.c (basename(argv[0]) → *_main) is compiled
#      separately, then the final link is delegated to upstream's
#      misc/Makefile via an injected `unpin-multicall.mk` fragment.
#      Reason: the lib paths needed for the link ($(LIBBLKID), $(LIBUUID),
#      $(LIBARCHIVE), $(SYSLIBS), $(ALL_LDFLAGS) …) resolve differently per
#      target — Linux passes `--disable-libblkid` so LIBBLKID becomes
#      `-L<util-linux>/lib -lblkid ...`; Darwin keeps libblkid in-tree so
#      LIBBLKID becomes `$(LIB)/libblkid.a $(LIBUUID)`; cc-wrapper's
#      implicit libgcc cascade (needed on linux-i686 for the libgcc
#      __x86.get_pc_thunk.* helpers PIC code uses) only kicks in when the
#      compiler is invoked via the wrapper with the right flag set, which
#      `$(CC) $(ALL_LDFLAGS)` reproduces. Letting make do the variable
#      substitution against mke2fs's own recipe (with e2fsck's
#      `$(LIBSUPPORT)` added) keeps every per-target detail intact.
#   4. We strip all upstream-installed binaries and replace them with one
#      multicall binary at $bin/bin/e2fsprogs plus applet symlinks for the
#      argv[0]-dispatch names. `lib.withAliases` then harvests those
#      symlinks, validates them, embeds the CSV as an UNPIN_META section,
#      and strips them — same shape as coreutils/kmod.
#
# Measured win (x86_64 musl-static, stripped, with full libarchive):
# 4 separate bins ~13 MB total → 1 multicall ~8.3 MB. 13 applet names
# embedded.
{ lib }:
pkgs:
let
  multicallObjs = {
    mke2fs = [
      "misc/mke2fs.o"
      "misc/util.o"
      "misc/default_profile.o"
      "misc/mk_hugefiles.o"
      "misc/create_inode.o"
      "misc/create_inode_libarchive.o"
    ];
    tune2fs = [
      "misc/tune2fs.o"
      "misc/util.o"
      "misc/journal.o"
      "misc/recovery.o"
      "misc/revoke.o"
    ];
    dumpe2fs = [
      "misc/dumpe2fs.o"
    ];
    e2fsck = [
      "e2fsck/unix.o" "e2fsck/e2fsck.o" "e2fsck/super.o"
      "e2fsck/pass1.o" "e2fsck/pass1b.o" "e2fsck/pass2.o"
      "e2fsck/pass3.o" "e2fsck/pass4.o" "e2fsck/pass5.o"
      "e2fsck/journal.o" "e2fsck/badblocks.o" "e2fsck/util.o"
      "e2fsck/dirinfo.o" "e2fsck/dx_dirinfo.o" "e2fsck/ehandler.o"
      "e2fsck/problem.o" "e2fsck/message.o" "e2fsck/quota.o"
      "e2fsck/recovery.o" "e2fsck/region.o" "e2fsck/revoke.o"
      "e2fsck/ea_refcount.o" "e2fsck/rehash.o" "e2fsck/logfile.o"
      "e2fsck/sigcatcher.o" "e2fsck/readahead.o" "e2fsck/extents.o"
      "e2fsck/encrypted_files.o"
    ];
  };

  # Applet names dispatched by argv[0]. Mke2fs/tune2fs/e2fsck each do their
  # own argv[0] re-check internally (e.g. tune2fs recognises e2label/
  # e2mmpstatus/findfs), so we route the alias straight to the tool main
  # and the tool decides the variant.
  appletAliases = [
    "mke2fs" "mkfs.ext2" "mkfs.ext3" "mkfs.ext4"
    "tune2fs" "e2label" "e2mmpstatus" "findfs"
    "dumpe2fs"
    "e2fsck" "fsck.ext2" "fsck.ext3" "fsck.ext4"
  ];

  # Dispatcher source. Routes basename(argv[0]) → tool_main. Extra
  # `e2fsprogs <applet> [args]` form so the primary binary is still
  # callable directly without renaming/symlinking.
  dispatcherC = ''
    #include <string.h>
    #include <stdio.h>

    int mke2fs_main(int argc, char *argv[]);
    int tune2fs_main(int argc, char *argv[]);
    int dumpe2fs_main(int argc, char *argv[]);
    int e2fsck_main(int argc, char *argv[]);

    struct applet { const char *name; int (*fn)(int, char **); };

    static const struct applet applets[] = {
        {"mke2fs",    mke2fs_main},
        {"mkfs.ext2", mke2fs_main},
        {"mkfs.ext3", mke2fs_main},
        {"mkfs.ext4", mke2fs_main},
        {"tune2fs",   tune2fs_main},
        {"e2label",   tune2fs_main},
        {"e2mmpstatus", tune2fs_main},
        {"findfs",    tune2fs_main},
        {"dumpe2fs",  dumpe2fs_main},
        {"e2fsck",    e2fsck_main},
        {"fsck.ext2", e2fsck_main},
        {"fsck.ext3", e2fsck_main},
        {"fsck.ext4", e2fsck_main},
        {NULL, NULL}
    };

    int main(int argc, char *argv[])
    {
        char *name = argv[0];
        char *slash = strrchr(name, '/');
        if (slash) name = slash + 1;
        if (strncmp(name, "lt-", 3) == 0) name += 3;

        if (strcmp(name, "e2fsprogs") == 0) {
            if (argc < 2) {
                fprintf(stderr, "e2fsprogs: usage: %s <applet> [args...]\n", argv[0]);
                fprintf(stderr, "applets:");
                for (const struct applet *a = applets; a->name; a++)
                    fprintf(stderr, " %s", a->name);
                fprintf(stderr, "\n");
                return 1;
            }
            name = argv[1];
            argv++;
            argc--;
        }

        for (const struct applet *a = applets; a->name; a++) {
            if (strcmp(name, a->name) == 0)
                return a->fn(argc, argv);
        }
        fprintf(stderr, "e2fsprogs: unknown applet '%s'\n", name);
        return 1;
    }
  '';

  # Darwin's ld64 doesn't accept --start-group/--end-group (errors with
  # "unknown option: --start-group"), and its clang+compiler-rt has no
  # `libgcc.a` for `-lgcc` to resolve. Pick the right link-line prefix/
  # suffix per target. The thunk + late-libc-symbol problem that --start-
  # group + libgcc solves is i686-specific (RIP-relative on x86_64,
  # different/no thunks on the other ISAs) — Mach-O linkers also rescan
  # symbol tables naturally, so neither directive is needed on Darwin.
  isTargetDarwin = pkgs.pkgsStatic.stdenv.hostPlatform.isDarwin;
  multicallGroupOpen = if isTargetDarwin then "" else "-Wl,--start-group";
  multicallGroupClose = if isTargetDarwin then "" else "-Wl,--end-group";
  multicallLibgcc = if isTargetDarwin then "" else "-lgcc";

  # Custom Makefile fragment that reuses upstream's misc/Makefile variables
  # ($(LIBBLKID), $(LIBUUID), $(LIBARCHIVE), $(LIBS), $(SYSLIBS), $(ALL_LDFLAGS)
  # …) to do the final link. Written via pkgs.writeText so neither Nix
  # interpolation nor bash heredoc indentation/escaping mangles the recipe
  # tabs. `top_builddir` is one level up from misc/, matching upstream's
  # misc/Makefile.in.
  multicallMk = pkgs.writeText "unpin-multicall.mk" ''
    MULTI_OUT ?= $(top_builddir)/multicall/e2fsprogs
    MULTI_OBJS = \
        $(top_builddir)/multicall/dispatcher.o \
        $(top_builddir)/multicall/mke2fs.combined.o \
        $(top_builddir)/multicall/tune2fs.combined.o \
        $(top_builddir)/multicall/dumpe2fs.combined.o \
        $(top_builddir)/multicall/e2fsck.combined.o

    .PHONY: multicall-link
    multicall-link: $(MULTI_OUT)

    # `--start-group ... $(MULTI_LIBGCC) --end-group` is the key difference
    # vs upstream's mke2fs/e2fsck per-tool recipes. Two reasons (GNU/Linux):
    #
    # (1) The bigger combined link drags in additional libc.a members
    #     (musl's __secs_to_tm.lo, __stdio_exit.lo, ...) whose PIC-mode
    #     references to `__x86.get_pc_thunk.*` are only resolvable from
    #     libgcc — and the cc-driver's implicit `-lgcc -lc -lgcc` tail is
    #     scanned ONCE by the linker. Without the explicit `-lgcc` inside
    #     the group, libc gets pulled in (introducing fresh
    #     `__x86.get_pc_thunk.*` undefs) after the implicit libgcc has
    #     already been scanned, leaving those undefs unresolved.
    #
    # (2) `ld -r`-combined objects (lib/support/profile.o etc.) carry
    #     leftover `__x86.get_pc_thunk.*` references too — putting libgcc
    #     inside the group picks those up during the rescan pass.
    #
    # Darwin (ld64): MULTI_LIBGCC is empty (clang/compiler-rt has no
    # `libgcc.a`; `-lgcc` would error with "library not found"). The
    # thunk problem is i686-specific (RIP-relative on x86_64, different
    # ISAs use different/no thunks), so skipping `-lgcc` on Darwin also
    # skips the problem class. `--start-group`/`--end-group` themselves
    # are no-ops on ld64.
    $(MULTI_OUT): $(MULTI_OBJS) $(DEPLIBS) $(LIBE2P) $(DEPLIBBLKID) $(DEPLIBUUID) $(LIBEXT2FS) $(LIBSUPPORT)
    	$(CC) $(ALL_LDFLAGS) -o $@ $(MULTI_OBJS) \
    		$(MULTI_GROUP_OPEN) \
    		$(LIBSUPPORT) $(LIBS) $(LIBBLKID) $(LIBUUID) \
    		$(LIBEXT2FS) $(LIBE2P) $(LIBINTL) \
    		$(SYSLIBS) $(LIBMAGIC) $(LIBARCHIVE) \
    		$(MULTI_LIBGCC) \
    		$(MULTI_GROUP_CLOSE)
  '';

  multicall = pkgs.pkgsStatic.e2fsprogs.overrideAttrs (old: {
    pname = "e2fsprogs-multi";

    postBuild = (old.postBuild or "") + ''
      mkdir -p multicall
      cat > multicall/dispatcher.c <<'DISPATCHER_EOF'
${dispatcherC}
DISPATCHER_EOF

      __e2fs_combine() {
        local tool=$1; shift
        $LD -r -o multicall/$tool.combined.o "$@"
        # Build one rename map per tool and apply it in a single
        # `--redefine-syms` pass:
        #   - `main` → `<tool>_main`  (the entry point routed by dispatcher.c)
        #   - every other defined global `foo` → `<tool>__foo` (private to
        #     this combined object across the final link).
        # Skip compiler-emitted COMDAT thunks (`__x86.get_pc_thunk.*`,
        # i686 PIC helpers) — leaving them global lets the FINAL link
        # dedupe normally and libgcc resolve any leftover refs.
        #
        # Why prefix-rename instead of `--localize-symbols`: llvm-objcopy's
        # `--localize-symbols` is functionally a no-op on Mach-O — the
        # demoted symbols stay externally visible, so misc/util.o pulled
        # into both mke2fs.combined.o and tune2fs.combined.o triggers
        # `duplicate symbol _journal_flags` at the ld64 final link.
        # Prefix-renaming is target-format agnostic and also keeps the
        # final binary's symbol map self-explanatory (you can see which
        # tool a leftover symbol came from).
        #
        # awk handles both Mach-O (leading `_` on user symbols) and ELF
        # (no prefix) in one pass: strip a leading `_` if present, then
        # re-attach it on the new name. Plain `grep -v` would also
        # `exit 1` (and trip set -e) on a tool whose only global is
        # main (e.g. dumpe2fs).
        $NM --defined-only -g multicall/$tool.combined.o \
          | awk -v t="$tool" \
              '$2 ~ /^[TBDR]$/ && $3 !~ /^__x86\.get_pc_thunk\./ {
                  old = $3
                  sym = old
                  pfx = ""
                  if (sub(/^_/, "", sym)) pfx = "_"
                  if (sym == "main") new = pfx t "_main"
                  else                new = pfx t "__" sym
                  print old, new
              }' \
          > multicall/$tool.renames.txt
        if [ -s multicall/$tool.renames.txt ]; then
          $OBJCOPY --redefine-syms=multicall/$tool.renames.txt \
            multicall/$tool.combined.o
        fi
      }

      ${lib.concatStringsSep "\n      " (lib.mapAttrsToList
        (tool: objs:
          "__e2fs_combine ${tool} ${lib.concatStringsSep " " objs}")
        multicallObjs)}

      $CC -O2 -c -o multicall/dispatcher.o multicall/dispatcher.c

      # Delegate the final link to upstream's misc/Makefile by adding a
      # custom target that reuses the same variables mke2fs uses
      # ($(LIBBLKID), $(LIBUUID), $(LIBARCHIVE), $(LIBS), $(SYSLIBS),
      # $(ALL_LDFLAGS), ...). Why: those vars resolve differently per
      # target — Linux passes `--disable-libblkid` so LIBBLKID becomes
      # `-L<util-linux>/lib -lblkid ...`; Darwin keeps libblkid in-tree
      # so LIBBLKID becomes `$(LIB)/libblkid.a $(LIBUUID)`. Hard-coding
      # `-lblkid -luuid` breaks Darwin; hard-coding the .a paths breaks
      # Linux. Make's variable expansion is the source of truth.
      #
      # Listed libraries are the union of what mke2fs (+LIBARCHIVE, +LIBMAGIC),
      # tune2fs/dumpe2fs (subset), and e2fsck (+LIBSUPPORT, +LIBSS) each
      # link against in their per-target recipes.
      install -m644 ${multicallMk} misc/unpin-multicall.mk

      make -C misc -f Makefile -f unpin-multicall.mk \
        MULTI_GROUP_OPEN="${multicallGroupOpen}" \
        MULTI_GROUP_CLOSE="${multicallGroupClose}" \
        MULTI_LIBGCC="${multicallLibgcc}" \
        multicall-link
    '';

    # Wipe upstream's installed binaries and replace with our single
    # multicall + applet symlinks. Must clear both `$bin/bin` AND
    # `$bin/sbin`: nixpkgs's fixupPhase (`_moveSbinToBin`) runs after
    # postInstall and re-merges the surviving sbin entries (mke2fs,
    # tune2fs, e2fsck, fsck.ext*, mkfs.ext*, ...) into `bin/`, which
    # would re-introduce the originals next to our multicall.
    postInstall = (old.postInstall or "") + ''
      rm -rf "$bin/bin" "$bin/sbin"
      mkdir -p "$bin/bin"
      install -m755 multicall/e2fsprogs "$bin/bin/e2fsprogs"
      for n in ${lib.concatStringsSep " " appletAliases}; do
        ln -s e2fsprogs "$bin/bin/$n"
      done
    '';
  });
in
lib.withAliases pkgs
  {
    primary = "e2fsprogs";
    aliasesFromSymlinksIn = "bin";
  }
  multicall
