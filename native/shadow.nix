# Upstream shadow ships ~32 separate binaries (login, passwd, su, useradd,
# usermod, chage, chfn, chsh, expiry, faillog, gpasswd, newgrp, groupadd,
# groupdel, groupmod, …), each its own static ELF in pkgsStatic. To honour
# the one-pkg-one-bin rule we post-link them into a single multicall using
# the same recipe proven on e2fsprogs and util-linux
# (see [[feedback-post-link-multicall-recipe]]).
#
# Differences from util-linux:
#   - shadow's Makefile lives in src/, not the package root.
#   - Most tools are single-source: automake emits `<tool>_OBJECTS = <tool>.o`
#     directly (no `am_<tool>_OBJECTS` indirection). Only `login` and `su`
#     are multi-source. We read `<tool>_OBJECTS` lines and resolve the
#     `am_<tool>_OBJECTS` indirection on the fly.
#   - The set of programs to bundle is gated by configure feature flags
#     (`WITH_SU`, `ENABLE_SUBIDS`, `ENABLE_LASTLOG`). Rather than guess we
#     consume the resolved installed-PROGRAMS lists from the Makefile —
#     `bin_PROGRAMS`, `sbin_PROGRAMS`, `ubin_PROGRAMS`, `usbin_PROGRAMS`,
#     each with `$(am__EXEEXT_N)` slots that expand to the conditional
#     applets actually built. `noinst_PROGRAMS` (sulogin — already shipped
#     in util-linux — and the libsubid test helpers) is excluded.
#   - Aliases: shadow installs two symlinks in its `install-am` rule
#     (`sg → newgrp`, `vigr → vipw`). We discover them by parsing
#     `ln -sf … $(DESTDIR)$(<dir>)/<alias>` lines from the Makefile rather
#     than running a sandboxed install (one fewer moving part).
#   - nixpkgs splits `su` into its own output (`outputs = [out su dev man]`,
#     postInstall moves `$out/bin/su` → `$su/bin/`). Our recipe absorbs su
#     into the multicall, so we drop the `su` output and replace nixpkgs's
#     postInstall entirely.
#   - Final-link libs: `lib/.libs/libshadow.a` + `libsubid/.libs/libsubid.a`
#     + `-lcrypt -lbsd` (mirrors `pkgsStatic.shadow.propagatedBuildInputs`:
#     libxcrypt-static + libbsd-static). No PAM/SELinux/audit — pkgsStatic
#     configure disables those, so the per-tool LDADD references resolve to
#     empty.
#
# Linux-only: shadow uses Linux-specific /etc/{passwd,shadow,group,gshadow}
# semantics, subuid/subgid via newuidmap, namespace-friendly setuid binaries.
# `meta.platforms` in nixpkgs is `*-linux` only.
{ lib }:
pkgs:
let
  multicall = pkgs.pkgsStatic.shadow.overrideAttrs (old: {
    pname = "shadow-multi";

    # Drop the nixpkgs `su` output split: we want su inside the multicall.
    outputs = [ "out" "dev" "man" ];

    postBuild = (old.postBuild or "") + ''
      set -e
      cd src
      mkdir -p multicall

      echo "=== shadow multicall postBuild (cwd=$PWD) ==="

      # Parse the post-configure Makefile.
      #
      # Pass 1 (line-by-line): capture `am__EXEEXT_N = …`, `am_<tool>_OBJECTS = …`,
      #         `<tool>_OBJECTS = …` definitions, plus the raw text of each
      #         `<dir>_PROGRAMS = …` line. We DEFER resolving `$(am__EXEEXT_N)`
      #         and `$(am_<tool>_OBJECTS)` references because automake emits the
      #         PROGRAMS lists BEFORE the am__EXEEXT_N helpers, and `<tool>_OBJECTS`
      #         BEFORE `am_<tool>_OBJECTS` is sometimes the case too. A single
      #         forward-pass would miss every conditional slot (su, getsubids,
      #         newgidmap, newuidmap), so resolution happens in END {} after the
      #         file is fully ingested.
      #
      # Pass 2 (END): resolve `$(am__EXEEXT_N)` in each captured PROGRAMS line
      #         and emit the installed-tool set. Drop `noinst_PROGRAMS` —
      #         sulogin lives in util-linux and the libsubid test helpers
      #         (check_subid_range, free_subid_range, get_subid_owners,
      #         new_subid_range) aren't user-facing.
      #
      # Pass 3 (END): for each installed tool, resolve `$(am_<tool>_OBJECTS)`
      #         in its OBJECTS list. Single-source tools have
      #         `<tool>_OBJECTS = <tool>.o` directly. Multi-source ones
      #         (login, su) have `<tool>_OBJECTS = $(am_<tool>_OBJECTS)` where
      #         `am_<tool>_OBJECTS` lists the actual files.
      #
      # Output: `tool<TAB>objs` per installed program with a non-empty
      # objects list and all .o files present on disk.
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
        # Pass 1: capture raw definitions; defer resolution to END.
        /^am__EXEEXT_[0-9]+[[:space:]]*=/ {
          name = $1
          block = clean(read_block($0))
          sub(/^[^=]*=[[:space:]]*/, "", block)
          exeMap[name] = block
          next
        }
        /^(bin|sbin|ubin|usbin)_PROGRAMS[[:space:]]*=/ {
          block = clean(read_block($0))
          sub(/^[^=]*=[[:space:]]*/, "", block)
          progLines[++nProgLines] = block
          next
        }
        /^am_[A-Za-z0-9_]+_OBJECTS[[:space:]]*=/ {
          name = $1
          sub(/^am_/, "", name); sub(/_OBJECTS$/, "", name)
          block = clean(read_block($0))
          sub(/^[^=]*=[[:space:]]*/, "", block)
          amObj[name] = block
          next
        }
        /^[A-Za-z0-9_]+_OBJECTS[[:space:]]*=/ {
          name = $1
          sub(/_OBJECTS$/, "", name)
          if (name ~ /_la$/) next  # libshadow / libsubid libtool objects
          block = clean(read_block($0))
          sub(/^[^=]*=[[:space:]]*/, "", block)
          rawObj[name] = block
          next
        }
        END {
          # Resolve PROGRAMS lines into installed[]
          for (i = 1; i <= nProgLines; i++) {
            n = split(progLines[i], parts, /[[:space:]]+/)
            for (j = 1; j <= n; j++) {
              p = parts[j]
              if (p == "") continue
              if (match(p, /^\$\(am__EXEEXT_[0-9]+\)$/)) {
                key = p; sub(/^\$\(/, "", key); sub(/\)$/, "", key)
                if (key in exeMap) {
                  m = split(exeMap[key], pp, /[[:space:]]+/)
                  for (k = 1; k <= m; k++)
                    if (pp[k] != "") installed[pp[k]] = 1
                }
              } else {
                installed[p] = 1
              }
            }
          }
          # Resolve OBJECTS per installed tool, expanding am_<tool>_OBJECTS.
          for (t in installed) {
            if (!(t in rawObj)) {
              print "SKIP " t " (no _OBJECTS line)" > "/dev/stderr"
              continue
            }
            block = rawObj[t]
            # Replace every $(am_<x>_OBJECTS) reference with its expansion.
            while (match(block, /\$\(am_[A-Za-z0-9_]+_OBJECTS\)/)) {
              ref = substr(block, RSTART, RLENGTH)
              key = ref; sub(/^\$\(am_/, "", key); sub(/_OBJECTS\)$/, "", key)
              repl = (key in amObj) ? amObj[key] : ""
              # Use gsub for the specific ref string (not regex) to handle
              # the parens safely.
              q = ref
              gsub(/[][()$\\.*+?^|]/, "\\\\&", q)
              if (!sub(q, repl, block)) break
            }
            # Keep only .o tokens.
            n = split(block, parts, /[[:space:]]+/)
            objs = ""
            for (j = 1; j <= n; j++)
              if (parts[j] ~ /\.o$/) objs = objs " " parts[j]
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", objs)
            if (objs != "") print t "\t" objs
            else print "SKIP " t " (no .o tokens after resolution)" > "/dev/stderr"
          }
        }
      ' Makefile > multicall/tools.tsv

      # Verify every listed .o exists; otherwise drop the row (self-pruning
      # if upstream adds a new conditional program with stale OBJECTS state).
      awk -F'\t' '
        {
          n = split($2, parts, /[[:space:]]+/)
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

      echo "=== shadow multicall: $(wc -l < multicall/tools.filtered.tsv) tools to bundle ==="
      if [ ! -s multicall/tools.filtered.tsv ]; then
        echo "ERROR: no tools to bundle. Makefile parsing mismatch?" >&2
        exit 1
      fi

      # Per-tool: ld -r the .o set, then rename main → <tool>_main and
      # every other defined global → <tool>__<sym>. Compiler-emitted COMDAT
      # thunks (`__x86.get_pc_thunk.*`) are skipped so libgcc + dedup
      # still resolve them at the final link.
      __sh_combine() {
        local tool=$1 objs=$2
        $LD -r -o multicall/$tool.combined.o $objs
        local -a redefs=()
        while read -r old new; do
          [ -n "$old" ] || continue
          redefs+=(--redefine-sym "$old=$new")
        done < <(
          $NM --defined-only -g multicall/$tool.combined.o \
            | awk -v s="$tool" \
                '$2 ~ /^[TBDR]$/ && $3 !~ /^__x86\.get_pc_thunk\./ {
                    old = $3
                    if (old == "main") new = s "_main"
                    else                new = s "__" old
                    print old, new
                }'
        )
        if [ ''${#redefs[@]} -gt 0 ]; then
          $OBJCOPY "''${redefs[@]}" multicall/$tool.combined.o
        fi
      }

      : > multicall/combined.list
      : > multicall/applets.list
      while IFS=$'\t' read -r tool objs; do
        __sh_combine "$tool" "$objs"
        echo "multicall/$tool.combined.o" >> multicall/combined.list
        printf '%s\t%s\n' "$tool" "$tool" >> multicall/applets.list
      done < multicall/tools.filtered.tsv

      # Capture install-am symlink aliases: `ln -sf <target> $(DESTDIR)$(...)/<alias>`.
      # shadow's hook adds `sg → newgrp` and `vigr → vipw`; auto-discovery
      # keeps the recipe correct if upstream adds more in the future.
      # `sed` regex captures (target, dir, alias); we drop dir.
      sed -nE 's|.*ln[[:space:]]+-sf[[:space:]]+([A-Za-z0-9_]+)[[:space:]]+\$\(DESTDIR\)\$\([a-z]+\)/([A-Za-z0-9_]+).*|\2\t\1|p' \
        Makefile > multicall/aliases.list || true
      if [ -s multicall/aliases.list ]; then
        while IFS=$'\t' read -r alias target; do
          [ -z "$alias" ] && continue
          # alias points at the target tool's <target>_main
          if awk -F'\t' -v t="$target" '$1 == t { found=1 } END { exit !found }' \
              multicall/applets.list; then
            if ! awk -F'\t' -v a="$alias" '$1 == a { found=1 } END { exit !found }' \
                multicall/applets.list; then
              printf '%s\t%s\n' "$alias" "$target" >> multicall/applets.list
            fi
          fi
        done < multicall/aliases.list
      fi
      echo "=== applets.list ($(wc -l < multicall/applets.list) entries) ==="

      # Dispatcher: basename(argv[0]) → <san>_main, plus `shadow <applet>`
      # fallback so the multicall is callable without renaming.
      {
        echo '#include <string.h>'
        echo '#include <stdio.h>'
        echo
        # Declarations: deduplicate over san (multiple aliases → same _main).
        awk -F'\t' '{ if (!(seen[$2]++)) print "int " $2 "_main(int argc, char *argv[]);" }' \
          multicall/applets.list
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

    if (strcmp(name, "shadow") == 0) {
        if (argc < 2) {
            fprintf(stderr, "shadow: usage: %s <applet> [args...]\n", argv[0]);
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
    fprintf(stderr, "shadow: unknown applet '%s'\n", name);
    return 1;
}
DISPATCHER_TAIL
      } > multicall/dispatcher.c

      $CC -O2 -c -o multicall/dispatcher.o multicall/dispatcher.c

      # Final link via injected makefile fragment. Reuses upstream's
      # convenience archives (lib/.libs/libshadow.a, libsubid/.libs/libsubid.a)
      # and links against the propagated buildInputs (libxcrypt, libbsd).
      # Linux-i686 PIC thunks resolve via the standard --start-group song.
      install -m644 ${multicallMk} unpin-multicall.mk

      make -f Makefile -f unpin-multicall.mk \
        MULTI_COMBINED_OBJS="$(tr '\n' ' ' < multicall/combined.list)" \
        MULTI_GROUP_OPEN="-Wl,--start-group" \
        MULTI_GROUP_CLOSE="-Wl,--end-group" \
        MULTI_LIBGCC="-lgcc" \
        multicall-link

      cd ..
    '';

    # Replace nixpkgs's install (which moves su to $su) entirely: wipe
    # $out/bin and $out/sbin, install the multicall + applet symlinks.
    postInstall = ''
      rm -rf "$out/bin" "$out/sbin"
      mkdir -p "$out/bin"
      install -m755 src/multicall/shadow "$out/bin/shadow"
      while IFS=$'\t' read -r tool san; do
        ln -s shadow "$out/bin/$tool"
      done < src/multicall/applets.list
    '';
  });

  multicallMk = pkgs.writeText "unpin-shadow-multicall.mk" ''
    MULTI_OUT ?= multicall/shadow

    .PHONY: multicall-link
    multicall-link: $(MULTI_OUT)

    # `$(top_builddir)/lib/.libs/libshadow.a` is the libtool convenience
    # archive used by every program. `libsubid.a` is needed for the subid
    # tools (newgidmap, newuidmap, getsubids). `-lcrypt -lbsd` cover
    # pkgsStatic.shadow's propagated buildInputs.
    #
    # Per-tool $(LIB*) slots (LIBSELINUX, LIBPAM, LIBAUDIT, …) expand to
    # empty when configure didn't find them — pkgsStatic disables those, so
    # we link only crypt + bsd. The `LIBS` ambient absorbs the autoconf
    # autodetect set on top.
    $(MULTI_OUT): multicall/dispatcher.o $(MULTI_COMBINED_OBJS)
    	$(CC) $(AM_LDFLAGS) $(LDFLAGS) -o $@ \
    		multicall/dispatcher.o $(MULTI_COMBINED_OBJS) \
    		$(MULTI_GROUP_OPEN) \
    		$(top_builddir)/lib/.libs/libshadow.a \
    		$(top_builddir)/libsubid/.libs/libsubid.a \
    		-lcrypt -lbsd \
    		$(LIBS) \
    		$(MULTI_LIBGCC) \
    		$(MULTI_GROUP_CLOSE)
  '';
in
lib.withAliases pkgs
  {
    primary = "shadow";
    aliasesFromSymlinksIn = "bin";
  }
  multicall
