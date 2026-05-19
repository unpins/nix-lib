# Setup hook for `pkgs.pkgsCross.cosmo`: every ELF binary in $out/bin
# gets apelinked to PE32+ and renamed `<name>` → `<name>.exe`. Same-
# directory symlinks whose target was just renamed get rewired so
# the package's own multi-name surface (ncurses' `reset → tset`,
# coreutils symlink set, etc.) survives.
#
# Detection chain:
#   - Skip symlinks, non-regular, non-executable, already-`.exe`
#   - Skip non-ELF (scripts, wrappers — first 4 bytes != `\x7fELF`)
#   - On ELF: invoke apelink. If output produced → rename. If apelink
#     fails to produce output → FAIL THE BUILD with a clear error
#     message (most common cause: upstream Makefile stripped the
#     binary during install, removing the .symtab apelink requires).
#
# Phase ordering (preFixupHook):
#   - postInstall (consumer install + symlinks + `lib.withAliases`
#     symlink harvest) has already happened → harvest saw the
#     non-`.exe` names.
#   - postFixup (consumer cleanup + `lib.withAliases` UNPIN_META embed
#     via `primary = "<name>.exe"`) runs after → embed operates on
#     the final `.exe`.
#
# Consumer guidance:
#   - Drop unwanted cosmocc-emitted bins (e.g. bash's `sh`/`bashbug`,
#     gawk's `awk` symlink) in postInstall, not postFixup — by
#     postFixup time the files are renamed to `.exe`.
#   - If upstream's `make install` runs `strip` (or upstream's
#     LDFLAGS include `-s`), override it. Common knobs:
#       installFlags = [ "STRIP=true" ];   # GNU-style
#       installFlags = [ "STRIPCMD=true" ];
#       env.NIX_LDFLAGS_BEFORE = "...";    # last-resort
#     Apelink needs the ELF symbol table; stripped binaries can't be
#     converted to PE32+.
#   - To ship a raw ELF instead of `.exe`, set
#     `dontCosmoApelink = true;` in mkDerivation attrs.
cosmoApelinkBins() {
    [ "${dontCosmoApelink:-0}" = 1 ] && return 0
    [ -d "$prefix/bin" ] || return 0
    local bin

    # Phase 1: apelink real binaries. Each `<name>` ELF that succeeds
    # becomes `<name>.exe`; the original `<name>` is removed.
    for bin in "$prefix"/bin/*; do
        [ -f "$bin" ] && [ ! -L "$bin" ] || continue
        case "$bin" in *.exe) continue ;; esac
        [ -x "$bin" ] || continue
        # ELF magic. Non-ELF (scripts, etc.) are skipped silently.
        local magic
        magic=$(head -c 4 "$bin" 2>/dev/null | od -An -tx1 | tr -d ' \n')
        [ "$magic" = "7f454c46" ] || continue
        local err
        err=$(@apelink@ -V @vbits@ -o "${bin}.exe" "$bin" 2>&1) || true
        if [ -f "${bin}.exe" ]; then
            rm -f "$bin"
        else
            echo "" >&2
            echo "cosmoApelinkBins: apelink failed on $bin" >&2
            [ -n "$err" ] && echo "  apelink stderr: $err" >&2
            echo "" >&2
            echo "Most common cause: upstream Makefile stripped the binary" >&2
            echo "during install, removing the .symtab apelink requires." >&2
            echo "Fix in the consumer's overrideAttrs (one of):" >&2
            echo "  installFlags = [ \"STRIP=true\" ];   # or STRIPCMD=true" >&2
            echo "  env.NIX_CFLAGS_LINK = \"...\";       # drop -s from LDFLAGS" >&2
            echo "Alternative: opt out and ship raw ELF instead of .exe:" >&2
            echo "  dontCosmoApelink = true;" >&2
            echo "" >&2
            return 1
        fi
    done

    # Phase 2: rewire dangling symlinks whose target's basename
    # matches a freshly-renamed `.exe` in this same $prefix/bin.
    # Covers both relative links (ncurses' `reset -> tset`) and
    # absolute-within-$out (nixpkgs alias drvs that write
    # `xxd -> $out/bin/tinyxxd`). Symlinks pointing to other drvs
    # don't dangle here, so they're naturally skipped by the
    # `[ ! -e "$link" ]` test.
    local link target basetarget newname
    for link in "$prefix"/bin/*; do
        [ -L "$link" ] || continue
        [ -e "$link" ] && continue       # not dangling → nothing to do
        target=$(readlink "$link")
        basetarget="${target##*/}"
        case "$basetarget" in *.exe) continue ;; esac
        [ -e "$prefix/bin/${basetarget}.exe" ] || continue
        case "${link##*/}" in
            *.exe) newname="$link" ;;
            *)     newname="${link}.exe" ;;
        esac
        ln -sf "${basetarget}.exe" "$newname"
        [ "$newname" = "$link" ] || rm -f "$link"
    done
}
preFixupHooks+=(cosmoApelinkBins)
