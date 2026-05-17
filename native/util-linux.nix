# Upstream util-linux ships 123 separate binaries (mount, umount, login,
# agetty, blkid, dmesg, fdisk, hexdump, cal, …), none of which share a
# multicall entry point. To honour the unpins one-pkg-one-bin rule we
# post-link them into a single multicall ELF using the same recipe
# proven on e2fsprogs (see [[feedback-post-link-multicall-recipe]]):
#
# Why a post-link route (no source patch): each tool has its own
# `int main()` plus shared helpers from `lib/*.c` that automake compiles
# with a per-program prefix (`lib/dmesg-monotonic.o` vs
# `lib/flock-monotonic.o` from the same `lib/monotonic.c`). The .o file
# names are unique, but the SYMBOL names inside (`get_boot_time`,
# `mono_diff`, …) are identical — so linking them all in one final pass
# triggers `multiple definition` errors. The binutils-level recipe
# disposes of the collision set wholesale.
#
#   1. Let `make` run upstream normally — every `<tool>` binary plus its
#      per-program .o set lands in the build tree.
#   2. Parse the post-configure `Makefile` to learn, for each shipped
#      program, the list of .o files automake wired into it (the
#      `am_<tool>_OBJECTS = …` lines). Conditionally-disabled tools
#      stay commented (`#@BUILD_X_TRUE@am_…`); we only pick up live
#      definitions. Auto-syncs with upstream: new bin_PROGRAMS get
#      bundled automatically the next time we bump nixpkgs.
#   3. For each program (with name sanitised to a valid C identifier,
#      e.g. `fsck.cramfs` → `fsck_cramfs`):
#        a. `ld -r` collects its .o set into a partial-link object.
#        b. `nm --defined-only -g` + iterated `objcopy --redefine-sym`
#           renames the tool's `main` → `<san>_main` (dispatcher target)
#           and every other defined global `foo` → `<san>__foo` (private
#           to this combined object across the final link). Skip
#           compiler-emitted COMDAT thunks (`__x86.get_pc_thunk.*`,
#           i686 PIC helpers) so libgcc + COMDAT dedup still resolve
#           them at the final link.
#   4. A generated `dispatcher.c` (basename(argv[0]) → `<san>_main`,
#      plus a `util-linux <applet>` form so the primary binary stays
#      callable without renaming/symlinking) is compiled separately.
#   5. The final link is delegated to upstream's `Makefile` via an
#      injected `unpin-multicall.mk` fragment that reuses upstream's
#      lib variables (`$(libcommon_la_OBJECTS)`, `$(libmount_la_OBJECTS)`,
#      etc.) so we don't hard-code per-target lib paths. Linux-i686 PIC
#      thunks still need `-Wl,--start-group … -lgcc … --end-group`
#      (same situation as e2fsprogs).
#   6. We replace upstream's installed binaries with the single multicall
#      plus argv[0]-dispatch symlinks, then `lib.withAliases` harvests
#      those symlinks for the UNPIN_META block — same shape as
#      coreutils/kmod/e2fsprogs.
#
# Linux-only: util-linux talks to Linux-specific syscalls (mount,
# init_module-adjacent), block-device ioctls, and parses /proc and /sys
# extensively. `meta.platforms` in nixpkgs is `*-linux` only.
{ lib }:
pkgs:
let
  # ELF-only recipe: util-linux is Linux-only, so we don't need the
  # Mach-O branch from e2fsprogs.nix.
  multicall = pkgs.pkgsStatic.util-linux.overrideAttrs (old: {
    pname = "util-linux-multi";

    postBuild = (old.postBuild or "") + ''
      set -e
      mkdir -p multicall

      echo "=== util-linux multicall postBuild (cwd=$PWD) ==="

      # 1. Scan the post-configure Makefile for `am_<tool>_OBJECTS = …`.
      #    Lines with a leading `#` (conditional false → automake comments
      #    the whole block) are skipped. We strip continuations into a
      #    single line per tool, then emit `tool<TAB>obj1 obj2 …` to
      #    `multicall/tools.tsv`. .static variants share the same source
      #    set with our regular bundling, so we drop them up front.
      # automake leaves `$(OBJEXT)` literal in the generated Makefile
      # (it expands only at make time, OBJEXT=o for ELF/Mach-O). We
      # substitute manually so our path filter recognises the .o entries.
      #
      # Tools with conditional sources reach the final OBJECTS list via
      # `$(am__objects_N)` indirections — automake emits one helper
      # variable per source slot guarded by AM_CONDITIONALs. We build a
      # forward-pass map of `am__objects_N → .o list` and expand
      # references when we see them inside an `am_<san>_OBJECTS` block.
      # The Makefile orders the helpers before each tool's OBJECTS line,
      # so a single forward pass resolves everything.
      #
      # automake mangles `.` to `_` in variable names, so the program
      # `fsck.cramfs` becomes `am_fsck_cramfs_OBJECTS`. To recover the
      # original applet name (the one a user types) we read the build
      # rule line `<orig>$(EXEEXT): $(<san>_OBJECTS) …`. That gives the
      # mapping orig→san explicitly; we then write the dispatcher with
      # `{"fsck.cramfs", fsck_cramfs_main}`.
      #
      # `_la_OBJECTS` lines belong to libtool .lo objects (libcommon,
      # libmount, libblkid, …) — those get linked in once at the final
      # stage as static archives, not bundled per-tool.
      awk '
        function clean(s,   r) {
          r = s
          gsub(/@[A-Z_]+_TRUE@/, "", r)
          gsub(/@[A-Z_]+_FALSE@/, "", r)
          gsub(/\$\(OBJEXT\)/, "o", r)
          gsub(/\$\(EXEEXT\)/, "", r)
          return r
        }
        function read_block(start_line,   block, next_line) {
          block = start_line
          while (match(block, /\\$/)) {
            sub(/\\$/, "", block)
            if ((getline next_line) <= 0) break
            block = block " " next_line
          }
          return block
        }
        function expand_refs(s,   key, parts, n, i, out) {
          # Resolve $(am__objects_N) references using objMap.
          # Unresolved references drop silently — these are typically
          # conditional sources upstream did not configure in.
          n = split(s, parts, /[[:space:]]+/)
          out = ""
          for (i = 1; i <= n; i++) {
            if (parts[i] == "") continue
            if (match(parts[i], /^\$\(am__objects_[0-9]+\)$/)) {
              key = parts[i]; sub(/^\$\(/, "", key); sub(/\)$/, "", key)
              if (key in objMap) out = out " " objMap[key]
            } else {
              out = out " " parts[i]
            }
          }
          return out
        }
        # 1. am__objects_N helpers
        /^am__objects_[0-9]+[[:space:]]*=/ {
          name = $1
          block = clean(read_block($0))
          sub(/^[^=]*=[[:space:]]*/, "", block)
          objMap[name] = block
          next
        }
        # 2. am_<san>_OBJECTS = ... per-tool object lists
        /^am_[A-Za-z0-9_.-]+_OBJECTS[[:space:]]*=/ {
          if ($1 ~ /_la_OBJECTS$/) next
          san = $1
          sub(/^am_/, "", san)
          sub(/_OBJECTS$/, "", san)
          block = clean(read_block($0))
          sub(/^[^=]*=[[:space:]]*/, "", block)
          block = expand_refs(block)
          n = split(block, parts, /[[:space:]]+/)
          filtered = ""
          for (i = 1; i <= n; i++) {
            if (parts[i] ~ /\.o$/) filtered = filtered " " parts[i]
          }
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", filtered)
          if (filtered != "") sanObjs[san] = filtered
          next
        }
        # 3. <orig>$(EXEEXT): $(<san>_OBJECTS) … — read the build rule
        #    to recover the original applet name (with dots intact).
        /^[A-Za-z0-9_.-]+\$\(EXEEXT\):[[:space:]]+\$\([A-Za-z0-9_-]+_OBJECTS\)/ {
          orig = $1
          sub(/\$\(EXEEXT\):.*/, "", orig)
          # find the san reference in remaining text
          rest = $0
          if (match(rest, /\$\([A-Za-z0-9_-]+_OBJECTS\)/)) {
            ref = substr(rest, RSTART, RLENGTH)
            san = ref
            sub(/^\$\(/, "", san); sub(/_OBJECTS\)$/, "", san)
            origMap[san] = orig
          }
          next
        }
        END {
          for (san in sanObjs) {
            orig = (san in origMap) ? origMap[san] : san
            print orig "\t" san "\t" sanObjs[san]
          }
        }
      ' Makefile > multicall/tools.tsv

      # 2. Filter the raw tool list:
      #    - drop `.static` variants (same source set as the regular one,
      #      and the per-program "_static_OBJECTS" lines double-list each
      #      .o file via $(am__objects_N) style indirections we don't try
      #      to resolve here);
      #    - drop `test_*` and `sample_*` programs — upstream declares
      #      `am_<name>_OBJECTS` for those even when they aren't built
      #      (they live behind --enable-tests/-samples which pkgsStatic
      #      doesn't pass), so their .o files simply don't exist on disk;
      #    - verify every listed .o exists. A surviving record with one
      #      missing object would crash `ld -r`; instead skip the tool
      #      and log it. This makes the recipe self-pruning if upstream
      #      adds a new conditional-built program without a matching
      #      AM_CONDITIONAL guard on its OBJECTS line.
      awk -F'\t' '
        $1 !~ /\.static$/ && $1 !~ /^test_/ && $1 !~ /^sample_/ {
          n = split($3, parts, /[[:space:]]+/)
          ok = 1
          for (i = 1; i <= n; i++) {
            if (parts[i] != "") {
              cmd = "test -f \"" parts[i] "\""
              if (system(cmd) != 0) { ok = 0; break }
            }
          }
          if (ok) print
          else print "SKIP " $1 " (missing .o files)" > "/dev/stderr"
        }
      ' multicall/tools.tsv > multicall/tools.filtered.tsv

      echo "=== util-linux multicall: $(wc -l < multicall/tools.filtered.tsv) tools to bundle ==="
      if [ ! -s multicall/tools.filtered.tsv ]; then
        echo "ERROR: no tools to bundle. Makefile parsing mismatch?" >&2
        exit 1
      fi

      # 3. Per-tool: ld -r + iterated --redefine-sym to rename
      #    main → <san>_main and every other defined global → <san>__<sym>.
      __ul_combine() {
        local san=$1 objs=$2
        $LD -r -o multicall/$san.combined.o $objs
        local -a redefs=()
        while read -r old new; do
          [ -n "$old" ] || continue
          redefs+=(--redefine-sym "$old=$new")
        done < <(
          $NM --defined-only -g multicall/$san.combined.o \
            | awk -v s="$san" \
                '$2 ~ /^[TBDR]$/ && $3 !~ /^__x86\.get_pc_thunk\./ {
                    old = $3
                    if (old == "main") new = s "_main"
                    else                new = s "__" old
                    print old, new
                }'
        )
        if [ ''${#redefs[@]} -gt 0 ]; then
          $OBJCOPY "''${redefs[@]}" multicall/$san.combined.o
        fi
      }

      # Drive the per-tool loop. Build two parallel manifests:
      #   - combined.list: the list of .combined.o paths (final link input)
      #   - applets.list:  TSV `orig<TAB>san` (for dispatcher.c generation
      #                    and for the post-install applet symlink set)
      : > multicall/combined.list
      : > multicall/applets.list
      while IFS=$'\t' read -r orig san objs; do
        __ul_combine "$san" "$objs"
        echo "multicall/$san.combined.o" >> multicall/combined.list
        printf '%s\t%s\n' "$orig" "$san" >> multicall/applets.list
      done < multicall/tools.filtered.tsv

      # 4b. Walk upstream's install-exec-hook to discover the extra
      #     argv[0]-dispatch aliases automake-rule-creates by `ln -sf`
      #     (setarch → uname26/linux32/linux64/i386/x86_64/…, last →
      #     lastb, vipw → vigr, …). We run the hook into a sandbox dir
      #     so `make` actually executes the ln commands without touching
      #     the real $bin — and `ln -sf` is happy creating dangling
      #     symlinks since the target binaries don't exist there. Then
      #     we scan the sandbox, look up each link's target in
      #     applets.list (now indexed by `orig` name), and append the
      #     alias rows pointing at the same `<san>_main`.
      mkdir -p multicall/sandbox-bin
      make install-exec-hook \
        DESTDIR="$PWD/multicall" \
        bindir=/sandbox-bin sbindir=/sandbox-bin \
        usrbin_execdir=/sandbox-bin usrsbin_execdir=/sandbox-bin \
        >/dev/null 2>&1 || true
      if [ -d multicall/sandbox-bin ]; then
        for link in multicall/sandbox-bin/*; do
          [ -L "$link" ] || continue
          alias_name=$(basename "$link")
          target=$(readlink "$link")
          target=$(basename "$target")
          # Lookup san for the target (it must already be in applets.list)
          san=$(awk -F'\t' -v t="$target" '$1 == t { print $2 }' \
            multicall/applets.list | head -1)
          if [ -n "$san" ]; then
            # Avoid duplicate entries
            if ! awk -F'\t' -v n="$alias_name" '$1 == n { found=1 } END { exit !found }' \
                multicall/applets.list; then
              printf '%s\t%s\n' "$alias_name" "$san" >> multicall/applets.list
            fi
          fi
        done
      fi
      echo "=== applets.list after alias scan ($(wc -l < multicall/applets.list) entries) ==="

      # 5. Generate dispatcher.c — declarations + applet table.
      {
        echo '#include <string.h>'
        echo '#include <stdio.h>'
        echo
        while IFS=$'\t' read -r tool san; do
          echo "int ''${san}_main(int argc, char *argv[]);"
        done < multicall/applets.list
        echo
        echo 'struct applet { const char *name; int (*fn)(int, char **); };'
        echo
        echo 'static const struct applet applets[] = {'
        while IFS=$'\t' read -r tool san; do
          printf '    {"%s", %s_main},\n' "$tool" "$san"
        done < multicall/applets.list
        echo '    {NULL, NULL}'
        echo '};'
        cat <<'DISPATCHER_TAIL'

int main(int argc, char *argv[])
{
    char *name = argv[0];
    char *slash = strrchr(name, '/');
    if (slash) name = slash + 1;
    if (strncmp(name, "lt-", 3) == 0) name += 3;

    if (strcmp(name, "util-linux") == 0) {
        if (argc < 2) {
            fprintf(stderr, "util-linux: usage: %s <applet> [args...]\n", argv[0]);
            fprintf(stderr, "applets (%zu):", sizeof(applets)/sizeof(applets[0]) - 1);
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
    fprintf(stderr, "util-linux: unknown applet '%s'\n", name);
    return 1;
}
DISPATCHER_TAIL
      } > multicall/dispatcher.c

      $CC -O2 -c -o multicall/dispatcher.o multicall/dispatcher.c

      # 6. Inject the final-link makefile fragment. We reuse upstream
      #    libtool archives (.libs/lib*.a). Linux-i686 needs the
      #    --start-group + -lgcc song-and-dance for `__x86.get_pc_thunk.*`
      #    helper resolution (same root cause as e2fsprogs); other ELF
      #    arches treat MULTI_LIBGCC/MULTI_GROUP_* as a no-op.
      install -m644 ${multicallMk} unpin-multicall.mk

      make -f Makefile -f unpin-multicall.mk \
        MULTI_COMBINED_OBJS="$(tr '\n' ' ' < multicall/combined.list)" \
        MULTI_GROUP_OPEN="-Wl,--start-group" \
        MULTI_GROUP_CLOSE="-Wl,--end-group" \
        MULTI_LIBGCC="-lgcc" \
        multicall-link
    '';

    # Replace upstream's 123 separate binaries with the single multicall +
    # applet symlinks. Wipe both `$bin/bin` AND `$bin/sbin` (nixpkgs'
    # `_moveSbinToBin` fixupPhase otherwise re-merges sbin into bin and
    # resurrects the originals next to our multicall).
    postInstall = (old.postInstall or "") + ''
      rm -rf "$bin/bin" "$bin/sbin"
      mkdir -p "$bin/bin"
      install -m755 multicall/util-linux "$bin/bin/util-linux"
      while IFS=$'\t' read -r tool san; do
        ln -s util-linux "$bin/bin/$tool"
      done < multicall/applets.list
    '';
  });

  # Custom makefile fragment that links the multicall against upstream's
  # libtool libs. `LIBS` and `MULTI_*` come from upstream's link flags +
  # our caller. `MULTI_COMBINED_OBJS` is passed on the make command line
  # because the per-tool list is computed at postBuild time from
  # `multicall/combined.list`. `.libs/libcommon.a` etc. are the static
  # archives libtool emits when configure sees --enable-static.
  #
  # Internal lib order doesn't strictly matter thanks to --start-group,
  # but we list dep-order anyway for readability. Variable references
  # to the $(*_LIBS) system-lib slots (REALTIME, POSIXIPC, MQ, NCURSES,
  # SELINUX, TINFO, READLINE, ...) cover whatever configure detected;
  # any unset slot expands to empty, so listing them all is safe and
  # forward-compatible if upstream adds new ones.
  multicallMk = pkgs.writeText "unpin-util-linux-multicall.mk" ''
    MULTI_OUT ?= multicall/util-linux

    .PHONY: multicall-link
    multicall-link: $(MULTI_OUT)

    # `$(wildcard .libs/lib*.a)` catches whatever convenience archives
    # configure left behind without us having to know which features
    # were enabled (liblastlog2 only exists when --enable-liblastlog2,
    # liblastlog2-deprecated, etc.). By the time `multicall-link` fires,
    # upstream's `make` has already produced every prerequisite (the
    # per-tool .o's we passed to `ld -r` were built then).
    # Per-tool LDADDs in util-linux hard-code several `-l<lib>` flags
    # (setpriv → -lcap-ng, sulogin → -lcrypt, zramctl → -lz, lastlog2
    # → -lsqlite3, …). The propagated buildInputs of `pkgsStatic.util-linux`
    # mirror this set (zlib, libxcrypt, sqlite, libcap-ng, ncurses). Listing
    # them directly avoids having to parse per-tool LDADDs. PAM/selinux/
    # systemd/audit are NOT in the pkgsStatic buildInputs (configure
    # disables their tools), so we don't link them.
    $(MULTI_OUT): multicall/dispatcher.o $(MULTI_COMBINED_OBJS)
    	$(CC) $(AM_LDFLAGS) $(LDFLAGS) -o $@ \
    		multicall/dispatcher.o $(MULTI_COMBINED_OBJS) \
    		$(MULTI_GROUP_OPEN) \
    		$(wildcard .libs/lib*.a) \
    		-lcap-ng -lcrypt -lz -lsqlite3 \
    		$(LIBUSER_LIBS) $(MAGIC_LIBS) $(MATH_LIBS) $(MQ_LIBS) \
    		$(NCURSES_LIBS) $(POSIXIPC_LIBS) $(READLINE_LIBS) \
    		$(REALTIME_LIBS) $(RTAS_LIBS) $(SELINUX_LIBS) \
    		$(SYSTEMD_DAEMON_LIBS) $(SYSTEMD_JOURNAL_LIBS) \
    		$(SYSTEMD_LIBS) $(TINFO_LIBS) \
    		$(LIBS) \
    		$(MULTI_LIBGCC) \
    		$(MULTI_GROUP_CLOSE)
  '';
in
lib.withAliases pkgs
  {
    primary = "util-linux";
    aliasesFromSymlinksIn = "bin";
  }
  multicall
