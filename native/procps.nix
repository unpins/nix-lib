# Upstream procps-ng ships 17 separate binaries (ps, top, free, kill,
# pgrep/pkill/pidwait, pidof, pmap, pwdx, slabtop, hugetop, sysctl,
# tload, uptime, vmstat, watch). All share `local/strutils.c`,
# `local/fileutils.c`, `local/signals.c`, `local/units.c`, and the
# generated per-tool helpers; automake compiles each .c with a
# per-program prefix (`src_kill-strutils.o` vs `src_pgrep-strutils.o`)
# so the .o files don't collide on disk, but the SYMBOL names inside
# (`set_program_name`, `strutils_…`, …) are identical → can't link
# them all into one binary without privatising the per-tool globals.
#
# Same post-link recipe as e2fsprogs / util-linux (see
# `[[feedback-post-link-multicall-recipe]]`):
#
#   1. `make` runs upstream normally — every tool's .o set lands in
#      `src/`, `src/ps/`, `src/top/`, `local/`.
#   2. Scan the post-configure `Makefile` for `am_<san>_OBJECTS = …`.
#      Per-tool helpers and `am__objects_N` indirections resolved the
#      same way as util-linux.nix. `_la_OBJECTS` (libproc2.la, libtool
#      convenience archive) skipped.
#   3. For each program: `ld -r` → partial-link object; `objcopy
#      --redefine-sym` renames `main` → `<san>_main` and every other
#      defined global `foo` → `<san>__foo` (privately scoped across
#      the final link). COMDAT thunks (`__x86.get_pc_thunk.*`) skipped.
#   4. Generate `dispatcher.c` (basename(argv[0]) → `<san>_main` plus
#      `procps-ng <applet>` form). The build-rule name maps to the
#      installed name via two transforms: (a) basename strip
#      (`src/top/top` → `top`, `src/ps/pscommand` → `pscommand`);
#      (b) `pscommand` → `ps` (procps's `transform` rule). Both applied
#      before emitting dispatcher entries.
#   5. Final link delegated to upstream's Makefile via injected
#      `unpin-multicall.mk` — reuses `$(LDADD)` resolution including
#      `library/libproc2.la` (libtool archive) and any system-lib
#      variables configure detected.
#   6. Strip upstream binaries and replace with one `procps-ng` plus
#      argv[0]-dispatch symlinks; `lib.withAliases` harvests them.
#
# Linux-only: procps reads `/proc` exhaustively; `meta.platforms` is
# `*-linux` and several deeper headers (`<sys/sysinfo.h>`) are Linux-
# specific.
{ lib }:
pkgs:
let
  multicall = pkgs.pkgsStatic.procps.overrideAttrs (old: {
    pname = "procps-ng-multi";

    postBuild = (old.postBuild or "") + ''
      set -e
      mkdir -p multicall

      echo "=== procps-ng multicall postBuild (cwd=$PWD) ==="

      # 1. Scan post-configure Makefile for `am_<san>_OBJECTS = …` and
      #    `<orig>$(EXEEXT): $(<san>_OBJECTS)` build rules. Strip out
      #    conditional-false @COND_FALSE@ markers, expand $(OBJEXT) and
      #    $(EXEEXT), resolve $(am__objects_N) indirections. Skip
      #    `_la_OBJECTS` (libtool .lo, linked at final stage as .a).
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
        /^am__objects_[0-9]+[[:space:]]*=/ {
          name = $1
          block = clean(read_block($0))
          sub(/^[^=]*=[[:space:]]*/, "", block)
          objMap[name] = block
          next
        }
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
        /^[A-Za-z0-9_./-]+\$\(EXEEXT\):[[:space:]]+\$\([A-Za-z0-9_-]+_OBJECTS\)/ {
          orig = $1
          sub(/\$\(EXEEXT\):.*/, "", orig)
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

      # 2. Filter:
      #    - drop tests/test_* (built only with --enable-tests);
      #    - drop sample_* if any;
      #    - skip tools whose .o set has missing files (conditional
      #      builds upstream didn't actually compile);
      #    - apply procps installed-name transform:
      #        src/top/top         → top
      #        src/ps/pscommand    → ps
      #        src/<name>          → <name>
      awk -F'\t' '
        $1 !~ /^src\/tests\// && $1 !~ /^sample_/ {
          n = split($3, parts, /[[:space:]]+/)
          ok = 1
          for (i = 1; i <= n; i++) {
            if (parts[i] != "") {
              cmd = "test -f \"" parts[i] "\""
              if (system(cmd) != 0) { ok = 0; break }
            }
          }
          if (!ok) {
            print "SKIP " $1 " (missing .o files)" > "/dev/stderr"
            next
          }
          orig = $1
          # Strip dirname → basename
          n = split(orig, p, "/")
          installed = p[n]
          # procps `transform = s/pscommand/ps/`
          if (installed == "pscommand") installed = "ps"
          print installed "\t" $2 "\t" $3
        }
      ' multicall/tools.tsv > multicall/tools.filtered.tsv

      echo "=== procps-ng multicall: $(wc -l < multicall/tools.filtered.tsv) tools to bundle ==="
      cat multicall/tools.filtered.tsv | awk -F'\t' '{ print "  " $1 " ← " $2 }' >&2
      if [ ! -s multicall/tools.filtered.tsv ]; then
        echo "ERROR: no tools to bundle. Makefile parsing mismatch?" >&2
        exit 1
      fi

      # 3. Per-tool: ld -r + iterated --redefine-sym.
      __procps_combine() {
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

      : > multicall/combined.list
      : > multicall/applets.list
      while IFS=$'\t' read -r tool san objs; do
        __procps_combine "$san" "$objs"
        echo "multicall/$san.combined.o" >> multicall/combined.list
        printf '%s\t%s\n' "$tool" "$san" >> multicall/applets.list
      done < multicall/tools.filtered.tsv

      # 4. dispatcher.c
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

    if ((strcmp(name, "procps-ng") == 0 || strcmp(name, "procps") == 0)
        && argc >= 2 && argv[1][0] != '-') {
        name = argv[1];
        argv++;
        argc--;
    }

    for (const struct applet *a = applets; a->name; a++) {
        if (strcmp(name, a->name) == 0)
            return a->fn(argc, argv);
    }
    /* Default route: --version, --help, and binaries renamed by the
       CI smoke step (smoke) land in ps. ps's getopt handles --version
       regardless of argv[0]. */
    return src_ps_pscommand_main(argc, argv);
}
DISPATCHER_TAIL
      } > multicall/dispatcher.c

      $CC -O2 -c -o multicall/dispatcher.o multicall/dispatcher.c

      # 5. Final link via injected Makefile fragment.
      install -m644 ${multicallMk} unpin-multicall.mk

      make -f Makefile -f unpin-multicall.mk \
        MULTI_COMBINED_OBJS="$(tr '\n' ' ' < multicall/combined.list)" \
        MULTI_GROUP_OPEN="-Wl,--start-group" \
        MULTI_GROUP_CLOSE="-Wl,--end-group" \
        MULTI_LIBGCC="-lgcc" \
        multicall-link
    '';

    # Replace upstream's per-tool binaries with one multicall + applet
    # symlinks. nixpkgs `_moveSbinToBin` in fixupPhase would re-merge
    # sbin/ into bin/ — clear both even though procps has very few sbin
    # entries (just sysctl).
    postInstall = (old.postInstall or "") + ''
      rm -rf "$out/bin" "$out/sbin"
      mkdir -p "$out/bin"
      install -m755 multicall/procps-ng "$out/bin/procps-ng"
      while IFS=$'\t' read -r tool san; do
        ln -s procps-ng "$out/bin/$tool"
      done < multicall/applets.list
    '';
  });

  # libtool emits `library/.libs/libproc2.a` for the convenience archive.
  # slabtop/top/watch/tload/hugetop pull ncurses + tinfo for the live UI;
  # those come via `propagatedBuildInputs` (ncurses-static-dev) so
  # configure detects them via pkg-config and sets $(NCURSES_LIBS) +
  # $(TINFO_LIBS). $(MATH_LIBS) is wanted by top. The rest of the
  # configure-detected lib slots stay empty under pkgsStatic (no
  # systemd / selinux / namespace headers).
  multicallMk = pkgs.writeText "unpin-procps-multicall.mk" ''
    MULTI_OUT ?= multicall/procps-ng

    .PHONY: multicall-link
    multicall-link: $(MULTI_OUT)

    $(MULTI_OUT): multicall/dispatcher.o $(MULTI_COMBINED_OBJS)
    	$(CC) $(AM_LDFLAGS) $(LDFLAGS) -o $@ \
    		multicall/dispatcher.o $(MULTI_COMBINED_OBJS) \
    		$(MULTI_GROUP_OPEN) \
    		library/.libs/libproc2.a \
    		$(NCURSES_LIBS) $(TINFO_LIBS) $(MATH_LIBS) \
    		$(SYSTEMD_LIBS) $(SELINUX_LIBS) $(NAMESPACE_LIBS) \
    		$(LIBS) \
    		$(MULTI_LIBGCC) \
    		$(MULTI_GROUP_CLOSE)
  '';
in
lib.withAliases pkgs
  {
    primary = "procps-ng";
    aliasesFromSymlinksIn = "bin";
  }
  multicall
