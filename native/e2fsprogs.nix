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
#        b. `objcopy --redefine-sym main=<tool>_main` renames its main.
#        c. `objcopy --localize-symbols=<all-other-globals>` demotes
#           every remaining exported global to file-local. Internal cross-
#           refs are already resolved by step (a), so localizing them is
#           safe — and it disposes of the collision set wholesale: no per-
#           collision rename, no per-version maintenance.
#   3. A small dispatcher.c (basename(argv[0]) → *_main) is compiled and
#      linked alongside the four combined.o objects against e2fsprogs's
#      in-tree libsupport/libext2fs/libe2p/libcom_err plus -lblkid/-luuid
#      from util-linux-minimal AND `$(LIBARCHIVE)` (pre-resolved from
#      pkg-config --libs --static, written by configure into MCONFIG —
#      `-larchive -lcrypto -lacl -lzstd -lbz2 -lz -llzma -lxml2 -lm -ldl
#      ...`). pkg-config isn't on PATH at postBuild time so we read the
#      string out of MCONFIG via awk. Keeping libarchive preserves
#      mke2fs's `-d <tarball>` source-from-archive mode.
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
        $OBJCOPY --redefine-sym main=''${tool}_main multicall/$tool.combined.o
        # Single-pass awk: keep globals (T/B/D/R) that aren't the redefined
        # tool entry point. Plain `grep -v` would exit 1 (and trip set -e)
        # for tools whose only global is <tool>_main, e.g. dumpe2fs.
        $NM --defined-only -g multicall/$tool.combined.o \
          | awk -v t="''${tool}_main" '$2 ~ /^[TBDR]$/ && $3 != t {print $3}' \
          > multicall/$tool.localize.txt
        # `objcopy --localize-symbols=<empty>` exits 1; only single-.o tools
        # like dumpe2fs hit this since their internal helpers are already
        # `static`. Skip the call rather than work around with || true so
        # genuine failures still propagate.
        if [ -s multicall/$tool.localize.txt ]; then
          $OBJCOPY --localize-symbols=multicall/$tool.localize.txt \
            multicall/$tool.combined.o
        fi
      }

      ${lib.concatStringsSep "\n      " (lib.mapAttrsToList
        (tool: objs:
          "__e2fs_combine ${tool} ${lib.concatStringsSep " " objs}")
        multicallObjs)}

      $CC -O2 -c -o multicall/dispatcher.o multicall/dispatcher.c

      # Pull LIBARCHIVE (the resolved `-L<libarchive>/lib -larchive -lcrypto
      # -lacl -lzstd -lbz2 -lz -llzma -lxml2 -lm -lcrypto -ldl ...` line from
      # `pkg-config --libs --static libarchive` that the upstream configure
      # baked into MCONFIG) so create_inode_libarchive.o's archive_* refs
      # resolve. pkg-config itself isn't on PATH post-configure (it was a
      # nativeBuildInput), so we read the pre-computed string out of MCONFIG.
      __e2fs_libarchive=$(awk -F= '/^LIBARCHIVE =/ {sub(/^[^=]*= */, ""); print; exit}' MCONFIG)

      # Link: dispatcher + 4 combined.o + e2fsprogs in-tree archives + libs
      # from util-linux-minimal (-lblkid -luuid) + libarchive cascade.
      $CC -o multicall/e2fsprogs \
        multicall/dispatcher.o \
        multicall/mke2fs.combined.o \
        multicall/tune2fs.combined.o \
        multicall/dumpe2fs.combined.o \
        multicall/e2fsck.combined.o \
        lib/support/libsupport.a \
        lib/ext2fs/libext2fs.a \
        lib/e2p/libe2p.a \
        lib/et/libcom_err.a \
        -lblkid -luuid \
        $__e2fs_libarchive
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
