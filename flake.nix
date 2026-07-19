{
  description = "Shared Nix helpers for unpins/* packages";

  # Bundled so consumers don't redeclare; bump propagates to every unpins/*.
  # Override via `inputs.unpins-lib.inputs.nixpkgs.follows = "nixpkgs"`.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs = { self, nixpkgs }:
    let
      lib = rec {
        # Canonical native targets. Editing here propagates to every unpins/* consumer.
        # forAllNative is pure nix (no nixpkgs.lib dep) so nix-lib stays standalone.
        nativeSystems = [
          "x86_64-linux"
          "aarch64-linux"
          "x86_64-darwin"
          "aarch64-darwin"
        ];

        forAllNative = f:
          builtins.listToAttrs
            (map (sys: { name = sys; value = f sys; }) nativeSystems);

        isLinuxSys = system: nixpkgs.lib.hasSuffix "-linux" system;
        isDarwinSys = system: nixpkgs.lib.hasSuffix "-darwin" system;

        # unpin-stdenv (route A): a bespoke stdenv over the standalone
        # `unpin-llvm` multicall toolchain (clang/lld + an on-demand,
        # variant-aware musl/libc++ sysroot, no nixpkgs cc-wrapper).
        #
        # The `toolchain` derivation is passed in by the CONSUMER, not taken as a
        # nix-lib flake input: `unpin-llvm` isn't published yet, so a hard input
        # would make nix-lib unresolvable for the whole catalog. Parameterising
        # keeps nix-lib's closure {nixpkgs} only.
        #
        # unpinSysroot bakes a read-only per-target sysroot; linking (not -c)
        # triggers the on-demand build of libc/CRTs (and libc++ when `cxx`). Bake
        # BOTH non-PIC and PIC variants: the cache is variant-aware and many build
        # systems force -fPIC even for a static target (zlib's configure does).
        # Without the PIC variant pre-baked the link fails writing the RO store
        # cache and configure silently mis-detects. `native` gates the sanity run
        # (cross can't exec on the builder); `cxx` the C++ half.
        unpinSysroot = { pkgs, toolchain ? unpinToolchain pkgs.stdenv.buildPlatform.system, triple, optClass ? "-O2", native ? false, cxx ? false }:
          pkgs.runCommand "unpin-sysroot-${triple}" { } ''
            export HOME=$TMPDIR
            export XDG_CACHE_HOME=$out/cache
            printf 'int main(void){return 0;}\n' > hello.c
            for pic in "" "-fPIC"; do
              ${toolchain}/bin/llvm clang -target ${triple} ${optClass} $pic hello.c -o hc
              ${nixpkgs.lib.optionalString native "./hc"}
            done
            ${nixpkgs.lib.optionalString cxx ''
              printf '#include <iostream>\nint main(){std::cout<<"";return 0;}\n' > hello.cpp
              for pic in "" "-fPIC"; do
                ${toolchain}/bin/llvm clang++ -target ${triple} ${optClass} $pic hello.cpp -o hcpp
                ${nixpkgs.lib.optionalString native "./hcpp"}
              done
            ''}
            echo "baked variants for ${triple}:"; find $out/cache/unpin-llvm -name .complete \
              | sed "s|$out/cache/unpin-llvm/||"
          '';

        # The vendored `unpin-llvm` build, from nix-lib's OWN pinned nixpkgs, so
        # the toolchain's LLVM version is locked together with nix-lib. Lazy.
        # `origPkgs` replicates the gc-sections-overlay scope mkStandaloneFlake's
        # `nixpkgsFor` hands the `llvm` package under catalog defaults, so the
        # vendored toolchain is byte-identical to the catalog `unpin-llvm` it was
        # validated as (same .drv, no rebuild) — the toolchain pulls those scoped
        # pkgsStatic.{zlib,zstd} as buildInputs.
        unpinToolchain = system:
          import ./toolchain {
            origPkgs = mkPkgsGC { inherit system; ssp = true; opt = null; pkgName = "llvm"; };
            inherit unpinPackTool;
          };

        # Shared engine plumbing for the Perl-family packages (unpins/perl,
        # unpins/biber). Under the unpin-llvm engine pkgsStatic is the bitcode
        # set, so perl + its XS/deps are all LLVM bitcode and the binary is
        # LTO-linked. The VFS that serves the embedded /zip @INC can't be bound by
        # `ld --wrap` or `objcopy --redefine-sym` (neither touches a bitcode
        # symtab), so perl's libc file-op refs are rewritten IN THE IR
        # (`llvm opt -S | sed | llvm opt`). `vfsSed` is the fix-prone core — the
        # darwin stat/lstat arch asymmetry lives there — so it gets ONE home here
        # instead of a copy in each flake that can silently drift.
        #
        # `introspectName` is the writeShellScript name for the bitcode-lowering
        # helper (per-package so hoisting keeps each cross drv byte-identical).
        enginePerl =
          { pkgs
          , sp ? pkgs.pkgsStatic
          , introspectName
          }:
          let
            multitool =
              "${unpinToolchain sp.stdenv.buildPlatform.system}/bin/llvm";
          in
          {
            inherit multitool;

            # perl-cross introspects target objects with readelf/objdump; under
            # the engine those are LTO bitcode ("not supported"). Lower a bitcode
            # arg to a native ELF object for the triple embedded in the module
            # before handing it to the real `llvm` tool; ELF args pass through.
            # -target is mandatory (else clang lowers to the x86_64 host -> wrong
            # sizes/endian). $1 = subtool; the object is perl-cross's last arg.
            # Build-host tool, cross only.
            bcIntrospect = sp.buildPackages.writeShellScript introspectName ''
              mt=${multitool}
              tool=$1; shift
              n=$#
              obj=''${!n}
              if [ -f "$obj" ] && [ "$(od -An -tx1 -N4 "$obj" 2>/dev/null | tr -d ' \n')" = 4243c0de ]; then
                triple=$("$mt" opt -S "$obj" -o - 2>/dev/null \
                  | sed -n 's/^target triple = "\(.*\)"/\1/p' | head -1)
                low=$(mktemp -d)/lowered.o
                if [ -n "$triple" ] && "$mt" clang -target "$triple" -fno-lto -x ir -c "$obj" -o "$low" 2>/dev/null; then
                  set -- "''${@:1:$((n - 1))}" "$low"
                fi
              fi
              exec "$mt" "$tool" "$@"
            '';

            # The engine bitcode shell helpers, interpolated into buildPhase after
            # `MT=<multitool>` is set. isbc + vfsSed + bcrewrite are used by every
            # Perl-family build; the archive variants (vfsArchiveFns) only by
            # biber.
            vfsShellFns = ''
              # bitcode magic: raw 4243c0de (linux) / darwin-wrapped dec0170b.
              isbc() { case "$(od -An -tx1 -N4 "$1" 2>/dev/null | tr -d ' \n')" in 4243c0de|dec0170b) return 0;; *) return 1;; esac; }
              # Rename perl's libc file-op refs to the VFS shims. @sym is a FUNCTION
              # symbol (sigil differs from %struct.stat), so @stat never touches
              # `struct stat`. darwin's SDK emits raw-label imports and the
              # stat/lstat spelling is ARCH-specific: x86_64 carries the legacy
              # inode32 ABI so the alias is `_stat$INODE64`, but arm64 was inode64
              # from day one so it's the PLAIN `_stat` (open/access are plain on
              # both arches). Miss the plain `_stat`/`_lstat` and perl's require
              # stat()s the real FS for /zip modules -> ENOENT -> "Can't locate
              # strict.pm" on arm64-darwin only. 32-bit musl's _REDIR_TIME64
              # renames stat->__stat_time64. Rules that miss a given IR are no-ops.
              vfsSed() {
                sed -i \
                  -e 's/@open\b/@unpinvfs_open/g' \
                  -e 's/@stat\b/@unpinvfs_stat/g' \
                  -e 's/@lstat\b/@unpinvfs_lstat/g' \
                  -e 's/@access\b/@unpinvfs_access/g' \
                  -e 's/@__stat_time64\b/@unpinvfs_stat/g' \
                  -e 's/@__lstat_time64\b/@unpinvfs_lstat/g' \
                  -e 's/@"\\01__stat_time64"/@unpinvfs_stat/g' \
                  -e 's/@"\\01__lstat_time64"/@unpinvfs_lstat/g' \
                  -e 's/@"\\01_open"/@unpinvfs_open/g' \
                  -e 's/@"\\01_access"/@unpinvfs_access/g' \
                  -e 's/@"\\01_stat"/@unpinvfs_stat/g' \
                  -e 's/@"\\01_lstat"/@unpinvfs_lstat/g' \
                  -e 's/@"\\01_stat\$INODE64"/@unpinvfs_stat/g' \
                  -e 's/@"\\01_lstat\$INODE64"/@unpinvfs_lstat/g' \
                  "$1"
              }
              bcrewrite() { $MT opt -S "$1" -o "$1.ll"; vfsSed "$1.ll"; $MT opt "$1.ll" -o "$1"; rm -f "$1.ll"; }
            '';

            # Archive-level variants, biber only (perl rewrites libperl.a members
            # by hand). bcrewriteArchive rewrites every bitcode member then repacks
            # with the bitcode-aware llvm ar; weakenArchive is the engine analogue
            # of objcopy --weaken-symbol (prepend `weak` to the matching define).
            vfsArchiveFns = ''
              bcrewriteArchive() {
                local a; a=$(readlink -f "$1"); local d; d=$(mktemp -d)
                ( cd "$d" && $MT ar x "$a" )
                for o in "$d"/*; do [ -f "$o" ] || continue; isbc "$o" && bcrewrite "$o"; done
                rm -f "$1" && $MT ar rcs "$1" "$d"/*
              }
              weakenArchive() {  # $1 = archive, $2 = symbol
                local a; a=$(readlink -f "$1"); local d; d=$(mktemp -d)
                ( cd "$d" && $MT ar x "$a" )
                for o in "$d"/*; do
                  [ -f "$o" ] || continue; isbc "$o" || continue
                  $MT opt -S "$o" -o "$o.ll"
                  sed -i -E "/@$2\(/ s/^define /define weak /" "$o.ll"
                  $MT opt "$o.ll" -o "$o"; rm -f "$o.ll"
                done
                rm -f "$1" && $MT ar rcs "$1" "$d"/*
              }
            '';
          };

        # mkUnpinStdenv (route A: bespoke, no cc-wrapper). Returns
        # `{ sysroot, unpinCC, cc, mkDerivation }` (mkDerivation = stdenvNoCC +
        # this toolchain).
        #
        # stackSize: musl's default THREAD stack is 128 KB vs glibc's 8 MB, and
        # glibc-developed software assumes the latter (a 137 KB stack frame in
        # ffmpeg's ffv1 encoder, deep recursion). Bake glibc-parity 8 MB as the
        # default: address-space only (lazily paged, no RAM cost), invisible to
        # thread-free packages. Link-only: a guard strips it from compile-only
        # calls (-c/-S/-E/-M) so a -Werror configure probe doesn't read clang's
        # -Wunused-command-line-argument as "flag unsupported".
        mkUnpinStdenv =
          { pkgs, toolchain ? unpinToolchain pkgs.stdenv.buildPlatform.system
          , target, lto ? "full", optClass ? "-O2"
          , native ? false, cxx ? false, stackSize ? "8388608" }:
          let
            sysroot = unpinSysroot { inherit pkgs toolchain; triple = target; inherit optClass native cxx; };
            ltoFlag =
              if lto == "thin" then "-flto=thin"
              else if lto == "full" || lto == true then "-flto"
              else "";
            stackFlag =
              if stackSize == null || stackSize == false then ""
              else "-Wl,-z,stack-size=${toString stackSize}";
            mkCC = name: face: pkgs.writeShellScript name ''
              ldextra=${nixpkgs.lib.escapeShellArg stackFlag}
              for a in "$@"; do case "$a" in -c|-S|-E|-M|-MM) ldextra=""; break;; esac; done
              exec ${toolchain}/bin/llvm ${face} -target ${target} "$@" ${optClass} ${ltoFlag} $ldextra
            '';
            ccW = mkCC "unpin-cc" "clang";
            cxxW = mkCC "unpin-cxx" "clang++";
            unpinCC = pkgs.runCommand "unpin-cc-${target}" { } ''
              mkdir -p $out/bin $out/nix-support
              ln -s ${ccW}  $out/bin/cc
              ln -s ${ccW}  $out/bin/clang
              ln -s ${cxxW} $out/bin/c++
              ln -s ${cxxW} $out/bin/clang++
              for f in llvm-ar llvm-ranlib llvm-nm llvm-objcopy llvm-strip ld.lld; do
                ln -s ${toolchain}/bin/llvm $out/bin/$f
              done
              ln -s llvm-ar      $out/bin/ar
              ln -s llvm-ranlib  $out/bin/ranlib
              ln -s llvm-nm      $out/bin/nm
              ln -s llvm-strip   $out/bin/strip
              ln -s llvm-objcopy $out/bin/objcopy
              cat > $out/nix-support/setup-hook <<EOF
              export CC=$out/bin/cc
              export CXX=$out/bin/c++
              export AR=$out/bin/llvm-ar
              export RANLIB=$out/bin/llvm-ranlib
              export NM=$out/bin/llvm-nm
              export STRIP=$out/bin/llvm-strip
              export LD=$out/bin/ld.lld
              export XDG_CACHE_HOME=${sysroot}/cache
              EOF
            '';
          in
          {
            inherit sysroot unpinCC;
            cc = unpinCC;
            mkDerivation = args: pkgs.stdenvNoCC.mkDerivation (args // {
              nativeBuildInputs = (args.nativeBuildInputs or [ ]) ++ [ unpinCC ];
              dontStrip = args.dontStrip or true;
              dontPatchELF = args.dontPatchELF or true;
            });
          };

        # unpinAdapterStdenv (route B: a drop-in nixpkgs stdenv over unpin-llvm).
        # Wraps the same `llvm` toolchain in a real nixpkgs cc-wrapper so an
        # UNMODIFIED nixpkgs recipe builds through it:
        # `pkgs.pkgsStatic.<name>.override { stdenv = unpinAdapterStdenv {...}; }`.
        # Modelled on cosmocc.nix's stdenv wiring.
        #
        # Three things make it work:
        #  1. passthru.isGNU = true (NOT isClang) + libc = null on the unwrapped
        #     cc — otherwise the clang wrapper injects `--gcc-toolchain=` + gcc
        #     -B/-L, poisoning clang's self-contained VFS sysroot. unpin-llvm
        #     brings its own compiler-rt/libc++/musl. Same trick cosmocc uses.
        #  2. The shims append ${optClass} after "$@" (route-A parity) so every
        #     invocation hits the SAME on-demand sysroot variant the seed warms.
        #  3. A writable, build-local XDG_CACHE_HOME seeded from the RO sysroot.
        #     unpin-llvm's sysroot is keyed by a per-flag variant hash; a generic
        #     recipe uses flag combos the bake didn't cover, and writing into the
        #     RO store path fails → link silently falls back to a broken dynamic
        #     musl. The copy lets new variants build on demand.
        #
        # lto: the cc/c++ shims append `-flto` so every object is LLVM BITCODE,
        # the prerequisite for the bitcode-LTO module emitter
        # (multicallModuleHookLTO). Off by default (the normal path is -O2 ELF,
        # which the objcopy-based multicallModuleHook needs). The cpp (-E) shim
        # omits it (clang warns "argument unused" under -E, which a -Werror probe
        # reads as unsupported). Bitcode app objs + ELF musl libc.a is the
        # standard LTO-app/non-LTO-libc case.
        unpinAdapterStdenv =
          { pkgs, toolchain ? unpinToolchain pkgs.stdenv.buildPlatform.system
          , target, optClass ? "-O2", cxx ? true, native ? false, lto ? false
          , captureLinks ? false
          # The host package set the adapter wraps: its `.stdenv` is the base we
          # overrideCC, and its `.buildPackages` builds the cc/bintools wrapper as
          # a genuine cross. Defaults to `pkgs.pkgsStatic` — the musl-static host
          # set, correct for every Linux target. WINDOWS overrides it to the mingw
          # cross set (`pkgs.pkgsCross.mingwW64`): pkgsStatic remaps mingw's host
          # config to the `…-windows-gnu` spelling, which clang accepts but autotools
          # `config.sub` REJECTS (`Kernel 'windows' not known to work with OS 'gnu'`);
          # the plain mingw cross set keeps the `…-w64-mingw32` config that config.sub
          # understands (static-ness comes later from mingwStaticCross's
          # makeStaticLibraries, not from pkgsStatic).
          , hostPkgs ? pkgs.pkgsStatic }:
          let
            sysroot = unpinSysroot { inherit pkgs toolchain; triple = target; inherit optClass native cxx; };
            ltoArg = if lto then " -flto" else "";
            # musl folds libm (and pthread/rt/dl/…) into libc — there is no separate
            # libm.a. CMake's `find_library(m)` (e.g. libtiff's FindCMath) doesn't
            # know that: finding no musl libm, it falls through to the build host's
            # glibc `libm.so` and hardcodes that absolute path onto the link line.
            # In the static-musl output those glibc-versioned math symbols (floor@
            # GLIBC_2.2.5, pow@GLIBC_2.29, …) can't resolve, stay at address 0, and
            # the first floor()/pow() call jumps to NULL → SIGSEGV at runtime (not a
            # link error — the symbols are UND in a PIE with no interp). An empty
            # libm.a (exactly what musl ships) on CMAKE_LIBRARY_PATH is found first,
            # so find_library(m) resolves to it and the real math comes from libc.
            # Linux-musl only: darwin has libm in libSystem, mingw ships a real libm.
            # An empty `ar` archive is just the 8-byte global header — write it
            # directly rather than shelling out to `ar`. Under a cross set
            # `buildPackages.binutils` is the target-prefixed wrapper (its bin/ has
            # `<triple>-ar`, no bare `ar`), so `bin/ar` is exit-127 on every cross
            # target; the literal header needs no binutils and is byte-identical to
            # what `ar rcs` emits for a memberless archive.
            muslLibmStub = pkgs.runCommand "unpin-musl-libm-stub" { } ''
              mkdir -p $out/lib
              printf '!<arch>\n' > $out/lib/libm.a
            '';
            # Windows: force fortify off. The engine's mingw CRT has none of the
            # `__*_chk` shims, so any known-size memcpy/strcpy fails to link. `-U`
            # doesn't work (gnulib's config.h `#if !defined _FORTIFY_SOURCE`
            # re-enables it); `-D_FORTIFY_SOURCE=0` (appended after "$@", wins over
            # the wrapper's `=2`) leaves it DEFINED so gnulib's guard stays false.
            # Empty on Linux.
            winFortifyOff = nixpkgs.lib.optionalString isWinTarget " -D_FORTIFY_SOURCE=0";
            # darwin: feed the packaged macOS SDK via SDKROOT (the engine clang
            # honours it as `-isysroot`, then links the SDK's libSystem +
            # Frameworks). BUILD-time dep, cached; shipped binaries stay 0-ref
            # since libSystem/frameworks are system paths. DEVELOPER_DIR cleared
            # so the engine never shells out to xcrun. Empty on non-darwin.
            darwinEnvSetup = nixpkgs.lib.optionalString isDarwinTarget
              "export SDKROOT=${pkgs.apple-sdk.sdkroot}; unset DEVELOPER_DIR; ";
            # Records each executable link to a per-output sidecar (objs + .a,
            # split local vs /nix/store) — the source the multicall hook reads
            # back for a program's objs/internalArchives. Inputs resolved to
            # absolute paths so the sidecar stays valid in the later postBuild.
            captureScript = ''
              #!/bin/sh
              [ -n "''${UNPIN_LINK_DIR:-}" ] || exit 0
              mkdir -p "$UNPIN_LINK_DIR" 2>/dev/null || exit 0
              out=""; link=1; prev=""
              for a in "$@"; do
                case "$prev" in -o) out="$a" ;; esac
                case "$a" in
                  -c|-E|-S|-shared|-r|--relocatable|-i) link=0 ;;
                esac
                prev="$a"
              done
              [ "$link" = 1 ] || exit 0
              [ -n "$out" ] || exit 0
              case "$out" in *.o|*.lo|*.so|*.so.*|*.os) exit 0 ;; esac
              nobj=0; objs=""; locala=""; storea=""; ldirs=""; lnames=""; prev=""
              for a in "$@"; do
                # separated forms: -L <dir>, -l <name>
                case "$prev" in
                  -L) ldirs="$ldirs $a" ;;
                  -l) lnames="$lnames $a" ;;
                esac
                case "$a" in
                  -L?*) ldirs="$ldirs ''${a#-L}" ;;
                  -l?*) lnames="$lnames ''${a#-l}" ;;
                  *.o|*.lo)
                    case "$a" in /*) p="$a" ;; *) p="$(pwd)/$a" ;; esac
                    nobj=$((nobj+1)); objs="$objs$p
              " ;;
                  *.a)
                    case "$a" in /*) p="$a" ;; *) p="$(pwd)/$a" ;; esac
                    case "$p" in
                      /nix/store/*) storea="$storea$p
              " ;;
                      *) locala="$locala$p
              " ;;
                    esac ;;
                esac
                prev="$a"
              done
              # Resolve `-L<dir> -l<name>` to a static lib<name>.a (autotools
              # packages — bash — pass their bundled internal libs this way, not
              # as positional `.a`). First match per name, ld search order;
              # build-tree dir => LOCALA (fold into the module), /nix/store =>
              # STOREA. Names with no `.a` in any -L dir (libc/-ldl/-lm) resolve
              # to a shared lib or the sysroot and are correctly skipped.
              set -f
              for nm in $lnames; do
                for d in $ldirs; do
                  cand="$d/lib$nm.a"
                  [ -f "$cand" ] || continue
                  case "$cand" in /*) p="$cand" ;; *) p="$(pwd)/$cand" ;; esac
                  case "$p" in
                    /nix/store/*) storea="$storea$p
              " ;;
                    *) locala="$locala$p
              " ;;
                  esac
                  break
                done
              done
              set +f
              [ "$nobj" -ge 1 ] || exit 0
              # Sidecar is keyed by program name (grep, sed, …); a windows link
              # outputs `<prog>.exe`, so strip `.exe` to keep the name the hook's
              # inferLinkInputs lookup expects (`<prog>.link`, not `<prog>.exe.link`).
              b="$(basename "$out")"; b="''${b%.exe}"
              {
                echo "CWD $(pwd)"
                printf '%s' "$objs"   | while IFS= read -r x; do [ -n "$x" ] && echo "OBJ $x"; done
                printf '%s' "$locala" | while IFS= read -r x; do [ -n "$x" ] && echo "LOCALA $x"; done
                printf '%s' "$storea" | while IFS= read -r x; do [ -n "$x" ] && echo "STOREA $x"; done
              } > "$UNPIN_LINK_DIR/$b.link"
              exit 0
            '';
            captureCall = nixpkgs.lib.optionalString captureLinks
              "[ -n \"\\$UNPIN_CAPTURE_LINKS\" ] && \"$out/libexec/unpin-capture\" \"\\$@\"";
            ccUnwrapped = pkgs.runCommand "unpin-cc-unwrapped-${target}"
              { passthru = { isGNU = true; version = "21.1.8"; };
                inherit captureScript; } ''
              mkdir -p $out/bin $out/libexec
              printf '%s' "$captureScript" > $out/libexec/unpin-capture
              chmod +x $out/libexec/unpin-capture
              # The generated wrapper rewrites argv in two spots before exec'ing the
              # toolchain (kept comment-free so it stays a lean hot path; rationale
              # here):
              #   * Link-step \`-v\` drop: the front treats a bare \`-v\` as a pure
              #     query and skips sysroot injection, so CMake's ABI-detection link
              #     (which passes \`-v\`) fails and CMAKE_SIZEOF_VOID_P comes back empty.
              #   * conftest \`-flto\`/\`-pg\` drop: autoconf probes must see honest
              #     results. Forced -flto defers codegen and changes what links (a -pg
              #     probe LTO-emits an unresolvable \`mcount\`, posix_spawn mis-detects);
              #     -pg also leaks into shared CFLAGS that later header-presence probes
              #     reuse, where a static-musl -pg link fails on \`mcount\` → those
              #     probes wrongly conclude headers are absent.
              #
              # \`-D__STDC_ISO_10646__\`: gcc predefines this on every Linux target
              # (wchar_t holds Unicode), clang predefines it on NONE. Code that hard-
              # checks it (\`#error wchar_t must store ISO 10646 characters\` in
              # libedit's chartype.h) built fine when deps were gcc, but the engine is
              # clang — so the all-deps path now miscompiles it. Every unpin target is
              # Linux/musl with 32-bit UCS-4 wchar_t, so the macro is true; define it
              # to gcc's value to keep the engine a drop-in for gcc-built sources.
              mk() {
                cat > "$out/bin/$1" <<EOF
              #!/bin/sh
              ${captureCall}
              __ln=1
              for __a in "\$@"; do case "\$__a" in -c|-S|-E) __ln=0;; esac; done
              if [ "\$__ln" = 1 ]; then
                __n=\$#
                while [ \$__n -gt 0 ]; do
                  __a=\$1; shift; __n=\$((__n-1))
                  [ "\$__a" = "-v" ] && continue
                  set -- "\$@" "\$__a"
                done
              fi
              __lto="${ltoArg}"
              __isconf=0
              for __a in "\$@"; do case "\$__a" in *conftest*) __isconf=1;; esac; done
              if [ "\$__isconf" = 1 ]; then
                __lto=""
                __n=\$#
                while [ \$__n -gt 0 ]; do
                  __a=\$1; shift; __n=\$((__n-1))
                  [ "\$__a" = "-pg" ] && continue
                  set -- "\$@" "\$__a"
                done
              fi
              ${darwinEnvSetup}exec ${toolchain}/bin/llvm $2 -target ${target} -D__STDC_ISO_10646__=201706L${darwinStubFlag} "\$@" ${optClass}${winFortifyOff}\$__lto
              EOF
                chmod +x "$out/bin/$1"
              }
              mk clang clang ; mk cc clang ; mk gcc clang
              mk clang++ clang++ ; mk c++ clang++ ; mk g++ clang++
              cat > $out/bin/cpp <<EOF
              #!/bin/sh
              ${darwinEnvSetup}exec ${toolchain}/bin/llvm clang -E -target ${target} -D__STDC_ISO_10646__=201706L${darwinStubFlag} "\$@"
              EOF
              chmod +x $out/bin/cpp
            '';
            # Target-PREFIXED tool names (`${target}-ar`, …): nixpkgs' cross
            # bintools-wrapper sources tools as `$ldPath/${targetPrefix}ar`, so a
            # genuine cross only finds them when prefixed (unprefixed left RANLIB
            # empty). The cc-wrapper sources unprefixed `clang`, so `ccUnwrapped`
            # stays unprefixed.
            # isGNU=true keeps the isGNU-gated wrapper behaviour the engine relies
            # on (the gnu-binutils-strip wrapper; no darwin ZERO_AR_DATE). isLLVM=true
            # is ALSO truthful — every tool here is an LLVM drop-in (ld.lld, llvm-ar,
            # llvm-windres, …) — and it is what nixpkgs recipes read to apply their
            # LLVM-appropriate handling: without it a recipe like freetype skips its
            # own `RC=""` guard (`!isWindows && bintools.isLLVM`) and then compiles a
            # Windows .rc via the exposed llvm-windres on a Linux target, which fails.
            # Passthru-only (stripped before the build) so the wrapper store path is
            # unchanged; the version-gated isLLVM branches (ncurses/binutils/… need
            # version≥17) stay off since no bintools version is set → byte-neutral for
            # the catalog, only freetype's version-less guard flips.
            bintoolsUnwrapped = pkgs.runCommand "unpin-bintools-unwrapped-${target}"
              { passthru = { isGNU = true; isLLVM = true; targetPrefix = "${target}-"; }; } ''
              mkdir -p $out/bin
              mkt() {
                cat > "$out/bin/${target}-$1" <<EOF
              #!/bin/sh
              exec ${toolchain}/bin/llvm $2 "\$@"
              EOF
                chmod +x "$out/bin/${target}-$1"
              }
              mkt ar llvm-ar ; mkt ranlib llvm-ranlib ; mkt nm llvm-nm
              mkt strip llvm-strip ; mkt objcopy llvm-objcopy ; mkt objdump llvm-objdump
              mkt ld ld.lld ; mkt ld.lld ld.lld
              # windres: the Windows resource compiler (.rc → .res COFF). mingw
              # autotools packages (libiconv, …) compile a version-info resource via
              # libtool's `--tag=RC`, which needs `${target}-windres`. llvm-windres
              # is a GNU-windres drop-in already in the multicall driver. Inert for
              # non-windows targets (never invoked), so added unconditionally.
              mkt windres llvm-windres
              ${nixpkgs.lib.optionalString isDarwinTarget ''
                # darwin Mach-O bintools. The darwin stdenv's fixup phase post-
                # processes every .dylib/Mach-O it installs — `install_name_tool`
                # rewrites LC_ID_DYLIB/LC_LOAD_DYLIB install names (libiconv ships a
                # versioned dylib), `lipo` handles fat slices, `otool` inspects load
                # commands, `dsymutil` debug bundles. The cross bintools-wrapper
                # sources them as `${target}-install_name_tool` etc. The unpin-llvm
                # multicall already carries the LLVM drop-ins (`install-name-tool`,
                # `lipo`, `otool`, `dsymutil`) — map them under the names the wrapper
                # and `fixupPhase` expect. Darwin-gated so non-darwin bintools stay
                # byte-identical to the validated linux/windows sets.
                mkt install_name_tool install-name-tool ; mkt install-name-tool install-name-tool
                mkt lipo lipo ; mkt otool otool ; mkt dsymutil dsymutil
              ''}
            '';
            # Wrap from `pkgsStatic.buildPackages`, not `pkgsStatic` directly:
            # build the cc/bintools wrapper the way nixpkgs builds it for ANY
            # cross stdenv. The wrapper is a build-platform derivation, but a
            # spliced package coerces to its hostTarget, so `pkgsStatic.wrapCCWith`
            # defaults every helper (coreutils, gnugrep, expand-response-params) to
            # the static TARGET build — FOREIGN binaries on a real cross →
            # `Exec format error` (the grep/sed/coreutils CI failures, masked
            # locally by qemu). `pkgsStatic.buildPackages.wrap…With` resolves every
            # helper to the build platform via callPackage's splice — no per-tool
            # list, no qemu. The salt still comes from `targetPlatform.config` (the
            # musl host, so bash's `--host=…-musl` lookup resolves) and the wrapper
            # runs genuine cross mode, sourcing PREFIXED bintools — hence
            # `bintoolsUnwrapped`'s `${target}-` names.
            staticBuild = hostPkgs.buildPackages;
            # A genuine-cross wrapper names tools `${target}-…` only. Our single
            # LLVM driver is target-agnostic and consumers expect bare names too
            # (stray Makefiles call bare `gcc`/`ar`), so re-add an unprefixed alias
            # for each `${target}-` tool — without disturbing the helper splice.
            unprefixAliases = ''
              for f in "$out"/bin/${target}-*; do
                [ -e "$f" ] || continue
                b=''${f##*/}; u=''${b#${target}-}
                [ -e "$out/bin/$u" ] || ln -s "$b" "$out/bin/$u"
              done
            '';
            # Windows: the engine resolves default CRT import libs from its VFS,
            # but EXTRA `-l<dll>` libs (bcrypt, ws2_32) are synthesized in-memory
            # from VFS .def files and that synthesis FAILS in the build sandbox
            # ("unable to find library"). nixpkgs' mingw-w64 ships them as real
            # ABI-neutral import stubs; curate ONLY the extras into a link-path dir
            # — NOT kernel32/CRT, so the engine's startup objects aren't shadowed.
            isWinTarget =
              nixpkgs.lib.hasInfix "windows" target || nixpkgs.lib.hasInfix "mingw" target;
            # darwin (Mach-O) target: arm64/x86_64-apple-darwin / -macos.
            isDarwinTarget =
              nixpkgs.lib.hasInfix "darwin" target || nixpkgs.lib.hasInfix "macos" target;
            # `apple-sdk = null` stops callPackage auto-filling the wrapper's
            # `apple-sdk` param (which re-injects Csu/crt + ld64 + cctools and
            # re-issues -isysroot/-syslibroot, fighting the engine's crt-less
            # Mach-O link); the engine gets the SDK via SDKROOT instead. Inert off
            # darwin. See docs/platforms/darwin.md.
            appleSdkOverride = nixpkgs.lib.optionalAttrs isDarwinTarget { apple-sdk = null; };
            # Legacy darwin headers the SDK no longer ships but gnulib + ncurses
            # still `#include` on __APPLE__: `<libc.h>` (gnulib's stackvma-mach.c,
            # via the c-stack module, needs only getpagesize), `<nlist.h>` (the
            # real struct lives in <mach-o/nlist.h>) and `<sys/ttydev.h>` (ncurses
            # lib_baudrate.c). Inject as thin `-idirafter` shims (last in search
            # order, so the real SDK header wins and these never shadow). Kept off
            # the ncurses recipe so the fix never re-hashes apple-sdk. Empty off
            # darwin.
            darwinHeaderStubs = pkgs.runCommand "unpin-darwin-hdr-stubs" { } ''
              mkdir -p $out/include/sys
              printf '#ifndef _UNPIN_LIBC_H\n#define _UNPIN_LIBC_H\n#include <unistd.h>\n#include <stdlib.h>\n#endif\n' > $out/include/libc.h
              printf '#ifndef _UNPIN_NLIST_H\n#define _UNPIN_NLIST_H\n#include <mach-o/nlist.h>\n#endif\n' > $out/include/nlist.h
              cp ${./darwin-ttydev.h} $out/include/sys/ttydev.h
            '';
            darwinStubFlag =
              nixpkgs.lib.optionalString isDarwinTarget " -idirafter ${darwinHeaderStubs}/include";
            # (No `-lm`/`-lpthread` stub libs: the engine adds `-L <sdk>/usr/lib`
            # at link, where the SDK's libm.tbd/libpthread.tbd resolve them.)
            winImportLibs = pkgs.runCommand "unpin-win-implibs-${target}" { } ''
              mkdir -p $out/lib
              for L in bcrypt ws2_32 userenv secur32 crypt32 shlwapi; do
                ln -s ${pkgs.windows.mingw_w64}/lib/lib$L.a $out/lib/
              done
            '';
            ccExtraBuildCommands = unprefixAliases
              + nixpkgs.lib.optionalString isWinTarget ''
                # `gcc`/`g++` aliases (bare + target-PREFIXED). Some deps build
                # through a bespoke, non-autotools Makefile that hardcodes the
                # gnu compiler by name — e.g. zlib's `win32/Makefile.gcc` invokes
                # `''${PREFIX}gcc` (= `x86_64-w64-mingw32-gcc`) literally, never
                # `$CC`. The cc-wrapper only exposes `cc`/`clang` (it adds no
                # `gcc` alias because the unwrapped clang isn't isGNU), and the
                # genuine-cross wrapper names it unprefixed. The prefixed BINTOOLS
                # (`${target}-ar`/`-ranlib`) already exist (bintoolsUnwrapped);
                # add the matching `gcc`/`g++` CC aliases (point at the `clang`/
                # `clang++` wrapper scripts, which resolve) so such Makefiles find
                # the engine compiler. Windows-only — linux/cosmo are untouched.
                ln -sf clang   "$out/bin/gcc"
                ln -sf clang++ "$out/bin/g++"
                ln -sf clang   "$out/bin/${target}-gcc"
                ln -sf clang++ "$out/bin/${target}-g++"
                echo "-L${winImportLibs}/lib" >> $out/nix-support/cc-ldflags
                # Force-link the curated import stubs on EVERY windows link. They
                # are pulled on demand (an unreferenced import lib adds no code), so
                # this is a no-op for a package that needs none — but it resolves
                # symbols the mega-link can't otherwise reach: a folded module.bc
                # references e.g. BCryptGenRandom, yet the mega buildPhase adds no
                # `-l<dll>` of its own (per-package builds do, via NIX_LDFLAGS).
                # cc-ldflags land after the user objects, so static resolution works.
                # shlwapi: file's libmagic calls PathRemoveFileSpecA to derive the
                # magic dir from the exe path; the per-package link gets it from
                # file's own LIBS, but the mega-link only knows depArchives, so add
                # it here too (no-op for packages that don't reference it).
                echo "-lbcrypt -lws2_32 -luserenv -lsecur32 -lcrypt32 -lshlwapi" >> $out/nix-support/cc-ldflags
              '';
            bintools = staticBuild.wrapBintoolsWith ({
              bintools = bintoolsUnwrapped; libc = null; extraBuildCommands = unprefixAliases;
            } // appleSdkOverride);
            cc = staticBuild.wrapCCWith ({
              inherit bintools; cc = ccUnwrapped; libc = null; extraPackages = [ ];
              extraBuildCommands = ccExtraBuildCommands;
            } // appleSdkOverride);
            seedHook = pkgs.makeSetupHook
              { name = "unpin-seed-sysroot-cache"; substitutions = { sysrootCache = "${sysroot}/cache"; }; }
              (pkgs.writeText "unpin-seed-sysroot-cache.sh" ''
                unpinSeedSysrootCache() {
                  if [ -z "''${_unpinCacheSeeded:-}" ]; then
                    export XDG_CACHE_HOME="''${NIX_BUILD_TOP:-$TMPDIR}/.unpin-cache"
                    mkdir -p "$XDG_CACHE_HOME"
                    if [ -d "@sysrootCache@/unpin-llvm" ]; then
                      cp -r "@sysrootCache@/unpin-llvm" "$XDG_CACHE_HOME/" 2>/dev/null || true
                      chmod -R u+w "$XDG_CACHE_HOME"
                    fi
                    _unpinCacheSeeded=1
                  fi
                }
                preConfigureHooks+=(unpinSeedSysrootCache)
                preBuildHooks+=(unpinSeedSysrootCache)
                # Also seed NOW, at hook-source time (before any phase). runHook
                # fires the package's own `preConfigure`/`postPatch` ATTR before the
                # preConfigureHooks array, and such an attr can already compile+link
                # (e.g. x265 multibitdepth's `cmake -B build-10bits` runs a
                # CMakeTestCCompiler probe). Without XDG_CACHE_HOME seeded that early
                # the linux sysroot copy is missing (ld.lld: cannot open crt1.o /
                # -lgcc / -lc) and the darwin on-demand sysroot build falls back to
                # $HOME/.cache = /homeless-shelter and fails. The _unpinCacheSeeded
                # guard makes the later hook runs no-ops.
                unpinSeedSysrootCache
              '');
            captureHook = pkgs.makeSetupHook { name = "unpin-capture-links"; }
              (pkgs.writeText "unpin-capture-links.sh" ''
                export UNPIN_CAPTURE_LINKS=1
                export UNPIN_LINK_DIR="''${NIX_BUILD_TOP:-$TMPDIR}/.unpin-links"
              '');
          in
          # dontPatchELF: static-musl has no interp/RPATH to touch.
          # hardeningDisable=all: match route-A's minimal flag set (fortify needs
          # libc support musl only partly provides). No dontStrip — unlike
          # cosmocc's APE, static-musl ELF strips fine, so strippedOrJoined's
          # final strip applies.
          pkgs.stdenvAdapters.addAttrsToDerivation
            ({ dontPatchELF = true; hardeningDisable = [ "all" ]; }
              # See muslLibmStub: keep CMake's find_library(m) off the host glibc
              # libm.so. Linux-musl only (darwin/windows have a real libm).
              // nixpkgs.lib.optionalAttrs (!isDarwinTarget && !isWinTarget) {
                CMAKE_LIBRARY_PATH = "${muslLibmStub}/lib";
              }
              # The engine feeds the SDK via SDKROOT inside the cc wrapper (see
              # darwinEnvSetup), which covers every compile/link. But some nixpkgs
              # darwin preConfigures read SDKROOT in the BUILD SHELL before any
              # compile — e.g. compiler-rt's
              # `-DDARWIN_macosx_OVERRIDE_SDK_VERSION=$(jq .Version $SDKROOT/SDKSettings.json)`
              # — and apple-sdk (whose setup hook would export SDKROOT shell-wide) is
              # dropped from extraBuildInputs below to keep its crt hooks out of the
              # Mach-O link. So also export SDKROOT as a plain build-env var. This is
              # a bare path (no setup hook), so it re-introduces none of apple-sdk's
              # crt/-syslibroot machinery. Without it, C++ darwin engine builds fail
              # to bootstrap their libc++/compiler-rt runtime.
              // nixpkgs.lib.optionalAttrs isDarwinTarget { SDKROOT = "${pkgs.apple-sdk.sdkroot}"; })
            ((pkgs.overrideCC hostPkgs.stdenv cc).override (old: {
              extraNativeBuildInputs = (old.extraNativeBuildInputs or [ ]) ++ [ seedHook ]
                ++ nixpkgs.lib.optional captureLinks captureHook;
              # The darwin stdenv bakes `apple-sdk` into `extraBuildInputs`, so
              # every mkDerivation pulls the SDK's setup hooks (re-export SDKROOT,
              # -isysroot/-syslibroot, Csu crt) that fight the engine's crt-less
              # Mach-O link. We supply the SDK via SDKROOT instead, so drop it from
              # the default inputs on darwin. Untouched elsewhere.
              extraBuildInputs =
                if isDarwinTarget then [ ] else (old.extraBuildInputs or [ ]);
            }));

        # Append `flags` (string or list) to NIX_CFLAGS_COMPILE. structuredAttrs
        # drvs carry it inside `env`; a top-level write on top of that collides
        # ("attribute set cannot contain any attributes passed to derivation"), so
        # append wherever the existing value lives, never both.
        appendCFlags = drv: flags:
          let
            flagStr = builtins.concatStringsSep " "
              (if builtins.isList flags then flags else [ flags ]);
          in
          drv.overrideAttrs (old:
            if old ? env && old.env ? NIX_CFLAGS_COMPILE then {
              env = old.env // {
                NIX_CFLAGS_COMPILE = old.env.NIX_CFLAGS_COMPILE + " " + flagStr;
              };
            } else if old ? NIX_CFLAGS_COMPILE then {
              NIX_CFLAGS_COMPILE = old.NIX_CFLAGS_COMPILE + " " + flagStr;
            } else {
              NIX_CFLAGS_COMPILE = flagStr;
            });

        # Bash build-correctness override (`bash`/`bashInteractive`/
        # `bashNonInteractive`). Two faults: configure bakes a bare `CC=gcc` that
        # can't do the static link, and the codegen tools (mkbuiltins/mksignames)
        # hit C23 where bash-5.3's `typedef unsigned char bool` is rejected — force
        # them onto gnu17. Drv-level so it reaches whichever variant a consumer
        # pulls; idempotent via the `unpinNativeFixed` marker.
        unpinBashBuildFix = scope: drv:
          let
            host = drv.stdenv.hostPlatform;
            buildp = drv.stdenv.buildPlatform;
            cc = drv.stdenv.cc;
            buildCC = scope.buildPackages.stdenv.cc;
            isCross = buildp.system != host.system;
            # CC_FOR_BUILD runs on the builder, so never the engine target cc.
            #   cross         → the build-platform cc.
            #   native linux  → bare `gcc` by name (keeps the bash drv
            #                   byte-identical to the published build).
            #   native darwin → no gcc exists; pin the vanilla build cc (genuine
            #                   clang+cctools, not engine-swapped). Inert on linux.
            ccForBuild =
              if isCross || buildp.isDarwin then "${buildCC}/bin/cc" else "gcc";
            # On native darwin build and host share the `x86_64-apple-darwin`
            # salt, so the engine bintools (bare `ld` = ELF lld) shadows the build
            # cc's cctools ld64 (the linux salt-separation collapses) → ld64 args
            # reach ELF lld, which rejects them. Pin to unwrapped cctools ld64.
            ldPathFlag = nixpkgs.lib.optionalString buildp.isDarwin
              " --ld-path=${buildCC.bintools.bintools}/bin/ld";
          in
          # Linux or darwin host; windows excluded (the mingw bash path handles its
          # own codegen). The isMusl-gated call sites keep this inert on darwin
          # until the darwin engine set calls it (below).
          if !(host.isLinux || host.isDarwin) || (drv.unpinNativeFixed or false) then drv
          else drv.overrideAttrs (old: {
            passthru = (old.passthru or { }) // { unpinNativeFixed = true; };
            preConfigure = (old.preConfigure or "") + ''
              export CC=${cc}/bin/cc
              export CXX=${cc}/bin/c++
            '';
            makeFlags = (old.makeFlags or [ ]) ++ [ "CC=${cc}/bin/cc" ];
            # CC_FOR_BUILD has a space → can't ride in word-split `makeFlags`; the
            # `makeFlagsArray` bash array keeps it intact.
            preBuild = (old.preBuild or "") + ''
              makeFlagsArray+=( "CC_FOR_BUILD=${ccForBuild} -std=gnu17${ldPathFlag}" )
            '';
          });

        # Which targets use lld, the unpins-standard linker. lldStdOpts is the
        # flag set (`-fuse-ld=lld --gc-sections --icf=safe`); `--icf=all` is NOT
        # used (breaks function/data-pointer identity, risks codec-table
        # miscompiles). Only valid on a FULL link, never `ld -r` (--gc-sections/
        # --icf error there) — hence it lives on the multicall post-link.
        # Excludes:
        #   * darwin → clang + Apple ld64; allowlist/codesign is link-sensitive.
        #   * cosmo (isWindows && !isMinGW) → cosmocc, its own toolchain.
        #   * riscv64 → lld emits "relocation refers to a symbol in a discarded
        #     section" (RISC-V relaxation × section-discard) even without
        #     --gc-sections/--icf; GNU ld doesn't.
        #   * ppc64le → lld doesn't synthesize the PowerPC out-of-line FP
        #     save/restore routines (libgcc crtsavres) GNU ld generates on
        #     demand, so any FP-heavy static link fails with undefined _restfpr_N.
        # Both crosses are size-neutral (the gc win is Linux-native only).
        isLLDTarget = pkgs:
          let h = pkgs.stdenv.hostPlatform;
          in !(h.isDarwin)
          && !(h.isWindows && !(h.isMinGW or false))
          && !(h.isRiscV or false)
          && !(h.isPower or false)
          # m68k: ld.lld has no m68k backend ("unknown emulation: m68kelf").
          && !(h.isM68k or false)
          # mips/s390x (tier-3 `.#cross`): lld support absent or incomplete,
          # route through ld.bfd (always shipped, still does --gc-sections).
          && !(h.isMips or false)
          && !(h.isS390 or false);

        # `ld.lld` aborts on a relocatable (`-r`) link carrying `--icf`
        # ("-r and --icf may not be used together"), but lldStdOpts' `--icf=safe`
        # reaches every $CC link including the `$CC -r` partial-links some builds
        # emit (busybox kbuild). `--gc-sections` is -r-safe; only `--icf` is fatal.
        # So wrap ld.lld to strip `--icf*` on -r/-i links. The wrapper dir
        # symlinks the rest of lld/bin so it's a drop-in for `-B<dir>`/PATH.
        # `buildPkgs` must be the recursion-safe build-platform scope (see
        # withLLDLink).
        lldRSafe = buildPkgs:
          buildPkgs.runCommand "lld-rsafe-${buildPkgs.lld.version}" { } ''
            mkdir -p $out/bin
            for f in ${buildPkgs.lld}/bin/*; do
              ln -s "$f" "$out/bin/$(basename "$f")"
            done
            rm -f $out/bin/ld.lld
            cat > $out/bin/ld.lld <<'WRAP'
            #!${buildPkgs.bash}/bin/bash
            reloc=0
            for a in "$@"; do
              case "$a" in -r|--relocatable|-i) reloc=1 ;; esac
            done
            if [ "$reloc" = 1 ]; then
              # Strip flags that are illegal or wrong on a relocatable (`-r`)
              # partial link: --icf ("-r and --icf may not be used together"),
              # and --wrap (the DNS-fallback wrap must apply only at the FINAL
              # full link — applying it on a kbuild partial-link too would
              # double-rewrite getaddrinfo refs). `--wrap SYM` (two-token) and
              # `--wrap=SYM` (one-token) both handled.
              args=()
              skip=0
              for a in "$@"; do
                if [ "$skip" = 1 ]; then skip=0; continue; fi
                case "$a" in
                  --icf|--icf=*) ;;
                  --wrap=*) ;;
                  --wrap) skip=1 ;;
                  *) args+=("$a") ;;
                esac
              done
              exec ${buildPkgs.lld}/bin/ld.lld "''${args[@]}"
            fi
            exec ${buildPkgs.lld}/bin/ld.lld "$@"
            WRAP
            chmod +x $out/bin/ld.lld
          '';

        # The unpins-standard lld options for a non-darwin final link.
        lldStdOpts = _: "-fuse-ld=lld -Wl,--gc-sections -Wl,--icf=safe";
        # `-B<lld>/bin` makes the driver find `ld.lld` for `-fuse-ld=lld` without
        # lld on PATH, so appending `${lib.gcSectionsFlag pkgs}` to a post-link is
        # self-sufficient (no per-package nativeBuildInputs edit). lld/bin ships no
        # `ld`/`as`/`ar`, so -B can't shadow the build's binutils.
        gcSectionsFlag = pkgs:
          if isLLDTarget pkgs then
            "-B${lldRSafe pkgs.buildPackages}/bin ${lldStdOpts pkgs}"
          else "";

        # `lld` build tool for the scope. Only needed where a link uses
        # `-fuse-ld=lld` WITHOUT going through gcSectionsFlag's `-B` (e.g. the
        # gc-overlay single-binary makeFlagsArray). Empty off the lld targets.
        lldFinalLink = pkgs:
          if isLLDTarget pkgs then [ (lldRSafe pkgs.buildPackages) ]
          else [ ];

        # nixos-26.05 meson (glib 2.88, pango 1.57, harfbuzz, gdk-pixbuf, …)
        # evaluates `subsystem = host_machine.subsystem()` on darwin; in CROSS
        # mode meson can't autodetect it and aborts
        #   ERROR: Subsystem not defined or could not be autodetected
        # and nixpkgs' generated cross-file (build-support/lib/meson.nix
        # [host_machine]) omits `subsystem`. When a cross-file is already in play
        # (a real cross — guard so we never force cross mode onto a native build)
        # this appends a supplemental cross-file re-emitting the COMPLETE
        # [host_machine] + subsystem='macos' (meson REPLACES [host_machine]
        # across files — a partial one drops system/cpu/endian → "Machine info
        # is currently {'subsystem'…}").
        #
        # ATTACH PER-PACKAGE, never by overriding the global `meson`. gnutar's
        # checkPhase closure transitively pulls `meson`, so ANY change to the
        # `meson` derivation (even its propagatedBuildInputs) re-hashes the whole
        # darwin stdenv closure — gnutar included — forcing a from-source rebuild
        # on the GHA macos-14 runner where gnutar test 155 (time01 "tricky time
        # stamps") fails, cascading to EVERY darwin build. So the setup-hook
        # rides the CONSUMING package's own nativeBuildInputs; the cached
        # stdenv/gnutar stay untouched. The per-package objc nativeFixes
        # (glib/pango/cairo) already carry their own complete [host_machine]
        # section; apply this to any other meson package that needs it.
        withDarwinMesonSubsystem = pkgs: drv:
          let
            bp = pkgs.buildPackages;
            hp = pkgs.stdenv.hostPlatform;
            cpuFamily = if hp.isAarch64 then "aarch64" else "x86_64";
            hook = bp.makeSetupHook { name = "meson-darwin-subsystem-hook"; }
              (bp.writeText "meson-darwin-subsystem-hook.sh" ''
                _unpinsMesonDarwinSubsystem() {
                  case " ''${mesonFlags:-} ''${mesonFlagsArray[*]:-} " in
                    *--cross-file*) ;;
                    *) return 0 ;;
                  esac
                  cat > "$NIX_BUILD_TOP/unpins-darwin-subsystem.ini" <<EOF
                [host_machine]
                system = 'darwin'
                cpu_family = '${cpuFamily}'
                cpu = '${hp.parsed.cpu.name}'
                endian = 'little'
                subsystem = 'macos'
                EOF
                  mesonFlagsArray+=("--cross-file=$NIX_BUILD_TOP/unpins-darwin-subsystem.ini")
                }
                preConfigureHooks+=(_unpinsMesonDarwinSubsystem)
              '');
          in
          drv.overrideAttrs (o: {
            nativeBuildInputs = (o.nativeBuildInputs or [ ]) ++ [ hook ];
          });

        # armv7l (aarch32) engine cross: nothing sets CC_FOR_BUILD, so meson
        # auto-detects the engine's unprefixed `cc` (an arm-TARGETING clang) as
        # the BUILD-machine compiler too (CI log: "C compiler for the build
        # machine: cc (clang 21.1.8)" + "Build machine cpu family: arm"). meson's
        # cross-sizeof shortcut `_cross_compute_int` then COMPILES a probe with
        # that build compiler and RUNS it (clike.py:469) — an armv7l binary. On
        # the aarch64 CI runner there is no arm binfmt, so run() raises
        # CrossNoRunException "Can not run test applications" (compilers.py:690;
        # NOT an EnvironmentException, so clike.py's `except` does not swallow it)
        # → configure dies. glib's `cc.sizeof('char')` is the first to hit it, so
        # EVERY engine meson package on armv7l is affected. It only "passes"
        # locally because this x86_64 box has qemu-arm binfmt with the fix-binary
        # (F) flag that leaks into the sandbox — the in-build qemu we forbid.
        #
        # Fix: export CC_FOR_BUILD/CXX_FOR_BUILD = the REAL builder's native
        # compiler (pkgsBuildBuild.stdenv.cc — aarch64 gcc in CI, x86_64 gcc under
        # the local helper). meson reads *_FOR_BUILD for the build-machine
        # compiler (environment.py:65), so the probe is compiled AND run with a
        # builder-native compiler → runs natively, never qemu; it also makes meson
        # detect the build cpu as the builder's, so need_exe_wrapper(BUILD) is
        # False. Only armv7l trips this — it is the sole cross built on a
        # foreign-arch (aarch64) runner; the x86_64-hosted crosses (i686/ppc64le/
        # riscv64) already keep a builder-native build compiler.
        #
        # Attach per-package via nativeBuildInputs — NEVER touch the global meson
        # drv (re-hashes the world, see withDarwinMesonSubsystem above). Gated to
        # aarch32 cross by its enginePkgsStatic call site → strict no-op
        # (byte-identical) on every other arch and non-meson package.
        withMesonBuildCC = pkgs: drv:
          let
            bp = pkgs.buildPackages;
            buildCC = pkgs.pkgsBuildBuild.stdenv.cc;
            hook = bp.makeSetupHook { name = "meson-buildcc-hook"; }
              (bp.writeText "meson-buildcc-hook.sh" ''
                _unpinsMesonBuildCC() {
                  export CC_FOR_BUILD=${buildCC}/bin/cc
                  export CXX_FOR_BUILD=${buildCC}/bin/c++
                }
                preConfigureHooks+=(_unpinsMesonBuildCC)
              '');
          in
          drv.overrideAttrs (o: {
            nativeBuildInputs = (o.nativeBuildInputs or [ ]) ++ [ hook ];
          });

        # Append to NIX_CFLAGS_LINK (cc-wrapper LINK-time flags),
        # structuredAttrs-aware like appendCFlags. Unlike NIX_LDFLAGS this reaches
        # ONLY $CC-driven links, never a direct `ld -r`, so --gc-sections/--icf
        # are safe here. The `old ? env && old.env ? VAR` test (NOT
        # `old.__structuredAttrs`, invisible in overrideAttrs' `old`) routes the
        # append into `env` when a structuredAttrs build presets it there (a
        # top-level dup would be rejected); a top-level scalar exports fine when
        # the var is absent.
        appendLinkFlags = drv: flagStr:
          drv.overrideAttrs (old:
            if old ? env && old.env ? NIX_CFLAGS_LINK then {
              env = old.env // { NIX_CFLAGS_LINK = old.env.NIX_CFLAGS_LINK + " " + flagStr; };
            } else if old ? NIX_CFLAGS_LINK then {
              NIX_CFLAGS_LINK = old.NIX_CFLAGS_LINK + " " + flagStr;
            } else { NIX_CFLAGS_LINK = flagStr; });

        # Append raw `ld` flags to NIX_LDFLAGS, structuredAttrs-aware. Unlike
        # NIX_CFLAGS_LINK this survives a build that wipes NIX_CFLAGS_LINK in
        # postConfigure (nixpkgs' whois drops the bootstrap `-static` that way),
        # and it's the mechanism fastfetch already uses for its `--wrap=dlopen`.
        # Entries are passed straight to ld, so use `--wrap=…` (not `-Wl,…`).
        appendLdFlags = drv: flagStr:
          drv.overrideAttrs (old:
            if old ? env && old.env ? NIX_LDFLAGS then {
              env = old.env // { NIX_LDFLAGS = old.env.NIX_LDFLAGS + " " + flagStr; };
            } else if old ? NIX_LDFLAGS then {
              NIX_LDFLAGS = old.NIX_LDFLAGS + " " + flagStr;
            } else { NIX_LDFLAGS = flagStr; });

        # DNS fallback (linux-static). A tiny C archive providing
        # __wrap_getaddrinfo / __wrap_freeaddrinfo. musl's resolver can't reach
        # DNS where /etc/resolv.conf is absent (Android: DNS lives behind Bionic +
        # netd), so catalog binaries fail to resolve. The wrapper delegates to the
        # real resolver normally and only takes over on EAI_AGAIN AND when the
        # user opted in (via $UNPIN_DNS or a `dns =` line the shim reads itself).
        # OFF by default: with nothing configured it surfaces the real error and
        # calls a weak hook unpin overrides to teach opt-in. Can escalate to DoH
        # via an OPTIONAL weak hook (unpin_readurl) a TLS-carrying binary provides
        # (the Rust tools do, over rustls); unprovided it stays UDP-only at zero
        # cost. See dns-fallback/dns-fallback.c for the contract.
        #
        # Built with the TARGET stdenv (per arch/OS); three link mechanisms via
        # #ifdef: musl/mingw `--wrap`, darwin getaddrinfo redefinition + dlsym.
        # The interposed symbol is also what Rust's std::net emits, so this fixes
        # the Rust binaries with no Rust-side change.
        dnsFallbackLib = pkgs: pkgs.stdenv.mkDerivation {
          pname = "unpin-dns-fallback";
          version = "0.1";
          src = ./dns-fallback;
          dontConfigure = true;
          buildPhase = ''
            runHook preBuild
            $CC -O2 -fPIC -ffunction-sections -fdata-sections \
              -c dns-fallback.c -o dns-fallback.o
            $AR rcs libunpindns.a dns-fallback.o
            runHook postBuild
          '';
          installPhase = ''
            runHook preInstall
            mkdir -p $out/lib
            cp libunpindns.a $out/lib/
            runHook postInstall
          '';
        };

        # Wrap a built drv's final link with the DNS fallback (linux-static only;
        # darwin/windows keep their native resolver). `--wrap` rides NIX_LDFLAGS
        # (NIX_CFLAGS_LINK gets wiped in postConfigure by some builds, e.g.
        # whois); lldRSafe strips `--wrap` from any `-r` partial-link, so the wrap
        # applies only at the final full link. `staticPkgs` is the scope the drv
        # was actually built in (pkgsStatic, NOT the glibc-host `pkgs`), so the .a
        # matches the consumer's arch. Interpose per toolchain:
        #   - linux musl / windows mingw: GNU ld `--wrap`. NIX_LDFLAGS lands at the
        #     END of the link line, so re-state the libc AFTER our archive (`-lc`;
        #     `-lws2_32 -lmsvcrt` on windows). rustc's `-nodefaultlibs` exposes it.
        #   - darwin: ld64 has no `--wrap`, so the archive DEFINES the symbols and
        #     `-force_load` wins over libSystem; the real ones via dlsym(RTLD_NEXT).
        withDnsFallback = staticPkgs: drv:
          let h   = staticPkgs.stdenv.hostPlatform;
              lib = "${dnsFallbackLib staticPkgs}/lib";
          in if (h.isLinux && (h.isStatic or false))
             then appendLdFlags drv
               # Short `-lunpindns`, NOT `-l:libunpindns.a`. The cc-wrapper
               # `-Wl,`-wraps each NIX_LDFLAGS token; the engine clang lowers the
               # short `-Wl,-l<name>` form (like `-Wl,-lc`) correctly, but drops
               # the `-l:` colon exact-file form (and bare abs paths) onto ld.lld
               # verbatim → `cannot open …-Wl,-l:libunpindns.a`. The dns dir is
               # static-only so `-lunpindns` resolves to libunpindns.a.
               ("--wrap=getaddrinfo --wrap=freeaddrinfo -L${lib} -lunpindns -lc")
             else if h.isWindows
             then appendLdFlags drv
               # -lws2_32 for the socket calls, -lkernel32 for GetCurrentProcessId,
               # -lmsvcrt for the basic CRT (calloc/getenv/memcpy/…). The archive
               # avoids snprintf, so no wide-char CRT cascade is pulled.
               ("--wrap=getaddrinfo --wrap=freeaddrinfo -L${lib} -l:libunpindns.a -lws2_32 -lkernel32 -lmsvcrt")
             else if h.isDarwin
             then appendLdFlags drv "-force_load ${lib}/libunpindns.a"
             else drv;

        # Make a build scope link `pkgName`'s final $CC link with lld + the
        # standard options via NIX_CFLAGS_LINK (build-system agnostic). Covers
        # what the gc overlay (Linux-native makeFlagsArray) and gcSectionsFlag
        # (multicall post-link) don't: SINGLE-BINARY packages on the cross targets.
        # No-op on darwin/cosmo and when pkgName is absent. Returns a full pkgs
        # scope so `pkgs.pkgsStatic.<name>` reaches the overlay.
        withLLDLink = pkgName: basePkgs:
          basePkgs // {
            pkgsStatic = basePkgs.pkgsStatic.extend (self: super:
              # `super` here is the static cross scope, but the same overlay is
              # re-evaluated for `pkgsStatic.buildPackages` (nixpkgs threads
              # overlays through the build-platform set). There `super` is the
              # NATIVE glibc host — and a cross build that references
              # `buildPackages.${pkgName}` (e.g. coreutils' Makefile `INSTALL =
              # ${buildPackages.coreutils}/bin/install`, or its man-copy from
              # `buildPackages.coreutils-full`) would then build that native
              # glibc tool WITH lld + --gc-sections. That breaks a glibc binary
              # that dynamically links e.g. libacl: --gc-sections/lld drops the
              # libacl.so.1 RUNPATH, so the tool fails to run at its own
              # help2man man-gen (`error while loading shared libraries:
              # libacl.so.1`). The flags only make sense for the static-musl
              # TARGET (static libacl, nothing to load at runtime), so gate on
              # isStatic — exactly as gc.nix does. Build-platform tools fall
              # back to stock (cache.nixos.org hit), which is what we want.
              if !(isLLDTarget super)
                 || !(super.stdenv.hostPlatform.isStatic or false)
                 || !(super ? ${pkgName}) then { }
              else {
                ${pkgName} = (appendLinkFlags super.${pkgName}
                  (lldStdOpts super)).overrideAttrs (old: {
                  # Use the pre-`.extend` host lld (`basePkgs.buildPackages`),
                  # NOT `super.buildPackages.lld`. In a cross scope `super` is
                  # the *extended* pkgsStatic whose buildPackages carries this
                  # very overlay; if pkgName is a build-foundational package
                  # (e.g. bash, which lld's own llvm→python test closure pulls
                  # in), `super.buildPackages.lld` → … → overridden bash → lld
                  # is an infinite recursion. `basePkgs.buildPackages` is the
                  # host set captured before the overlay, so its lld closure
                  # uses the un-overridden bash — same lld binary, no cycle.
                  # lldRSafe (the -r-safe ld.lld wrapper) so a `$CC -r` in the
                  # build doesn't choke on lldStdOpts' --icf.
                  nativeBuildInputs = (old.nativeBuildInputs or [ ])
                    ++ [ (lldRSafe basePkgs.buildPackages) ];
                });
              });
          };

        # Remove .so/.dylib/.la/.dll/.dll.a from a drv's outputs (postFixup, not
        # configure flags). GNU ld and Apple ld64 prefer shared over .a in -L
        # paths and ld64 has no `-Bstatic`, so deleting the shared artifact is the
        # only platform-neutral way to force a static link without patching the
        # consumer. Self-guarded: pkgsStatic drvs already produce only .a, skip
        # them to keep cache.nixos.org hits.
        dropSharedLibs = drv:
          let isStatic = drv.stdenv.hostPlatform.isStatic or false;
          in if isStatic then drv
          else drv.overrideAttrs (old: {
            postFixup = (old.postFixup or "") + ''
              for o in $outputs; do
                d="''${!o}"
                [ -d "$d/lib" ] || continue
                find "$d/lib" \( \
                       -name '*.dylib' -o -name '*.dylib.*' \
                    -o -name '*.so'    -o -name '*.so.*'    \
                    -o -name '*.la'                          \
                    -o -name '*.dll'   -o -name '*.dll.a'    \
                  \) -delete 2>/dev/null || true
              done
            '';
          });

        # Fallback-terminfo machinery (the curated terminal list + the two embed
        # variants) lives in ./ncurses-fallback.nix so it sits in one place and no
        # platform overlay depends on another's file. Reexported here so the
        # overlays (which receive `lib`) and consumer flakes reach the same source.
        inherit (import ./ncurses-fallback.nix)
          fallbackTerminals embedFallbackTerminfo embedFallbackTerminfoOnly;

        # openssl's packaging delta, single-sourced so the standalone `openssl`
        # package, its Windows build, and every engine consumer (native-overlay/
        # openssl.nix) apply the identical recipe instead of each re-rolling it.
        # nixpkgs compiles OPENSSLDIR/ENGINESDIR/MODULESDIR as paths into the static
        # libcrypto; left alone they point at the /nix/store output (a store ref in a
        # self-contained binary, and a path that doesn't exist on the user's host).
        # Retarget the three to the conventional system locations (sslDir = /etc/ssl
        # natively, C:/ssl on Windows) so the binary stays 0-ref and consults the
        # host's openssl.cnf + trust store like a distro openssl. nixpkgs adds `no-ct`
        # for static builds solely because CT bakes a /nix/store CTLOG_FILE; with
        # OPENSSLDIR retargeted that follows to sslDir/ct_log_list.cnf, so drop the
        # flag and ship CT. c_rehash is a legacy perl-equivalent shim wrapped via
        # makeWrapper; we delete it, but makeBinaryWrapper *compiles* it first with
        # `cc -x c -` (C on stdin) — under the unpin-llvm engine the cc-wrapper
        # appends crt1.o while -x c is active and clang parses the ELF crt as C
        # (-Werror,-Wnull-character). Stub makeWrapper so the shim is never built
        # (non-engine builds compiled it fine but deleted it anyway — pure waste).
        retargetOpenssl = sslDir: enginesDir: modulesDir: old: {
          configureFlags = builtins.filter (f: f != "no-ct") (old.configureFlags or [ ]);
          buildFlags = (old.buildFlags or [ ]) ++ [
            "OPENSSLDIR=${sslDir}"
            "ENGINESDIR=${enginesDir}"
            "MODULESDIR=${modulesDir}"
          ];
          postInstall = ''
            makeWrapper() { :; }
          '' + (old.postInstall or "") + ''
            rm -f "''${bin:-$out}/bin/c_rehash"
          '';
        };

        # Canonical libarchive for the catalog: ONE derivation shared by every
        # unpin that links libarchive (tar ships bsdtar over it; e2fsprogs uses
        # it for `mke2fs -d <archive>`). Because both consumers link this exact
        # store `.a` as an EXTERNAL depArchive, the catalog mega folds a SINGLE
        # copy (STOREA, deduped by path) instead of one baked into each package's
        # module.bc. Curated lean + dependency-symmetric so the shared drv suits
        # every consumer:
        #   * xarSupport=false → no libxml2 (XAR is Apple .pkg legacy). Drops the
        #     libxml2 store-ref AND its darwin xmlIconvConvert iconv reference.
        #   * --without-openssl always: nixpkgs keeps openssl an unconditional
        #     buildInput AND names it in preFixup, so under the engine cc OpenSSL
        #     would build with -flto (tens of minutes/arch) for a lib nothing
        #     links — filter it out and rewrite preFixup to keep only the lzo .la
        #     fixup. libarchive's crypto (encrypted ZIP/7z, mtree digests) instead
        #     comes from **mbedtls on linux** (~500 KB, not OpenSSL 3.x's ~4 MB).
        #   * The crypto backend does NOT force itself on every consumer, because
        #     `archive_read_support_format_all()` is explicit calls (not ctors) and
        #     only the zip/7z/mtree/xar handlers reference the digest/cryptor layer.
        #     A static `.a` pulls a member only if referenced: bsdtar calls
        #     format_all → pulls the crypto members → keeps the feature; e2fsprogs
        #     is patched to register only format_tar (see its flake) → never
        #     references crypto → mbedtls stays OUT of e2fsprogs even though it
        #     links this same crypto-enabled `.a`. So one shared libarchive serves
        #     both without dragging crypto into the fs tools.
        #   * darwin: --without-mbedtls (nixpkgs-mbedtls + darwin engine-cc don't
        #     build cleanly — clang-detected-as-GNU cmake flags, -static-libgcc in
        #     the test link, a threading postConfigure that can't find its script).
        #     darwin tar therefore has no encrypted-archive/digest support, as
        #     before this convergence; core formats + compression are unaffected.
        #     archive_string.c calls iconv, which GNU libiconvReal (the
        #     engine-darwin swap) renames to libiconv(); bake libiconvReal into
        #     buildInputs so the object references libiconv() — the consumer's
        #     final link carries libiconvReal via darwinIconvFixed. --disable-shared
        #     via configureFlagsArray (ld64.lld rejects the -soname libtool would
        #     otherwise pass for the dylib; a plain flag is stripped on darwin).
        unpinLibarchive = pkgs:
          let
            l = nixpkgs.lib;
            isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
            isLinux = pkgs.stdenv.hostPlatform.isLinux;
            static = pkgs.pkgsStatic;
            noOpenssl = l.filter (d: !(l.hasInfix "openssl" (d.name or "")));
          in
          (static.libarchive.override { xarSupport = false; }).overrideAttrs (o: {
            doCheck = false;
            buildInputs = noOpenssl (o.buildInputs or [ ])
              ++ l.optional isDarwin static.libiconvReal;
            # mbedtls is PROPAGATED (not a plain buildInput) so every consumer's
            # link environment carries its -L: e2fsprogs' configure copies
            # libarchive's `-lmbedcrypto` into its own Makefiles (it doesn't read
            # the .la via libtool at link), so the search path must reach it that
            # way. Propagation also lands mbedcrypto.a in each consumer's manifest
            # depInputDirs, so the mega has it available — tar's applet references
            # it (pulled), e2fsprogs' format_tar-only applet does not (left out).
            propagatedBuildInputs = noOpenssl (o.propagatedBuildInputs or [ ])
              ++ l.optional isLinux static.mbedtls;
            configureFlags = (o.configureFlags or [ ]) ++ [ "--without-openssl" ]
              ++ [ (if isLinux then "--with-mbedtls" else "--without-mbedtls") ];
            # libtool records libarchive's optional deps in the installed .la's
            # dependency_libs as bare `-l` flags with no `-L`; a consumer that
            # links this store .la (bsdtar, e2fsprogs' debugfs) then hits
            # "unable to find library" unless it happens to carry that dep in its
            # own buildInputs. Bake the search paths into the .la so it is
            # self-contained for every consumer. mbedcrypto only on linux (the
            # only place --with-mbedtls added it; gating the interpolation keeps
            # darwin from realising pkgsStatic.mbedtls, which doesn't build there).
            preFixup = ''
              sed -i $lib/lib/libarchive.la \
                -e 's|-llzo2|-L${static.lzo}/lib -llzo2|'
            '' + l.optionalString isLinux ''
              sed -i $lib/lib/libarchive.la \
                -e 's|-lmbedcrypto|-L${l.getLib static.mbedtls}/lib -lmbedcrypto|'
            '';
          } // l.optionalAttrs isDarwin {
            preConfigure = (o.preConfigure or "") + ''
              configureFlagsArray+=("--disable-shared")
            '';
          });

        # Strip `--enable-static`/`--disable-shared` from configureFlags on
        # darwin. Many GNU-ish configure.ac (dash, htop) translate
        # `--enable-static` into `LDFLAGS=-static`, which breaks every subsequent
        # AC_CHECK_LIB probe — darwin has only libSystem.dylib, no libSystem.a — so
        # consumers think deps are missing. Filtering lets each pkgsStatic input
        # still contribute its `.a`; only libSystem stays dynamic. Applied in
        # mkStandaloneFlake's native pipeline. Not on mingw/cosmo (no libSystem
        # issue, and --enable-static there is a genuine static-link request).
        filterEnableStaticOnDarwin = drv:
          if (drv.stdenv.hostPlatform.isDarwin or false)
          then drv.overrideAttrs (old: {
            configureFlags = nixpkgs.lib.filter
              (f: f != "--enable-static" && f != "--disable-shared")
              (old.configureFlags or [ ]);
          })
          else drv;

        # Darwin libiconv handling, applied to every darwin build in
        # mkStandaloneFlake's pipeline. macOS keeps iconv in a standalone libiconv
        # and the portability allow-list permits only libSystem/libobjc/Frameworks,
        # so anything referencing iconv must link it statically:
        #
        #  * Target link (every darwin build): use the *static* libiconv (a
        #    pkgsStatic leaf, dodging the broken cctools-static cascade) so the
        #    binary carries no libiconv.2.dylib load command. The bare `-liconv`
        #    rides the unsalted NIX_LDFLAGS; harmless when nothing references it.
        #
        #  * Build-host link (darwin CROSS only): rustc appends `-liconv` for
        #    build-host links (build scripts, proc-macro dylibs) against the salted
        #    NIX_LDFLAGS_<buildSalt>, which has no path for it → "library not found".
        #    Hand it a build-arch -L. CROSS-ONLY: native, build salt == target
        #    salt, so this -L would pull a *dynamic* libiconv and trip the allow-list.
        #
        # Darwin-only. See docs/platforms/darwin.md ("the libiconv catch").
        withDarwinIconv = pkgs: drv:
          let
            host = pkgs.stdenv.hostPlatform;
            cross = host.config != pkgs.stdenv.buildPlatform.config;
            buildSalt = pkgs.buildPackages.stdenv.cc.suffixSalt;
          in
          if !(host.isDarwin or false) then drv
          else drv.overrideAttrs (old: {
            buildInputs = [ pkgs.pkgsStatic.libiconv ] ++ (old.buildInputs or [ ]);
            preBuild = (old.preBuild or "")
              + nixpkgs.lib.optionalString cross ''
                export NIX_LDFLAGS_${buildSalt}="''${NIX_LDFLAGS_${buildSalt}:-} -L${nixpkgs.lib.getLib pkgs.buildPackages.libiconv}/lib"
              '';
          # structuredAttrs drvs (coreutils-full) keep NIX_LDFLAGS in `env`;
          # setting it top-level too is a hard collision. Route to env there,
          # keep the top-level append everywhere else (byte-identical).
          } // (if old ? env && old.env ? NIX_LDFLAGS
                then { env = old.env // { NIX_LDFLAGS = old.env.NIX_LDFLAGS + " -liconv"; }; }
                else { NIX_LDFLAGS = (old.NIX_LDFLAGS or "") + " -liconv"; }));

        # Build-host-native tool that packs a staging `unpin/` tree into a
        # zstd-in-zip (ZIP method 93) overlay — the format withMan/withAliases use.
        # Shipped binaries decode method 93 with unpin's pure-Rust ruzstd reader
        # (unpin/src/meta.rs). Sources vendored from unpins/unpin-vfs.
        # `-DMINIZ_NO_TIME` zeroes entry mtimes so the overlay is byte-reproducible.
        unpinPackTool = pkgs: pkgs.buildPackages.stdenv.mkDerivation {
          name = "unpin-vfs-pack";
          dontUnpack = true;
          buildInputs = [ pkgs.buildPackages.zstd ];
          buildPhase = ''
            $CC -O2 -DMINIZ_USE_ZSTD -DMINIZ_NO_TIME -I${./vfs-pack} \
              ${./vfs-pack/unpin-vfs-pack.c} ${./vfs-pack/miniz.c} ${./vfs-pack/unpin_zstd.c} \
              -o unpin-vfs-pack -lzstd
          '';
          installPhase = ''mkdir -p $out/bin; cp unpin-vfs-pack $out/bin/'';
        };

        # Shared embed primitive for withAliases/withMan/withRuntimeData: add a
        # staging tree to the binary's embedded ZIP (docs/embedded-metadata.md).
        # Every binary ends up with exactly ONE ZIP with absolute offsets (the
        # self-extracting convention, so `unzip <binary>` reads clean and cosmo's
        # zipos parses it). Two paths:
        #
        #  * cosmo: REWRITE the existing tail-ZIP (a second appended ZIP would
        #    shadow cosmo's `/zip/` store, found via the EOF EOCD). `--carry`
        #    copies its entries verbatim and adds ours as zstd in the same archive.
        #  * everything else: truncate back to pre-embed size and append our ZIP.
        # Both accumulate the subtree per-binary and repack the whole tree as one
        # ZIP (all zstd except `unpin/aliases`, kept deflate for pre-zstd readers);
        # a later call replaces the overlay with a superset — never two ZIPs.
        #
        # On Mach-O the overlay sits past LC_CODE_SIGNATURE, outside the signed
        # range, so the kernel ignores it.
        unpinEmbedSh = ''
          __unpin_embed_subtree() {
            __ues_bin="$1"; __ues_stage="$2"
            if [ ! -f "$__ues_bin" ]; then
              echo "unpin embed: $__ues_bin does not exist" >&2; exit 1
            fi
            find "$__ues_stage" -mindepth 1 -exec touch -h -d "@''${SOURCE_DATE_EPOCH:-315532800}" {} + 2>/dev/null || true
            __ues_names="$(cd "$__ues_stage" && find . -mindepth 1 \( -type f -o -type l \) | sed 's|^\./||' | LC_ALL=C sort)"
            [ -n "$__ues_names" ] || return 0

            # Merge this call's subtree into the per-binary accumulator, so
            # withAliases + withMan + withRuntimeData compose into ONE archive.
            __ues_acc="$NIX_BUILD_TOP/.unpin-embed-$(printf '%s' "$__ues_bin" | cksum | cut -d' ' -f1)"
            mkdir -p "$__ues_acc"
            cp -a "$__ues_stage/." "$__ues_acc/"
            # unpin-vfs-pack stores no symlinks (miniz emits no unix link
            # mode), so resolve `.so`-redirect man links to their target's
            # bytes — same deref the @INC blob does with `cp -L`.
            find "$__ues_acc" -type l | while IFS= read -r __ues_l; do
              __ues_t="$(readlink -f "$__ues_l" 2>/dev/null || true)"
              if [ -n "$__ues_t" ] && [ -f "$__ues_t" ]; then
                rm -f "$__ues_l"; cp "$__ues_t" "$__ues_l"
              fi
            done

            # Where to put the ONE ZIP. A Cosmopolitan APE already carries a
            # tail-ZIP (its `/zip/` store: `.cosmo`, zoneinfo, a stdlib, …)
            # located by the end-of-file EOCD, so a SECOND ZIP appended after it
            # would shadow it. We instead REWRITE that tail-ZIP: `--carry` copies
            # its entries verbatim (deflate/store preserved so cosmo still reads
            # them, `.symtab.amd64` dropped) and ours go in as zstd. The base
            # then defaults to where cosmo's ZIP began, which the pack tool
            # prints. Every other binary has no tail-ZIP: truncate back to the
            # pristine size and append. grep WITHOUT -q: pipefail + -q's early
            # exit would SIGPIPE unzip on a listing bigger than the pipe buffer.
            if [ -n "$(unzip -Z1 "$__ues_bin" 2>/dev/null | grep -xF .cosmo)" ]; then
              # Carry from a snapshot of the pristine APE taken before our first
              # append, so re-running (aliases then man) always rebuilds from
              # cosmo's original store, never from a half-embedded binary.
              __ues_src="$__ues_acc.cosmosrc"
              [ -f "$__ues_src" ] || cp "$__ues_bin" "$__ues_src"
              __ues_place="--carry $__ues_src"
            else
              # First call records the pristine size; later calls truncate the
              # previous overlay away so the repack below replaces it.
              if [ -f "$__ues_acc.size" ]; then
                truncate -s "$(cat "$__ues_acc.size")" "$__ues_bin"
              else
                stat -c %s "$__ues_bin" > "$__ues_acc.size"
              fi
              __ues_place="--base $(stat -c %s "$__ues_bin")"
            fi

            __ues_d="$(mktemp -d)"
            # The pack tool prints the resolved base (where to truncate-and-
            # append) on stdout; its stats go to stderr.
            __ues_base=$(unpin-vfs-pack "$__ues_d/m.zip" "$__ues_acc" \
              $__ues_place --deflate unpin/aliases)
            # A shared zstd dictionary (`zstd --train`, stored as `.unpin/zdict`,
            # auto-loaded by the reader) exploits cross-page roff redundancy for a
            # much bigger win on large man sets — but it's ~110 KB STORED, dead
            # weight on a small one. So only train above a threshold, and keep the
            # dict variant ONLY if it actually came out smaller: the dict can never
            # make a package larger, and training too-few samples just falls back.
            __ues_raw=$(find "$__ues_acc" -type f -printf '%s\n' | awk '{s+=$1} END{print s+0}')
            if [ "''${__ues_raw:-0}" -ge 1048576 ] && command -v zstd >/dev/null 2>&1; then
              if ( cd "$__ues_acc" && zstd -q -f --train $(find . -type f | LC_ALL=C sort) -o "$__ues_d/zdict" --maxdict=112640 2>/dev/null ) \
                 && unpin-vfs-pack "$__ues_d/md.zip" "$__ues_acc" --dict "$__ues_d/zdict" \
                      $__ues_place --deflate unpin/aliases >/dev/null; then
                if [ "$(wc -c < "$__ues_d/md.zip")" -lt "$(wc -c < "$__ues_d/m.zip")" ]; then
                  mv "$__ues_d/md.zip" "$__ues_d/m.zip"
                fi
              fi
            fi
            # cosmo: strips the prior overlay back to cosmo's ZIP start; else:
            # already truncated above, so this is a no-op at the pristine size.
            truncate -s "$__ues_base" "$__ues_bin"
            cat "$__ues_d/m.zip" >> "$__ues_bin"
            rm -rf "$__ues_d"
          }
        '';

        # Shared man-tree staging, used by BOTH embed paths (in-build
        # withUnpinEmbed and post-build unpinEmbedWrap). Locates a `share/man`
        # root and runs mkmeta.py into $__unpin_stage. `candidates` is a bash
        # word-list probed in order when no explicit `manRoot` is given — the
        # in-build path passes its build-env output vars (`$man`/`$out`/…), the
        # post-build path passes resolved store paths; both reduce to "first dir
        # with share/man wins". `manFallback` borrows a man-bearing build (the
        # windows graft) when the chosen root has no actual pages. mkmeta.py
        # populates its OWN temp dir, merged into $__unpin_stage only on success,
        # so an exit-3 skip leaves no partial `unpin/man`. exit 3 = no pages
        # (legit skip); any other nonzero = fail the build (never silently ship
        # man-less).
        unpinManStageSh = { tag, manRoot ? null, manFallback ? null, candidates ? [ ] }: ''
          ${if manRoot != null then ''
          # Externally supplied man source (windows/cosmo graft, or a curated tree).
          __unpin_manroot="${manRoot}"
          [ -d "$__unpin_manroot/share/man" ] || __unpin_manroot=""
          '' else ''
          # Harvest from the build/base outputs: first candidate with share/man.
          __unpin_manroot=""
          for __unpin_d in ${builtins.toString candidates}; do
            if [ -n "$__unpin_d" ] && [ -d "$__unpin_d/share/man" ]; then
              __unpin_manroot="$__unpin_d"; break
            fi
          done
          ''}${nixpkgs.lib.optionalString (manFallback != null) ''
          # No man of our own (no share/man, or a pruned-empty one) → borrow the
          # version-locked pages from a man-bearing build. -print -quit: no pipe
          # (stdenv runs `set -o pipefail`; `find | grep -q` SIGPIPEs grep on any
          # tree bigger than the pipe buffer, misreading it as empty).
          if [ -d "${manFallback}/share/man" ] \
             && { [ -z "$__unpin_manroot" ] \
                  || [ -z "$(find "$__unpin_manroot/share/man" \( -type f -o -type l \) -print -quit 2>/dev/null)" ]; }; then
            __unpin_manroot="${manFallback}"
          fi''}
          if [ -z "$__unpin_manroot" ]; then
            echo "${tag}: no share/man found, skipping" >&2
          else
            __unpin_ms="$(mktemp -d)"; __unpin_rc=0
            python3 ${./mkmeta.py} "$__unpin_manroot" "$__unpin_ms" || __unpin_rc=$?
            if [ "$__unpin_rc" = 3 ]; then
              echo "${tag}: no man pages, skipping" >&2
            elif [ "$__unpin_rc" != 0 ]; then
              echo "${tag}: mkmeta.py failed (exit $__unpin_rc)" >&2
              exit "$__unpin_rc"
            else
              cp -a "$__unpin_ms/." "$__unpin_stage/"
            fi
            rm -rf "$__unpin_ms"
          fi
        '';

        # Shared stage population, used by BOTH embed paths. Given a created
        # $__unpin_stage and (for aliases) the CSV pre-set in $__unpin_al, writes
        # the runtime tree, `unpin/aliases`, and the man tree. The runtime tree
        # goes in FIRST, into the still-empty stage, so its "produced nothing"
        # guard is exact (a declared runtimeStage that stages no files is broken,
        # not degraded → hard fail). ZIP entry order is independent of staging
        # order (the packer sorts), so aliases/man order is free.
        #
        # What stays in the callers — because it genuinely differs — is binary
        # discovery + the missing-primary policy (in-build: one bin, fail for
        # aliases/runtime but warn-skip for man-only; post-build: N bin variants),
        # and WHERE $__unpin_al / the man candidates come from (build-env symlinks
        # & output vars vs. resolved store paths).
        unpinStageSh =
          { tag, manEnabled, manRoot ? null, manFallback ? null
          , manCandidates ? [ ], runtimeStage ? null }: ''
          ${nixpkgs.lib.optionalString (runtimeStage != null) ''
          ${runtimeStage}
          if [ -z "$(find "$__unpin_stage" -mindepth 1 \( -type f -o -type l \) -print -quit)" ]; then
            echo "${tag}: runtime stage produced no files" >&2
            exit 1
          fi
          ''}
          if [ -n "''${__unpin_al:-}" ]; then
            mkdir -p "$__unpin_stage/unpin"
            printf '%s' "$__unpin_al" | tr ',' '\n' > "$__unpin_stage/unpin/aliases"
          fi
          ${nixpkgs.lib.optionalString manEnabled
            (unpinManStageSh { inherit tag manRoot manFallback; candidates = manCandidates; })}
        '';

        # withUnpinEmbed: the IN-BUILD embed (overrideAttrs postFixup). Most
        # packages embed POST-BUILD via unpinEmbedWrap (the runCommand below) —
        # standalone CLIs, the mega/self-fold, and the VFS packages (via
        # mkStandaloneFlake's `runtimeEmbed`). withUnpinEmbed is retained for the
        # recipe-A hand-rolled multicall packages (bzip2, aom, …) that build a
        # multicall binary mid-recipe and must embed the applet aliases INTO that
        # binary during the build (`lib.withAliases`), where a post-build wrap can't
        # reach. It stages every payload into a single ZIP-root tree and packs the
        # binary's EOF ZIP once, sharing the same staging logic (unpinStageSh +
        # unpinManStageSh) and pack primitive (unpinEmbedSh + mkmeta.py) as
        # unpinEmbedWrap — only the binary discovery and missing-primary policy
        # differ:
        #
        #   * aliases       → `unpin/aliases` (explicit list or symlink harvest)
        #   * man pages     → `unpin/man/*` via mkmeta.py (`man = true`, or an
        #                     explicit `manRoot`; optional `manFallback`)
        #   * runtime tree  → arbitrary entries at the ZIP root, served by the
        #                     unpin-vfs self-EOF mode (`runtimeStage` snippet)
        #
        # withAliases/withMan/withRuntimeData are thin wrappers; passing
        # everything here pays for ONE pack. When man is included the result
        # carries `passthru.unpinEmbedsMan` so mkStandaloneFlake skips its own
        # withMan.
        #
        # Failure policy: a missing primary binary is a hard error for an
        # aliases/runtime call but warn-and-skip for man-only (embedMan is
        # default-on; man-less is degraded, not broken). An empty runtime stage
        # always fails.
        withUnpinEmbed = pkgs:
          { primary
          , aliases ? null
          , aliasesFromSymlinksIn ? null
          , man ? false
          , manRoot ? null
          , manFallback ? null
          , runtimeStage ? null
          }: drv:
          let
            hasExplicit = aliases != null;
            hasAuto = aliasesFromSymlinksIn != null;
            manEnabled = man || manRoot != null;
            aliasesActive = (hasExplicit && aliases != [ ]) || hasAuto;

            # Alias names are embedded verbatim — nix-lib does NOT validate them.
            # All alias policy lives solely in unpin (validate_alias /
            # alias_needs_confirmation in unpin/src/aliases.rs), enforced at
            # install time; a second copy here only drifts.
            explicitCsv =
              if hasExplicit
              then nixpkgs.lib.concatStringsSep "," aliases
              else "";

            # Pick the output the binary lives in: `bin` when split (jq, htop),
            # else `out` (pkgsStatic usually collapses to it). `''${${binOutputName}}`
            # below renders as `${bin}`/`${out}` for bash to expand.
            binOutputName =
              let outs = drv.outputs or [ "out" ];
              in
              if builtins.elem "bin" outs then "bin"
              else if builtins.elem "out" outs then "out"
              else builtins.head outs;

            wrapped = drv.overrideAttrs (old: {
              nativeBuildInputs = (old.nativeBuildInputs or [ ])
                ++ [
                  # Build + add to the binary's embedded ZIP. Build-only (~few
                  # MB closure), never linked into the shipped artifact. unzip
                  # detects the cosmo tail-ZIP (read-only); the pack tool (with
                  # --carry) rewrites it and does the single-overlay repack;
                  # zstd trains the shared dict.
                  pkgs.buildPackages.unzip
                  (unpinPackTool pkgs)
                  pkgs.buildPackages.zstd
                ]
                ++ nixpkgs.lib.optional manEnabled
                  pkgs.buildPackages.python3Minimal;  # mkmeta.py builds the man tree

              # Lets mkStandaloneFlake see that man is already handled here
              # and skip its own withMan application (one pack, not two).
              passthru = (old.passthru or { })
                // nixpkgs.lib.optionalAttrs manEnabled { unpinEmbedsMan = true; };

              postInstall = (old.postInstall or "")
                + nixpkgs.lib.optionalString hasAuto ''
                # Harvest every multi-call symlink (skipping the primary, which
                # is the real binary) and embed the names verbatim. No name
                # filtering here: alias policy — charset/length rules,
                # Windows-reserved names, blocklist, the catalog-owner gate, the
                # MAX_ALIASES cap — lives solely in unpin and runs at install
                # time (`validate_alias` in unpin/src/aliases.rs). The build
                # just records which applets the package ships; the installer
                # decides which are safe to link.
                __unpin_aliases=""
                for f in "''${${binOutputName}}/${aliasesFromSymlinksIn}"/*; do
                  [ -L "$f" ] || continue
                  n="$(basename "$f")"
                  [ "$n" = "${primary}" ] && continue
                  __unpin_aliases="''${__unpin_aliases:+$__unpin_aliases,}$n"
                done
                printf '%s' "$__unpin_aliases" > "$NIX_BUILD_TOP/.unpin-aliases"
                find "''${${binOutputName}}/${aliasesFromSymlinksIn}" -maxdepth 1 -type l -delete
              '';

              postFixup = (old.postFixup or "") + ''
                ${unpinEmbedSh}
                __unpin_bin="''${${binOutputName}}/bin/${primary}"
                # Windows artifacts are `<primary>.exe`.
                if [ ! -f "$__unpin_bin" ] && [ -f "$__unpin_bin.exe" ]; then
                  __unpin_bin="$__unpin_bin.exe"
                fi
                if [ ! -f "$__unpin_bin" ]; then
                  ${if aliasesActive || runtimeStage != null then ''
                  echo "withUnpinEmbed: $__unpin_bin does not exist" >&2
                  exit 1
                  '' else ''
                  # Man-only call (embedMan is default-on across the catalog):
                  # warn and skip rather than fail — worst case is no embedded
                  # man for this package, a degraded result, not a broken one.
                  echo "withUnpinEmbed: $__unpin_bin missing — skipping embed for ${primary}" >&2
                  __unpin_bin=""
                  ''}
                fi
                if [ -n "$__unpin_bin" ]; then
                  # ONE staging dir = the ZIP root; every payload lands here
                  # and a single __unpin_embed_subtree packs it all.
                  __unpin_stage="$(mktemp -d)"
                  ${nixpkgs.lib.optionalString aliasesActive ''
                  # Source the alias CSV — explicit list, or the names harvested
                  # in postInstall (symlinks deleted there, so a file carries
                  # them forward). The shared stage snippet writes unpin/aliases.
                  # No name filtering: alias policy lives in unpin and runs at
                  # install time (validate_alias in unpin/src/aliases.rs).
                  ${if hasExplicit
                    then "__unpin_al='${explicitCsv}'"
                    else ''__unpin_al="$(cat "$NIX_BUILD_TOP/.unpin-aliases")"''}
                  [ -n "$__unpin_al" ] \
                    || echo "withUnpinEmbed: no aliases to embed for ${primary}, skipping" >&2
                  ''}
                  # Stage runtime tree + aliases + man into $__unpin_stage. The
                  # man candidates are this build's OUTPUT ENV VARS ($man/$out/the
                  # bin output) — resolved at build time, unlike the post-build
                  # wrap's store paths.
                  ${unpinStageSh {
                    tag = "withUnpinEmbed";
                    inherit manEnabled manRoot manFallback runtimeStage;
                    manCandidates = [ ''"''${man:-}"'' ''"''${${binOutputName}}"'' ''"''${out:-}"'' ];
                  }}
                  # A man-only call may legitimately have staged nothing
                  # (no man found / exit-3 skip) — embed only when something
                  # is there. Runtime emptiness already failed hard above.
                  if [ -n "$(find "$__unpin_stage" -mindepth 1 \( -type f -o -type l \) -print -quit)" ]; then
                    __unpin_embed_subtree "$__unpin_bin" "$__unpin_stage"
                  fi
                  rm -rf "$__unpin_stage"
                fi
              '';
            });
          in
          if hasExplicit && hasAuto then
            throw "withUnpinEmbed: pass either `aliases` or `aliasesFromSymlinksIn`, not both"
          # Nothing to embed at all → return the input drv untouched (no
          # nativeBuildInputs bloat, no postInstall/postFixup hooks). The
          # MAX_ALIASES cap and all name validation are enforced by unpin at
          # install time, not here (see validate_alias in unpin/src/aliases.rs).
          else if !aliasesActive && !manEnabled && runtimeStage == null then drv
          else wrapped;

        # Thin wrapper over withUnpinEmbed — embed only the alias list. Two
        # input modes (explicit `aliases` list or `aliasesFromSymlinksIn` harvest).
        withAliases = pkgs:
          { primary
          , aliases ? null
          , aliasesFromSymlinksIn ? null
          }: drv:
          if aliases == null && aliasesFromSymlinksIn == null then
            throw "withAliases: requires `aliases` or `aliasesFromSymlinksIn`"
          else
            withUnpinEmbed pkgs { inherit primary aliases aliasesFromSymlinksIn; } drv;

        # Thin wrapper over withUnpinEmbed — embed only the package's man pages
        # as `unpin/man/<name>.<section>` entries. `manRoot` null harvests from
        # the drv's own outputs (`$man`/`$out`); a store path reads
        # `$manRoot/share/man` instead. `manFallback` is consulted only on the
        # harvest-own path when the drv ships no man (the windows/cosmo default).
        withMan = pkgs: { primary, manRoot ? null, manFallback ? null }: drv:
          withUnpinEmbed pkgs { inherit primary manRoot manFallback; man = true; } drv;

        # Thin wrapper over withUnpinEmbed — embed only a runtime tree (vim's
        # share/vim, perl's @INC), read back at run time by the unpin-vfs self-EOF
        # mode. `stage` is a postFixup shell snippet (AFTER strip) with
        # `$__unpin_stage` = the empty ZIP-root dir to populate. An empty stage
        # fails the build (a missing runtime tree is broken, not degraded).
        withRuntimeData = pkgs: { primary, stage }: drv:
          withUnpinEmbed pkgs { inherit primary; runtimeStage = stage; } drv;

        # unpinEmbedWrap — the SINGLE post-build embed for every shipped binary
        # (native single-binary, mega/self-fold, windows mingw/cosmo, and the
        # build-coupled VFS packages vim/perl). It replaces the older overrideAttrs
        # embed (withUnpinEmbed and its thin wrappers): rather than fork the build's
        # postFixup — which would make a library consumer link a DIFFERENT artifact
        # than the package ships — it copies the pristine `base` binary into a cheap
        # runCommand and embeds there, so the base build is shared byte-for-byte with
        # library consumers (ONE derivation per package: openssl as a shipped CLI vs
        # as dnsutils' libcrypto dep).
        #
        # The base binary is UNSTRIPPED (the engine adapter defers strip); we strip
        # the copy with `stripCmd` (default = the engine's own llvm-strip, proven
        # byte-identical to the fixup strip on engine targets; windows/cosmo pass
        # their own) and never touch the base's lib/dev outputs, so consumers still
        # link full symbols.
        #
        # Payloads (all compose into the single EOF ZIP via unpinEmbedSh):
        #   * aliases   — explicit list, else AUTO-DISCOVERED from sibling symlinks
        #                 in the bin dir (like the multicall `.a` glob)
        #   * man       — `manRoot`/share/man if given, else auto from the base
        #                 outputs; `manFallback` borrows a man-bearing build when the
        #                 build ships none (windows graft). `man = false` skips it.
        #   * runtime   — the one DECLARED arbitrary tree (vim/perl @INC, file magic);
        #                 the snippet populates `$__unpin_stage`.
        #
        # `cosmoSymtabTrim` drops cosmo's unused `.symtab.amd64` ZIP member. Every
        # binary variant the build produced (`<primary>`, `.exe`, `.ape`) is copied,
        # stripped, and gets the container embedded.
        unpinEmbedWrap = pkgs:
          { primary
          , aliases ? null
          , man ? true
          , manRoot ? null
          , manFallback ? null
          , runtimeStage ? null
          , stripCmd ? null
          , cosmoSymtabTrim ? false
          , removeReferences ? [ ]  # name-substring patterns whose store refs are
                                    # DEAD baked datadir/helper paths (never reached
                                    # at runtime in the standalone binary); scrub them
                                    # so the 0-ref invariant holds. Opt-in — [] leaves
                                    # the drv byte-identical. See mkStandaloneFlake's
                                    # `multicall.removeReferences`.
          }: base:
          let
            nukeRefs = removeReferences != [ ];
            outs = base.outputs or [ "out" ];
            binOutputName =
              if builtins.elem "bin" outs then "bin"
              else if builtins.elem "out" outs then "out"
              else builtins.head outs;
            binOut = base.${binOutputName};
            manOut = base.man or binOut;
            outOut = base.out or binOut;
            strip =
              if stripCmd != null then stripCmd
              else "${unpinToolchain pkgs.stdenv.buildPlatform.system}/bin/llvm llvm-strip --strip-all";
            hasExplicitAliases = aliases != null;
            explicitCsv = if hasExplicitAliases then nixpkgs.lib.concatStringsSep "," aliases else "";
          in
          pkgs.runCommand (base.name or "${base.pname or primary}-${base.version or "0"}")
            {
              nativeBuildInputs = [
                pkgs.buildPackages.unzip
                (unpinPackTool pkgs)
                pkgs.buildPackages.zstd
              ]
              ++ nixpkgs.lib.optional man pkgs.buildPackages.python3Minimal
              ++ nixpkgs.lib.optional cosmoSymtabTrim pkgs.buildPackages.zip
              ++ nixpkgs.lib.optional nukeRefs pkgs.buildPackages.removeReferencesTo;
              # Carry the base passthru (notably `module` for a multicall fold and
              # version/pname) so the mega manifest and withLicense/withDescription
              # still resolve against the shipped drv.
              passthru = (base.passthru or { })
                // nixpkgs.lib.optionalAttrs (base ? module) { inherit (base) module; };
              # Carry upstream meta (license/description) but pin outputsToInstall to
              # this runCommand's single `out` — base.meta lists the multi-output
              # openssl's `[bin man …]`, which `nix build` would otherwise try to
              # realize on a drv that only has `out`.
              meta = (base.meta or { }) // { outputsToInstall = [ "out" ]; };
            }
            ''
              mkdir -p "$out/bin"
              # The shipped binary may be <primary> (native), <primary>.exe (mingw /
              # cosmo PE) and/or <primary>.ape (cosmo fat APE). Copy+strip every
              # variant the build produced; the container is embedded into each.
              __unpin_bins=()
              for __unpin_v in "${primary}" "${primary}.exe" "${primary}.ape"; do
                if [ -f "${binOut}/bin/$__unpin_v" ]; then
                  cp "${binOut}/bin/$__unpin_v" "$out/bin/$__unpin_v"
                  chmod +w "$out/bin/$__unpin_v"
                  ${strip} "$out/bin/$__unpin_v"${nixpkgs.lib.optionalString nukeRefs ''

                    # Scrub DEAD store refs: these are baked datadir/helper path
                    # constants (glib localedir, libX11 compose/locale, dbus-launch,
                    # the package's own install libdir) inlined from the deps — the
                    # code is statically linked in, so the strings are never reached
                    # at runtime in this self-contained binary, yet Nix counts them as
                    # runtime refs and drags their whole (build) closure. Discover the
                    # matching store paths IN the binary and rewrite their hash so the
                    # ref (and its closure) drops, leaving behaviour unchanged. Runs
                    # BEFORE the man/alias ZIP embed (that data carries no store paths).
                    # This whole block is gated by `optionalString nukeRefs` glued to
                    # the strip line above: with removeReferences = [] it is "", so the
                    # buildPhase — and the drv — is byte-identical to before.
                    for __unpin_p in $(grep -aoE '/nix/store/[a-z0-9]{32}-[^ "'"'"'()]*' "$out/bin/$__unpin_v" \
                         | sed -E 's#(/nix/store/[a-z0-9]{32}-[a-zA-Z0-9._+-]+).*#\1#' | sort -u); do
                      for __unpin_pat in ${nixpkgs.lib.concatMapStringsSep " " nixpkgs.lib.escapeShellArg removeReferences}; do
                        case "$__unpin_p" in
                          *"$__unpin_pat"*)
                            remove-references-to -t "$__unpin_p" "$out/bin/$__unpin_v" \
                              && echo "unpinEmbedWrap: scrubbed dead ref $__unpin_p (matched '$__unpin_pat')" >&2
                            break ;;
                        esac
                      done
                    done''}
                  __unpin_bins+=("$out/bin/$__unpin_v")
                fi
              done
              if [ "''${#__unpin_bins[@]}" = 0 ]; then
                echo "unpinEmbedWrap: no binary <${primary}>[.exe|.ape] in ${binOut}/bin" >&2
                exit 1
              fi
              # Mirror share/man into the result tree (the ZIP is the canonical copy;
              # this is redundant but preserved for tooling).
              if [ -d "${manOut}/share/man" ]; then
                mkdir -p "$out/share"
                cp -R "${manOut}/share/man" "$out/share/man"
                chmod -R u+w "$out/share/man"
              fi

              ${unpinEmbedSh}
              __unpin_stage="$(mktemp -d)"

              # aliases: explicit list, else harvest sibling symlinks of the
              # primary. Sets $__unpin_al for the shared stage snippet to write.
              ${if hasExplicitAliases then ''
              __unpin_al='${explicitCsv}'
              '' else ''
              __unpin_al=""
              if [ -d "${binOut}/bin" ]; then
                for f in "${binOut}/bin"/*; do
                  [ -L "$f" ] || continue
                  __unpin_n="$(basename "$f")"
                  [ "$__unpin_n" = "${primary}" ] && continue
                  __unpin_al="''${__unpin_al:+$__unpin_al,}$__unpin_n"
                done
              fi
              ''}
              # Stage runtime tree + aliases + man into $__unpin_stage. The man
              # candidates are RESOLVED STORE PATHS (manOut/binOut/outOut),
              # unlike the in-build path's build-env output vars.
              ${unpinStageSh {
                tag = "unpinEmbedWrap";
                manEnabled = man;
                inherit manRoot manFallback runtimeStage;
                manCandidates = [ ''"${manOut}"'' ''"${binOut}"'' ''"${outOut}"'' ];
              }}

              if [ -n "$(find "$__unpin_stage" -mindepth 1 \( -type f -o -type l \) -print -quit)" ]; then
                for __unpin_b in "''${__unpin_bins[@]}"; do
                  __unpin_embed_subtree "$__unpin_b" "$__unpin_stage"
                done
              fi
              rm -rf "$__unpin_stage"
              ${nixpkgs.lib.optionalString cosmoSymtabTrim ''
              # cosmo only: drop the unused .symtab.amd64 ZIP member (stdenv strip
              # can't reach a ZIP entry; zip -d removes just it, preserving the APE).
              for __unpin_b in "''${__unpin_bins[@]}"; do
                if unzip -Z1 "$__unpin_b" 2>/dev/null | grep -xF '.symtab.amd64' >/dev/null; then
                  zip -d "$__unpin_b" .symtab.amd64 >/dev/null
                fi
              done
              ''}
            '';

        # Drop Cosmopolitan's `.symtab.amd64` (apelink's crash-backtrace symtab,
        # ~30-80 KB, unused at runtime) from a cosmo APE's tail-ZIP — stdenv strip
        # can't reach a ZIP member. `zip -d` removes just it, preserving the PE
        # prefix, `.cosmo`, zoneinfo and our `unpin/*` entries. No-op on mingw PE.
        # Apply AFTER withMan.
        withCosmoStrip = pkgs: { primary }: drv:
          let
            binOutputName =
              let outs = drv.outputs or [ "out" ];
              in
              if builtins.elem "bin" outs then "bin"
              else if builtins.elem "out" outs then "out"
              else builtins.head outs;
          in
          drv.overrideAttrs (old: {
            nativeBuildInputs = (old.nativeBuildInputs or [ ])
              ++ [ pkgs.buildPackages.zip pkgs.buildPackages.unzip ];
            postFixup = (old.postFixup or "") + ''
              __unpin_cs="''${${binOutputName}}/bin/${primary}"
              if [ ! -f "$__unpin_cs" ] && [ -f "$__unpin_cs.exe" ]; then
                __unpin_cs="$__unpin_cs.exe"
              fi
              # `grep -xF` *without* -q on purpose: nixpkgs' build shell runs
              # with `set -o pipefail`, and `grep -q` exits on the first match
              # → SIGPIPE to `unzip` → the pipeline reports failure even when
              # the entry IS present. Reading to EOF sidesteps that.
              if [ -f "$__unpin_cs" ] \
                 && unzip -Z1 "$__unpin_cs" 2>/dev/null | grep -xF '.symtab.amd64' >/dev/null; then
                zip -d "$__unpin_cs" .symtab.amd64 >/dev/null
              fi
            '';
          });

        # Recipe-A multicall dispatcher generator (the `ld -r` family:
        # e2fsprogs/util-linux/shadow/findutils/procps-ng). The caller writes
        # `multicall/applets.list` as a TSV (the NAME→FUNCTION table is
        # many-to-one, so the symbol can't be derived from the applet name):
        #
        #     <applet-name>\t<fn-base>      (the C symbol is <fn-base>_main)
        #
        # Aliases are extra rows at the same <fn-base>. Dispatch contract: an
        # alias symlink (base != canon, matching an applet) runs via argv[0] and
        # ignores `--unpin-program`; the canonical name (or a renamed copy) selects
        # via `--unpin-program=NAME` first arg. `copy_basename` strips a `/`/`\\`
        # dir prefix (`\\` unconditional — cosmo APE argv[0] carries it and
        # `_WIN32` isn't defined for cosmo), a trailing `.exe`, and a `lt-` prefix.
        #
        # Optional `defaultApplet` (a <fn-base>): a bare invocation runs it instead
        # of printing usage (procps-ng → ps). See docs/multicall.md.
        #
        # Applets are called `fn(argc, argv, environ)` — the THREE-arg main form.
        # bash declares main(argc,argv,env) and reads env from the 3rd arg; a
        # 2-arg call leaves it a garbage register → SIGSEGV. Passing environ is
        # ABI-safe for 2-arg mains (they ignore the extra register). The LTO path
        # interposes a 3-arg trampoline that forwards all three.
        multicallTableDispatcherC = { name, defaultApplet ? null }:
          let
            fallbackC =
              if defaultApplet == null
              then ''    if (argc < 2) { list_programs(stdout); return 0; }
    if (!strcmp(argv[1], "--help") || !strcmp(argv[1], "-h") || !strcmp(argv[1], "help")) {
        list_programs(stdout); return 0;
    }
    fprintf(stderr, "${name}: select a program with --unpin-program=<name>. Available:");
    for (const struct applet *a = applets; a->name; a++)
        fprintf(stderr, "%s%s", a == applets ? " " : ", ", a->name);
    fprintf(stderr, "\n");
    return 1;''
              else ''    (void)list_programs;  /* defaultApplet replaces the listing fallback */
    return ${defaultApplet}_main(argc, argv, environ);'';
          in
          ''
      {
        echo '#include <string.h>'
        echo '#include <stdio.h>'
        echo '#include <strings.h>'
        # mingw-w64 makes `environ` a macro `(*__p__environ())` declared in
        # <stdlib.h>, NOT a linkable global — a bare `extern char **environ;`
        # compiles but leaves an undefined `environ` at link. So pull the header
        # on _WIN32 (mingw) and keep the extern elsewhere: cosmo (no _WIN32) and
        # linux/musl both expose `environ` as a real global.
        echo '#ifdef _WIN32'
        echo '#include <stdlib.h>'
        echo '#else'
        echo 'extern char **environ;'
        echo '#endif'
        # Force C linkage: a `requires.cxx` module links this dispatcher with $CXX,
        # which would mangle these forward declarations and miss the trampolines'
        # C-linkage `unpin__<pkg>__<prog>_main` symbols.
        echo '#ifdef __cplusplus'
        echo 'extern "C" {'
        echo '#endif'
        while IFS="$(printf '\t')" read -r tool san; do
          [ -n "$tool" ] || continue
          echo "int ''${san}_main(int, char **, char **);"
        done < multicall/applets.list
        echo '#ifdef __cplusplus'
        echo '}'
        echo '#endif'
        echo 'struct applet { const char *name; int (*fn)(int, char **, char **); };'
        echo 'static const struct applet applets[] = {'
        while IFS="$(printf '\t')" read -r tool san; do
          [ -n "$tool" ] || continue
          printf '    {"%s", %s_main},\n' "$tool" "$san"
        done < multicall/applets.list
        cat <<'CBODY'
    {0, 0}
};
static void copy_basename(char *dst, size_t cap, const char *src) {
    const char *p = src, *s;
    s = strrchr(p, '/');  if (s) p = s + 1;
    s = strrchr(p, '\\'); if (s) p = s + 1;   /* unconditional: cosmo APE argv[0] */
    size_t n = strlen(p); if (n >= cap) n = cap - 1;
    memcpy(dst, p, n); dst[n] = 0;
    if (n > 4 && strcasecmp(dst + n - 4, ".exe") == 0) dst[n - 4] = 0;
    if (strncmp(dst, "lt-", 3) == 0) memmove(dst, dst + 3, strlen(dst + 3) + 1);
}
CBODY
        cat <<CBODY
static void list_programs(FILE *out) {
    fprintf(out, "${name} is one binary with several programs:");
    for (const struct applet *a = applets; a->name; a++)
        fprintf(out, "%s%s", a == applets ? " " : ", ", a->name);
    fprintf(out, "\nRun one: ${name} --unpin-program=<program> [args...]\n");
}
int main(int argc, char **argv) {
    char base[256];
    const char *a0 = (argc > 0 && argv[0]) ? argv[0] : "${name}";
    copy_basename(base, sizeof base, a0);
    int is_canon = strcmp(base, "${name}") == 0;
    /* Alias path: a symlink whose basename is an applet (and not the canonical
       binary "${name}") -> run that applet via argv[0]. --unpin-program is
       deliberately NOT honored here, locking an alias to its argv[0] identity. */
    if (!is_canon)
        for (const struct applet *a = applets; a->name; a++)
            if (strcmp(base, a->name) == 0) return a->fn(argc, argv, environ);
    /* Multitool path: the canonical name "${name}" or a renamed copy. Select
       the applet explicitly with the first argument --unpin-program=NAME. */
    if (argc >= 2 && strncmp(argv[1], "--unpin-program=", 16) == 0) {
        const char *sel = argv[1] + 16;
        for (const struct applet *a = applets; a->name; a++)
            if (strcmp(sel, a->name) == 0) {
                argv[1] = (char *)sel;   /* applet's argv[0]=NAME, args follow */
                return a->fn(argc - 1, argv + 1, environ);
            }
        fprintf(stderr, "${name}: no program '%s'\n", sel);
        return 1;
    }
    /* The canonical name when it is itself an applet runs that applet bare. */
    if (is_canon)
        for (const struct applet *a = applets; a->name; a++)
            if (strcmp(base, a->name) == 0) return a->fn(argc, argv, environ);
${fallbackC}
}
CBODY
      } > multicall/dispatcher.c'';

        # ── Multicall MODULE artifact (the `.a`-generation scheme) ──────────
        # Add a `module` output carrying a self-describing multicall module:
        # `module.a` (the package's objects, `main`→`unpin__<pkg>__<prog>_main`,
        # every other defined global namespaced) plus the package's PRIVATE
        # bundled archives (gnulib) with their callbacks rewritten to the
        # namespaced names. Produced by `objcopy --redefine-syms` over the
        # already-compiled objects — no recompile, rides the shipped binary's
        # builder.
        #
        # The manifest (applets/depArchives/requires) is assembled by the caller
        # (mkStandaloneFlake's `multicall` arg, attached as
        # passthru.multicallModule); mkMegaMulticall links N modules into one
        # binary. A PRIVATE bundled lib (gnulib: `internalArchives`, callbacks
        # namespaced but own defs untouched so they stay dedupable) is
        # distinguished from a CLEAN external dep (`depArchives`, never touched,
        # deduped at mega-link). Linux native only for now. See docs/multicall.md.
        multicallModuleHook =
          { package                 # "grep" — namespace component
          , programs                # [ { name; objs = [ "src/x.o" ]; } ]
          , internalArchives ? [ ]  # builddir-relative private .a (gnulib)
          , isTargetDarwin ? false
          }: drv:
          let
            san = n: nixpkgs.lib.replaceStrings [ "." "-" "+" ] [ "_" "_" "_" ] n;
            pfxOf = p: "unpin__${san package}__${san p.name}";
            emitRedef = p: ''
              {
                echo "main ${pfxOf p}_main"
                $NM --defined-only -g ${nixpkgs.lib.concatStringsSep " " p.objs} 2>/dev/null \
                  | awk -v t="${pfxOf p}" -v strip=${if isTargetDarwin then "1" else "0"} '
                      $2 ~ /^[TBDRWVCS]$/ {
                        sym = $3
                        if (strip && sym ~ /^_/) sym = substr(sym, 2)
                        if (sym ~ /^[A-Za-z_][A-Za-z0-9_]*$/ && sym != "main" && !seen[sym]++)
                          print sym " " t "__" sym
                      }'
              } > multicall/${san p.name}.redef
            '';
            # Per-program: rename the program's own objects with its own map.
            renameObjs = p: ''
              ${nixpkgs.lib.concatMapStringsSep "\n"
                  (o: ''$OBJCOPY --redefine-syms=multicall/${san p.name}.redef "${o}" "multicall/objs/${san p.name}_$(echo '${o}' | tr / _)"'')
                  p.objs}
            '';
          in
          drv.overrideAttrs (old: {
            outputs = (old.outputs or [ "out" ]) ++ [ "module" ];
            postBuild = (old.postBuild or "") + ''
              set -e
              mkdir -p multicall/objs
              ${nixpkgs.lib.concatMapStringsSep "\n" emitRedef programs}
              ${nixpkgs.lib.concatMapStringsSep "\n" renameObjs programs}
              mkdir -p "$module/lib"
              $AR rcs "$module/lib/module.a" multicall/objs/*.o
              # Union map for the private bundled archives: rewrites their
              # callbacks into the program (gnulib dfa.o -> dfaerror, …) to the
              # namespaced names. gnulib's OWN defs aren't in the map -> untouched.
              cat multicall/*.redef > multicall/all.redef
              ${nixpkgs.lib.concatMapStringsSep "\n"
                  (a: ''
                    cp "${a}" "$module/lib/$(basename ${a})"
                    chmod +w "$module/lib/$(basename ${a})"
                    $OBJCOPY --redefine-syms=multicall/all.redef "$module/lib/$(basename ${a})"
                  '')
                  internalArchives}
            '';
          });

        # Bitcode-LTO variant of multicallModuleHook for engine = "unpin-llvm".
        # The adapter compiled every object as LLVM BITCODE, so objcopy
        # --redefine-syms can't apply (llvm-objcopy refuses bitcode). Per program:
        #
        #   1. a tiny trampoline `unpin__<pkg>__<prog>_main` calls the program's
        #      `main` (only the trampoline is compiled; bitcode objs used as-is);
        #   2. a REAL linker (`ld.lld -r --lto-emit-llvm`, NOT llvm-link) folds the
        #      program's bitcode objs + trampoline + PRIVATE internalArchives into
        #      one bitcode module — lld's on-demand archive pull (first-def dedup +
        #      back-ref resolution) is what llvm-link can't do (see perProgram);
        #   3. `opt -passes=internalize` keeps ONLY the trampoline entry external,
        #      localizing everything else (incl. the real `main`, which LLVM 21's
        #      new-PM InternalizePass does NOT auto-preserve) so two programs'
        #      same-named statics can't collide at the mega-link.
        #
        # The per-program modules are llvm-link'd into one module.bc (colliding
        # internals auto-renamed, external entries stay distinct). CLEAN external
        # depArchives stay external in the manifest, deduped at the mega-link
        # (which is -flto -fuse-ld=lld for whole-program LTO). Linux-native only.
        # Needs llvm-link + opt from the vendored `llvm` (toolchain Patch 4),
        # passed as `llvm` = "${toolchain}/bin/llvm".
        multicallModuleHookLTO =
          { package                 # "grep" — namespace component
          , programs                # [ { name; objs = [ "src/x.o" ]; } ]
          , internalArchives ? [ ]  # builddir-relative private .a (gnulib, bitcode)
          , llvm                    # "${toolchain}/bin/llvm" (has llvm-link + opt)
          , inferLinkInputs ? true  # read objs + local .a from the capture sidecar
                                    # ($UNPIN_LINK_DIR/<prog>.link) instead of the
                                    # hand-listed objs/internalArchives
          , stripDllexport ? false  # mingw: strip __declspec(dllexport) before
                                    # internalize (see stripStep) — off elsewhere
          }: drv:
          let
            san = n: nixpkgs.lib.replaceStrings [ "." "-" "+" ] [ "_" "_" "_" ] n;
            entryOf = p: "unpin__${san package}__${san p.name}_main";
            spaceSep = nixpkgs.lib.concatStringsSep " ";
            # Fold the program's bitcode objs + trampoline + PRIVATE archives
            # into one module with a REAL linker (ld.lld -r), not llvm-link.
            # llvm-link has no archive semantics: it whole-loads (duplicate strong
            # defs — coreutils' libsinglebin_*.a each carry blake2b-ref.o →
            # "multiply defined") or, with --only-needed, a single left-to-right
            # pass that can't satisfy cross-archive back-references. lld pulls
            # members on demand, first-def-wins dedup, resolves back-refs by
            # default — the native single-binary link. `-r` keeps libc/dep symbols
            # undefined for the mega-link; `--lto-emit-llvm` writes bitcode (not
            # codegen) so the cross-module LTO chain stays intact. Then opt
            # internalizes everything but the entry.
            perProgram = p:
              let
                linkBc = "multicall/link_${san p.name}.bc";
                infer = inferLinkInputs && (p.objs or null) == null;
                # dedup LOCALA: a gnulib archive double-listed for circular refs
                # folds to one — lld -r resolves back-references without it.
                inferSetup = ''
                  __side="$UNPIN_LINK_DIR/${p.name}.link"
                  [ -f "$__side" ] || { echo "multicallModuleHookLTO: no link sidecar for ${p.name} ($__side)" >&2; exit 1; }
                  __objs=$(awk '$1=="OBJ"{print $2}' "$__side")
                  __arch=$(awk '$1=="LOCALA"{print $2}' "$__side" | awk '!seen[$0]++')
                  [ -n "$__objs" ] || { echo "multicallModuleHookLTO: sidecar for ${p.name} has no objects" >&2; exit 1; }
                '';
                linkLine =
                  if infer
                  then ''${llvm} ld.lld -r $__objs multicall/tramp_${san p.name}.bc $__arch \
                  --lto-emit-llvm -o ${linkBc}''
                  else ''${llvm} ld.lld -r ${spaceSep (p.objs or [ ])} multicall/tramp_${san p.name}.bc ${spaceSep internalArchives} \
                  --lto-emit-llvm -o ${linkBc}'';
                # SIMD/asm rescue: native ELF objects (NASM/yasm asm) can't live in
                # a .bc, so --lto-emit-llvm silently drops them and their symbols go
                # undefined at the mega-link. Carry them out-of-band in a per-module
                # `module_native.a` the mega links alongside module.bc, keeping SIMD
                # on without a per-package SIMD-off. _unpin_collect (in postBuild)
                # classifies inputs by magic and archives the native ones.
                natCollect =
                  if infer
                  then ''_unpin_collect "$module/lib/module_native.a" $__objs $__arch''
                  else ''_unpin_collect "$module/lib/module_native.a" ${spaceSep (p.objs or [ ])} ${spaceSep internalArchives}'';
                # Just the program OBJECTS (no archives) — used to decide which
                # asm-referenced symbols must be kept external (see body). A symbol
                # an asm object references is kept external ONLY if it's defined in
                # an own object (gzip's deflate.o → window: lives solely in
                # module.bc, so internalize orphans the asm). Symbols that come from
                # an archive (xz's lzma_crc32_table, in liblzma.a) are left
                # internalized: the same archive is also an external depArchive at
                # the mega-link, so the asm resolves there — keeping module.bc's
                # copy external instead would duplicate it (ld.lld: duplicate
                # symbol). Restricting to objects fixes gzip and is a no-op for xz.
                progObjs =
                  if infer then "$__objs" else "${spaceSep (p.objs or [ ])}";
                # mingw compiles a package's public API (and the gnulib getline/
                # getdelim it ships) with __declspec(dllexport). opt -internalize
                # PRESERVES dllexport symbols by design (they are a DLL's export
                # table), so on mingw they would survive as defined externals and
                # collide across the mega — every gnulib package exports `getline`.
                # Nothing is a DLL here (we fold into one static binary), so strip
                # the storage class from the merged module before internalize; the
                # result matches the Linux module's single external. No-op on
                # Linux (visibility("default"), which internalize already lowers),
                # so this is gated to the mingw module path. The dllstorageclass is
                # always grammar at the HEAD of a def/global line (before any
                # operand), so strip ` dllexport ` only in each line's prefix up to
                # its first `"` — never inside a c"..." constant whose bytes happen
                # to spell " dllexport " (a blunt global substitution would corrupt
                # such a literal).
                internalizeIn = if stripDllexport then "${linkBc}.ll" else linkBc;
                stripStep = nixpkgs.lib.optionalString stripDllexport ''
                  ${llvm} opt ${linkBc} -S -o ${linkBc}.ll
                  awk '{ q=index($0,"\""); if(q){h=substr($0,1,q-1); gsub(/ dllexport /," ",h); print h substr($0,q)} else {gsub(/ dllexport /," "); print} }' \
                    ${linkBc}.ll > ${linkBc}.ll.stripped
                  mv ${linkBc}.ll.stripped ${linkBc}.ll
                '';
              in
              ''
                # 3-arg trampoline: forwards argc/argv/env so a 3-arg main (bash:
                # main(argc,argv,env), reads env from the 3rd arg) gets its
                # environment. 2-arg mains (grep/sed/coreutils) declare main with
                # 2 params — calling main(c,v,e) passes one extra arg the callee
                # ignores (ABI-safe; LTO resolves the type mismatch via bitcast,
                # same as the dispatcher→entry call). A 2-arg trampoline instead
                # dropped env → a 3-arg main received NULL (verified) → SIGSEGV.
                printf 'extern int main(int,char**,char**);\nint %s(int c,char**v,char**e){return main(c,v,e);}\n' \
                  '${entryOf p}' > multicall/tramp_${san p.name}.c
                $CC -flto -O2 -c multicall/tramp_${san p.name}.c -o multicall/tramp_${san p.name}.bc
                ${nixpkgs.lib.optionalString infer inferSetup}
                ${linkLine}
                ${natCollect}
                # asm→bitcode rescue (the reverse of the SIMD case above): a native
                # object (e.g. gzip's i386 match.o) may REFERENCE a global DEFINED in
                # one of this program's own objects (deflate.c's window/strstart/…,
                # which then live solely in module.bc). The default keep-list is just
                # the entry trampoline, so opt -internalize makes those globals local
                # → the native object goes undefined at the mega-link. Preserve them
                # by adding `undefined(module_native.a) ∩ defined(progObjs)` to the
                # keep-list. Restricted to OWN OBJECTS (not archives) so xz's
                # lzma_crc32_table — which comes from liblzma.a and is also an
                # external depArchive at the mega — is left internalized and resolved
                # there (keeping it external would duplicate it). Empty — hence
                # byte-identical — for self-contained asm (zstd, whose asm only
                # DEFINES symbols) and asm-free packages; natCollect above is
                # unchanged, so module_native.a stays byte-identical too. Single-
                # program packages only isolate cleanly here (the shared archive ==
                # this program's natives); all catalog asm packages are single-prog.
                keeplist='${entryOf p}'
                if ${llvm} llvm-ar t "$module/lib/module_native.a" >/dev/null 2>&1 \
                   && [ -n "$(${llvm} llvm-ar t "$module/lib/module_native.a" 2>/dev/null)" ]; then
                  ${llvm} llvm-nm --undefined-only "$module/lib/module_native.a" 2>/dev/null \
                    | awk '$1=="U"{print $2}' | sort -u > multicall/nat_${san p.name}.u
                  # defined externals of the OWN OBJECTS only (skip the "file:"
                  # headers llvm-nm prints when handed several files).
                  ${llvm} llvm-nm --defined-only --extern-only ${progObjs} 2>/dev/null \
                    | awk '$NF ~ /:$/ {next} {print $NF}' | sort -u > multicall/obj_${san p.name}.d
                  __extra=$(comm -12 multicall/nat_${san p.name}.u multicall/obj_${san p.name}.d)
                  for __s in $__extra; do keeplist="$keeplist,$__s"; done
                  [ -n "$__extra" ] && echo "multicall(${p.name}): keeping asm-referenced bitcode syms external:" $__extra >&2 || true
                fi
                ${stripStep}
                ${llvm} opt -passes=internalize -internalize-public-api-list="$keeplist" \
                  ${internalizeIn} -o multicall/mod_${san p.name}.bc
              '';
          in
          drv.overrideAttrs (old: {
            outputs = (old.outputs or [ "out" ]) ++ [ "module" ];
            # `or ""` only catches a MISSING attr, not a literal `null` (some
            # nixpkgs recipes set postBuild = null, e.g. lua5_4) — coerce null too.
            postBuild = (if (old.postBuild or null) == null then "" else old.postBuild) + ''
              set -e
              mkdir -p multicall "$module/lib"
              # surface the capture sidecars for inspection
              if [ -d "''${UNPIN_LINK_DIR:-/nonexistent}" ]; then
                mkdir -p "$module/links"
                cp "$UNPIN_LINK_DIR"/*.link "$module/links/" 2>/dev/null || true
              fi
              # native-object rescue helpers (see natCollect). Classify by leading
              # magic: bitcode (4243c0de) or its wrapper (dec0170b) already rode
              # into module.bc; anything else is a native object to rescue.
              _unpin_natkind() {
                case "$(od -An -tx1 -N4 "$1" 2>/dev/null | tr -d ' \n')" in
                  4243c0de|dec0170b) echo bc ;;
                  *) echo native ;;
                esac
              }
              _unpin_collect() {
                __nat="$1"; shift
                for __i in "$@"; do
                  [ -e "$__i" ] || continue
                  case "$__i" in
                    *.a)
                      # split a (possibly mixed) archive: archive only its native
                      # members; the bitcode members already rode into module.bc
                      # via the ld.lld -r link. Copy in first so a relative archive
                      # path survives the cd into the extraction dir.
                      __td=$(mktemp -d)
                      cp "$__i" "$__td/in.a" || { rm -rf "$__td"; continue; }
                      mkdir -p "$__td/x"
                      ( cd "$__td/x" && ${llvm} llvm-ar x "$__td/in.a" ) || { rm -rf "$__td"; continue; }
                      for __m in "$__td"/x/*; do
                        [ -f "$__m" ] || continue
                        # NB: must be if/then (not `[ ] && cmd`) — under set -e a
                        # bare `[ ] && cmd` whose test is false returns non-zero and
                        # aborts the whole postBuild silently.
                        if [ "$(_unpin_natkind "$__m")" = native ]; then
                          ${llvm} llvm-ar qc "$__nat" "$__m"
                        fi
                      done
                      rm -rf "$__td"
                      ;;
                    *)
                      if [ "$(_unpin_natkind "$__i")" = native ]; then
                        ${llvm} llvm-ar qc "$__nat" "$__i"
                      fi
                      ;;
                  esac
                done
              }
              ${nixpkgs.lib.concatMapStringsSep "\n" perProgram programs}
              # always materialize module_native.a (empty archive if no asm) so the
              # manifest path is stable and the mega-link can reference it
              # unconditionally; an empty archive links to nothing.
              if [ -f "$module/lib/module_native.a" ]; then
                ${llvm} llvm-ar s "$module/lib/module_native.a"
              else
                ${llvm} llvm-ar rc "$module/lib/module_native.a"
              fi
              ${llvm} llvm-link ${spaceSep (map (p: "multicall/mod_${san p.name}.bc") programs)} \
                -o "$module/lib/module.bc"
            '';
          });

        # Cosmo (APE) multicall MODULE emitter for engine = "cosmocc". ld.lld
        # won't link cosmo objects (the IFUNC/IPLT wall), so the cosmo mega-link
        # is NATIVE through cosmocc + ld.bfd + apelink and the module carries
        # plain renamed ELF objects (cosmo objects are ELF before apelink, so
        # objcopy --redefine-syms applies directly).
        #
        # FULL per-package namespacing (stronger than the per-program scheme):
        # every defined global across objs AND the package's archives is renamed
        # `unpin__<pkg>__<sym>` (`main` → the entry), so internal references stay
        # resolved while libc's undefined symbols are untouched — every package is
        # hermetic, no reliance on archive-member dedup (which the cosmo native
        # link can't guarantee — cf. the "blake2 multiply defined" LTO failure).
        #
        # Three staged buckets preserve the NATIVE link order at the mega-link:
        #   objs/    program objects, linked DIRECT, so an object that overrides
        #            an archive symbol (csplit.o's xalloc_die) wins first;
        #   applet/  per-applet archives, scanned BEFORE gnulib so the override is
        #            satisfied from the applet object, not gnulib's default;
        #   gnulib/  the private bundled archive(s), scanned AFTER applets.
        # Single-program packages only.
        multicallModuleHookCosmo =
          { package                  # "bash" — namespace component
          , program                  # single program; entry = unpin__<pkg>__<prog>_main
          , programObjs              # builddir-relative .o (DIRECT at mega-link)
          , appletArchives ? [ ]     # builddir-relative .a, scanned BEFORE gnulib
          , gnulibArchives ? [ ]     # builddir-relative .a (gnulib), scanned AFTER
          }: drv:
          let
            san = n: nixpkgs.lib.replaceStrings [ "." "-" "+" ] [ "_" "_" "_" ] n;
            pfx = "unpin__${san package}__";
            entry = "${pfx}${san program}_main";
            sp = nixpkgs.lib.concatStringsSep " ";
          in
          drv.overrideAttrs (old: {
            outputs = (old.outputs or [ "out" ]) ++ [ "module" ];
            postBuild = (old.postBuild or "") + ''
              set -e
              mkdir -p multicall "$module/objs" "$module/applet" "$module/gnulib"
              progobjs="${sp programObjs}"
              ag="${sp appletArchives}"; gg="${sp gnulibArchives}"
              # nullglob-safe: a bare `ls` with no args lists the cwd, so only
              # run it when the glob list is non-empty.
              applet=$([ -n "$ag" ] && ls $ag 2>/dev/null || true)
              gnulib=$([ -n "$gg" ] && ls $gg 2>/dev/null || true)
              # One redef map over EVERY defined global (objs + both archive
              # buckets): main → the entry, every other global → unpin__<pkg>__.
              {
                echo "main ${entry}"
                $NM --defined-only -g $progobjs $applet $gnulib 2>/dev/null \
                  | awk -v p="${pfx}" '
                      $2 ~ /^[TBDRWVCSiu]$/ {
                        sym = $3
                        if (sym ~ /^[A-Za-z_][A-Za-z0-9_]*$/ && sym != "main" && !seen[sym]++)
                          print sym " " p sym
                      }'
              } > multicall/${san package}.redef
              rename_into() { # $1=destdir ; reads a file list on stdin
                local n=0 a d
                while read -r a; do
                  [ -n "$a" ] || continue
                  d="$1/$(printf '%03d' $n)-$(basename "$a")"
                  cp "$a" "$d"; chmod +w "$d"
                  $OBJCOPY --redefine-syms=multicall/${san package}.redef "$d"; n=$((n+1))
                done
              }
              n=0
              for o in $progobjs; do
                $OBJCOPY --redefine-syms=multicall/${san package}.redef "$o" \
                  "$module/objs/$(printf '%03d' $n)-$(basename "$o")"; n=$((n+1))
              done
              printf '%s\n' $applet | rename_into "$module/applet"
              printf '%s\n' $gnulib | rename_into "$module/gnulib"
              # Self-check that `main` got renamed to the entry. Capture nm into
              # a variable and glob-match it — a `nm | grep -Fq` pipe makes grep
              # exit early, SIGPIPEs nm, and `set -o pipefail` (active in stdenv
              # phases) then fails the pipeline even though the symbol IS present.
              __unpin_syms=$($NM --defined-only -g "$module"/objs/*.o 2>/dev/null || true)
              case "$__unpin_syms" in
                *"${entry}"*) : ;;
                *) echo "multicallModuleHookCosmo: entry ${entry} missing after rename" >&2; exit 1 ;;
              esac
            '';
          });

        # Cross-platform multicall fold (cpp-rename / "X+Z" recipe). A package
        # shipping N sibling programs from one source tree (each its own subdir
        # Makefile, sharing a clean static lib with no callbacks into the
        # programs) folds into ONE binary at bin/<primary>, the others argv[0]
        # aliases.
        #
        # Each program is recompiled with a per-program `-include <p>.rename.h`
        # that renames `main`→<san>_main and namespaces every other defined global
        # behind `<san>__`. Objects stay normal .o (no partial link), so the cross
        # lld's `--gc-sections` is happy (unlike the older ld -r + objcopy fold,
        # which trips i686's linkonce thunks) and the recipe works on ELF, Mach-O
        # (leading-`_` strip) and cosmo APE. Shared static libs (libacl.a) are NOT
        # renamed (called identically by every program), passed via `linkExtra`.
        #
        # Generalized from the per-package mc.nix (acl/psmisc/dosfstools/
        # exfatprogs); bc/e2fsprogs keep bespoke variants (bc's shared number.o
        # calls back into per-program rt_error). See docs/multicall.md.
        cppRenameMulticall =
          { pkgs                    # build-host pkgs (writeText, withAliases)
          , basePkg                 # pkgsStatic.<pkg> (or cosmo/mingw pkg) to override
          , primary                 # bin/<primary> is the real binary (== package name)
          , programs                # [ { name; buildDir ? makeSubdir; objs = [ "rel/obj.o" … ]; } ]
          , aliases ? [ ]           # [ { name; target; } ]  extra dispatch names (symlink only)
          , makeSubdir ? "."        # dir whose Makefile defines $(LINK) + the lib vars
          , linkExtra ? ""          # shared static libs / automake lib vars for the final link
          , extraInstall ? ""       # raw shell appended to installPhase (man pages)
          , isTargetDarwin ? false  # Mach-O: strip leading `_`, include `S`-type symbols
          , isCosmo ? false         # Windows APE: no applet symlinks; explicit alias list
          , isWindows ? false       # mingw PE: bin/<pkg>.exe, embedded aliases (no symlinks)
          }:
          let
            san = name: nixpkgs.lib.replaceStrings [ "." "-" "+" ] [ "_" "_" "_" ] name;
            # Windows (mingw or cosmo) ships one .exe with the applet names
            # embedded as aliases — no in-store symlinks. mingw x86_64 keeps the
            # --start-group/-lgcc (no Mach-O/APE constraints; libgcc is present);
            # only darwin+cosmo drop it.
            isWin = isCosmo || isWindows;
            exe = nixpkgs.lib.optionalString isWin ".exe";
            # The cosmo cross stdenv's apelink fixup hook converts an ELF in
            # $out/bin to an APE and renames it `<name>.exe` — but ONLY if it
            # isn't already `.exe`. So for cosmo we install the staged binary
            # WITHOUT the extension and let the hook add it; mingw has no such
            # hook, so we name it `.exe` ourselves. Native keeps the bare name.
            installExe = nixpkgs.lib.optionalString isWindows ".exe";
            installName = "${primary}${installExe}";
            outName = "${primary}${exe}";
            noGroup = isTargetDarwin || isCosmo;
            groupOpen = if noGroup then "" else "-Wl,--start-group";
            groupClose = if noGroup then "" else "-Wl,--end-group";
            libgcc = if noGroup then "" else "-lgcc";

            appletLines =
              (map (p: "${p.name}\t${san p.name}") programs)
              ++ (map (a: "${a.name}\t${san a.target}") aliases);

            # Phase A: discover defined globals per program (canonical names,
            # before any recompile) and emit the rename header.
            renameHeader = p: ''
              {
                echo "/* multicall rename header: ${p.name} */"
                echo "#define main ${san p.name}_main"
                $NM --defined-only -g ${nixpkgs.lib.concatStringsSep " " p.objs} 2>/dev/null \
                  | awk -v t="${san p.name}" -v strip=${if isTargetDarwin then "1" else "0"} '
                      $2 ~ /^[TBDRWVCS]$/ {
                        sym = $3
                        if (strip && sym ~ /^_/) sym = substr(sym, 2)
                        if (sym ~ /^[A-Za-z_][A-Za-z0-9_]*$/ && sym != "main" && !seen[sym]++)
                          print "#define " sym " " t "__" sym
                      }'
              } > multicall/${san p.name}.rename.h
            '';

            # Phase B: rm the program's objects, recompile them with the rename
            # header `-include`d (reusing automake's exact per-target flags via
            # `make`), then copy the freshly-renamed .o into multicall/obj_<p>/
            # before the next program's rebuild can clobber a shared source path.
            rebuild = p:
              let
                dir = p.buildDir or makeSubdir;
                prefix = if dir == "." then "" else "${dir}/";
                targets = map (o: nixpkgs.lib.removePrefix prefix o) p.objs;
              in ''
                rm -f ${nixpkgs.lib.concatStringsSep " " p.objs}
                make -C ${dir} -j''${NIX_BUILD_CORES:-1} ${nixpkgs.lib.concatStringsSep " " targets} \
                  NIX_CFLAGS_COMPILE="$_orig_NIX_CFLAGS_COMPILE -include $PWD/multicall/${san p.name}.rename.h"
                mkdir -p multicall/obj_${san p.name}
                ${nixpkgs.lib.concatMapStringsSep "\n      "
                    (o: ''cp "${o}" "multicall/obj_${san p.name}/$(echo '${o}' | tr / _)"'')
                    p.objs}
              '';

            multicallMk = pkgs.writeText "unpin-multicall.mk" ''
              # Recursive-automake Makefiles define top_builddir per subdir
              # (e.g. exfatprogs' mkfs/Makefile → `..`); flat ones (mtools) leave
              # it unset, which would make the paths below absolute (`/multicall`).
              # `?=` defaults it to the make -C dir without overriding a real one.
              top_builddir ?= .
              MULTI_OUT ?= $(top_builddir)/multicall/${primary}
              .PHONY: multicall-link
              multicall-link: $(MULTI_OUT)
              $(MULTI_OUT): $(top_builddir)/multicall/dispatcher.o
              	# Explicit `-o`: automake's $(LINK) bakes in `-o $@`, but flat
              	# Makefiles (mtools) define LINK without it and add `-o $@`
              	# per-rule, so name the output here. A duplicate `-o` (automake)
              	# is harmless — the last one wins, same value.
              	$(LINK) -o $(MULTI_OUT) $(top_builddir)/multicall/dispatcher.o $(top_builddir)/multicall/obj_*/*.o \
              		${groupOpen} ${linkExtra} $(LIBS) ${libgcc} ${groupClose}
            '';

            binSymlinks =
              (map (p: p.name) (nixpkgs.lib.filter (p: p.name != primary) programs))
              ++ (map (a: a.name) aliases);

            multicall = basePkg.overrideAttrs (old: {
              pname = "${old.pname or "pkg"}-multi";
              doCheck = false;
              outputs = [ "out" ];

              postBuild = (old.postBuild or "") + ''
                set -e
                mkdir -p multicall
                _orig_NIX_CFLAGS_COMPILE=''${NIX_CFLAGS_COMPILE:-}

                # Phase A: discovery
                ${nixpkgs.lib.concatMapStringsSep "\n" renameHeader programs}
                # Phase B: recompile + isolate
                ${nixpkgs.lib.concatMapStringsSep "\n" rebuild programs}

                printf '${nixpkgs.lib.concatStringsSep "\\n" appletLines}\n' > multicall/applets.list
              ${multicallTableDispatcherC { name = primary; defaultApplet = null; }}
                $CC -O2 -c -o multicall/dispatcher.o multicall/dispatcher.c

                install -m644 ${multicallMk} ${makeSubdir}/unpin-multicall.mk
                make -C ${makeSubdir} -f Makefile -f unpin-multicall.mk multicall-link
              '';

              installPhase = ''
                runHook preInstall
                mkdir -p "$out/bin"
                install -m755 "multicall/${primary}" "$out/bin/${installName}"
                ${nixpkgs.lib.optionalString (!isWin)
                    (nixpkgs.lib.concatMapStringsSep "\n      " (n: ''ln -s "${primary}" "$out/bin/${n}"'') binSymlinks)}
                ${extraInstall}
                runHook postInstall
              '';

              postFixup = (old.postFixup or "") + ''
                rm -rf "$out/nix-support"
              '';
            });
          in
          withAliases pkgs
            ({ primary = outName; }
             // (if isWin
                 then { aliases = map (p: p.name) programs ++ map (a: a.name) aliases; }
                 else { aliasesFromSymlinksIn = "bin"; }))
            multicall;

        # The external static archives a multicall build links, derived from the
        # build drv rather than hand-named. Walks the transitive propagated-input
        # closure (+ direct buildInputs) and returns store-path DIRECTORIES — pure
        # strings, no IFD (never readDir at eval time, so evaluating a flake
        # doesn't force its deps). The mega builder globs `<dir>/lib/*.a` at build
        # time. libc/cc are stdenv deps and never appear here; unreferenced
        # archives are inert under archive-link semantics. Reads the FINAL build
        # drv, so an `.override` adding deps (coreutils' acl/attr) is reflected.
        multicallExternalDepDirs = drv:
          let
            isDrv = d: d != null && builtins.isAttrs d && (d ? outPath);
            roots = builtins.filter isDrv
              ((drv.buildInputs or [ ]) ++ (drv.propagatedBuildInputs or [ ]));
            closure = builtins.genericClosure {
              startSet = map (d: { key = d.outPath; val = d; }) roots;
              operator = item: map (d: { key = d.outPath; val = d; })
                (builtins.filter isDrv (item.val.propagatedBuildInputs or [ ]));
            };
            # Emit EVERY output of each dep: the static `.a` may sit in `out`,
            # `lib`, or `dev` depending on the package's output split (pcre2's
            # default output is `dev`, but libpcre2-8.a lives in `out`). The
            # build-time glob picks whichever dir actually has lib/*.a.
            outsOf = d: map (o: "${d.${o}}") (d.outputs or [ "out" ]);
          in nixpkgs.lib.unique (builtins.concatMap (item: outsOf item.val) closure);

        # mkMegaMulticall: fold N package multicall MODULES (the
        # passthru.multicallModule manifests) into ONE busybox-style binary
        # "unpinbox". Each manifest carries:
        #   moduleFormat  "bitcode" (-flto emitter) | "elf-archive" (objcopy)
        #   moduleArchive  store path to module.bc / module.a
        #   depArchives    external clean .a (pcre2, zlib) — passthru store paths
        #   applets        [ { name; entry } ]  entry = unpin__<pkg>__<prog>_main
        #   requires       { cxx; group; … }
        #
        # The dispatcher routes argv[0]-basename or `--unpin-program=NAME` to the
        # matching entry. Bitcode modules link with `clang -flto -fuse-ld=lld`
        # (whole-program LTO); external depArchives passed once, deduped by store
        # path. The link runs through unpinAdapterStdenv so the on-demand musl
        # sysroot is seeded. Applet-name collisions across packages are a HARD
        # error — pass `nameOverrides = { old = new; }`. cppRenameMulticall is the
        # single-package fold; this is the cross-package one. See docs/multicall.md.
        mkMegaMulticall =
          { pkgs
          , name ? "unpinbox"
          , modules                  # [ multicallModule manifest, … ]
          , nameOverrides ? { }      # { oldName = newName; } collision fixes
          , defaultApplet ? null     # applet name to run bare (null = list)
          , toolchain ? unpinToolchain pkgs.stdenv.buildPlatform.system
          , target ? pkgs.pkgsStatic.stdenv.hostPlatform.config
          }:
          let
            renamedName = a: nameOverrides.${a.name} or a.name;
            allApplets = nixpkgs.lib.concatMap
              (m: map (a: { name = renamedName a; inherit (a) entry; }) m.applets)
              modules;
            names = map (a: a.name) allApplets;
            dups = nixpkgs.lib.unique
              (nixpkgs.lib.filter
                (n: builtins.length (nixpkgs.lib.filter (x: x == n) names) > 1) names);
            # The dispatcher emits `<san>_main` for each applet; entry already IS
            # `<san>_main`, so san = entry minus the trailing "_main".
            sanOf = a: nixpkgs.lib.removeSuffix "_main" a.entry;
            appletLines = map (a: "${a.name}\t${sanOf a}") allApplets;
            defaultSan =
              if defaultApplet == null then null
              else
                let m = nixpkgs.lib.findFirst (a: a.name == defaultApplet) null allApplets;
                in if m == null
                   then throw "mkMegaMulticall: defaultApplet '${defaultApplet}' is not an applet of any module"
                   else sanOf m;
            anyBitcode = builtins.any (m: (m.moduleFormat or "elf-archive") == "bitcode") modules;
            # engine = "cosmocc": modules emitted by multicallModuleHookCosmo,
            # linked NATIVELY through cosmocc + apelink (no lld, no adapter).
            cosmoMode = builtins.any (m: (m.moduleFormat or "elf-archive") == "cosmo-elf") modules;
            anyCxx = builtins.any (m: m.requires.cxx or false) modules;
            anyGroup = builtins.any (m: m.requires.group or false) modules;
            moduleArchives = map (m: m.moduleArchive) modules;
            # Native (asm/SIMD) sidecars rescued by the bitcode hook — one per
            # bitcode module, linked in the back-ref group alongside depArchives so
            # the asm code the bitcode module references resolves. null on the
            # cosmo/elf-archive paths (those carry native objects directly).
            nativeArchives = nixpkgs.lib.filter (x: x != null)
              (map (m: m.nativeArchive or null) modules);
            depArchives = nixpkgs.lib.unique
              (nixpkgs.lib.concatMap (m: m.depArchives) modules);
            # Auto-derived external dep dirs. The builder globs <dir>/lib/*.a and
            # skips libc-family archives (the engine/cosmo provides libc; a deep
            # closure surfacing musl's libc.a must not clash with it).
            depInputDirs = nixpkgs.lib.unique
              (nixpkgs.lib.concatMap (m: m.depInputDirs or [ ]) modules);
            # Union of dead-ref scrub patterns across folded modules (see
            # unpinEmbedWrap's removeReferences). Applied to the mega binary.
            removeReferences = nixpkgs.lib.unique
              (nixpkgs.lib.concatMap (m: m.removeReferences or [ ]) modules);
            # Basenames the auto-derive drops from depInputDirs: a deep closure can
            # surface a glibc-style libc split (libc.a + friends) that would clash
            # with the engine/cosmo-provided libc. musl never splits these out, so on
            # the engine (musl) path the list is defensive — EXCEPT `libcrypt.a`,
            # which musl also folds into libc.a, so any `libcrypt.a` in a musl closure
            # is libxcrypt (crypt_gensalt/yescrypt), a real dep some packages (shadow)
            # fold. A module opts its own libcrypt.a back IN via multicall.keepAuto
            # Archives; other folds (tcsh/perl, which use musl's plain crypt) keep the
            # default skip. Union the keeps across modules, subtract from the skip set.
            keptAutoArchives = nixpkgs.lib.unique
              (nixpkgs.lib.concatMap (m: m.keepAutoArchives or [ ]) modules);
            libcSplitArchives = [
              "libc.a" "libm.a" "libpthread.a" "librt.a" "libdl.a"
              "libresolv.a" "libutil.a" "libcrypt.a" "libxnet.a" "libnsl.a"
            ];
            effectiveSkipArchives =
              nixpkgs.lib.subtractLists keptAutoArchives libcSplitArchives;
            # Shell prelude (shared by both builders) that fills a `autodeps`
            # array from depInputDirs, filtering the libc split archives.
            autoDepsPrelude = ''
              autodeps=()
              for d in ${nixpkgs.lib.concatStringsSep " " depInputDirs}; do
                for a in "$d"/lib/*.a; do
                  [ -e "$a" ] || continue
                  case "$(basename "$a")" in
                    ${nixpkgs.lib.concatStringsSep "|" effectiveSkipArchives}) continue ;;
                  esac
                  autodeps+=("$a")
                done
              done
            '';
            face = if anyCxx then "$CXX" else "$CC";
            # A mingw mega links a PE32+; it must be named `<name>.exe` so it runs
            # on Windows and so withAliases/withUnpinEmbed's `.exe` fallback finds
            # it (same as the cosmo path's `${name}.exe`). No-op for every Linux
            # target. Derived from the link `pkgs` host platform.
            isWin = pkgs.stdenv.hostPlatform.isWindows or false;
            binFile = if isWin then "${name}.exe" else name;
            # darwin (Mach-O) mega: ld64 rejects the GNU flags the ELF/PE path
            # uses — `--start-group`/`--end-group` (ld64 resolves back-refs
            # multi-pass, no group needed) and `-s` (ld64's spelling is `-x`). So
            # darwin drops the groups and swaps `-Wl,-s`→`-Wl,-x`. No-op off darwin.
            isDarwinHost = pkgs.stdenv.hostPlatform.isDarwin or false;
            stripLinkFlag = if isDarwinHost then "-Wl,-x" else "-Wl,-s";
            # Bitcode libc: musl's `malloc` is a WEAK alias of the strong
            # `__libc_malloc`. When a mega's modules are NATIVE objects (elf-archive,
            # the cross megas) their references to `malloc` are invisible to the
            # `-flto` link's LTO, so it internalizes/drops the weak `malloc` from the
            # codegen'd libc → `undefined symbol: malloc` at final resolution. (Megas
            # with BITCODE modules — x86_64 native — escape it: LTO sees the use.)
            # `-u malloc` both pulls the defining object AND adds `malloc` to the LTO
            # preserve set so it survives into the output for the native objects to
            # bind. Gate on a linux host (every linux engine mega links the bitcode
            # libc); exclude darwin/windows (libSystem/mingw, no weak-musl-malloc).
            bitcodeLibcForce = nixpkgs.lib.optionalString
              (!isDarwinHost && !pkgs.stdenv.hostPlatform.isWindows)
              "-Wl,-u,malloc ";
            # A group is needed when there is more than one archive to back-ref
            # across — explicit depArchives OR auto-derived dirs both count. Never on
            # darwin (ld64 has no --start-group and doesn't need it).
            needGroup = !isDarwinHost
              && (anyGroup || depArchives != [ ] || depInputDirs != [ ] || nativeArchives != [ ]);
            groupOpen = nixpkgs.lib.optionalString needGroup "-Wl,--start-group";
            groupClose = nixpkgs.lib.optionalString needGroup "-Wl,--end-group";
            # darwin frameworks a folded module references (htop → IOKit /
            # CoreFoundation): the mega relinks from bitcode, so it must name them
            # itself. Union across modules, darwin-only.
            darwinFrameworks = nixpkgs.lib.unique
              (nixpkgs.lib.concatMap (m: (m.requires or { }).frameworks or [ ]) modules);
            # Just the `-framework <each>` flags. The engine adapter already adds
            # `-F <sdk>/.../Frameworks`, `-L <sdk>/usr/lib` and `-lSystem`, so the
            # frameworks (and CoreFoundation's libobjc re-export) resolve from there.
            darwinFrameworkFlags = nixpkgs.lib.optionalString
              (isDarwinHost && darwinFrameworks != [ ])
              (nixpkgs.lib.concatMapStringsSep " " (f: "-framework ${f}") darwinFrameworks);
            adapter = unpinAdapterStdenv {
              inherit pkgs toolchain target;
              # Cross mega: with a cross pkgs the link runs through the cross
              # stdenv (lld cross-links per-arch modules); only the sysroot sanity
              # run is gated off. toolchain stays build-host (clang -target emits
              # the host arch).
              native = pkgs.stdenv.buildPlatform.system == pkgs.stdenv.hostPlatform.system;
              cxx = anyCxx;
              lto = anyBitcode;
            };

            # ── Bitcode/ELF path: one ELF via the unpin-llvm adapter,
            # whole-program LTO across modules with lld. ──
            megaElfDrv = adapter.mkDerivation {
              inherit name;
              dontUnpack = true;
              dontConfigure = true;
              buildPhase = ''
                runHook preBuild
                mkdir -p multicall
                printf '${nixpkgs.lib.concatStringsSep "\\n" appletLines}\n' > multicall/applets.list
                ${multicallTableDispatcherC { inherit name; defaultApplet = defaultSan; }}
                ${autoDepsPrelude}
                # stripLinkFlag (-Wl,-s on ELF/PE, -Wl,-x on Mach-O) strips at link
                # (after LTO codegen bound the entries) — the entries are dead in the
                # symtab once linked, so the shipped binary carries none. The
                # UNPIN_META ZIP is embedded post-link by withAliases, so it survives
                # the strip. Explicit depArchives + auto-derived (autodeps) ride in
                # one group (empty on darwin — ld64 resolves back-refs multi-pass).
                ${face} -fuse-ld=lld ${stripLinkFlag} ${bitcodeLibcForce}-o ${binFile} \
                  multicall/dispatcher.c \
                  ${nixpkgs.lib.concatStringsSep " " moduleArchives} \
                  ${groupOpen} ${nixpkgs.lib.concatStringsSep " " nativeArchives} ${nixpkgs.lib.concatStringsSep " " depArchives} "''${autodeps[@]}" ${groupClose} \
                  ${darwinFrameworkFlags}
                runHook postBuild
              '';
              installPhase = ''
                runHook preInstall
                mkdir -p "$out/bin"
                install -m755 ${binFile} "$out/bin/${binFile}"
                runHook postInstall
              '';
            };

            # ── Cosmo path: native cosmocc link in each package's NATIVE order
            # (objs DIRECT, then applet group, then gnulib group), then apelink to
            # a fat APE + a thin Windows PE32+. cosmo objects can't go through lld. ──
            cosmo = cosmoStdenv pkgs;
            cosmoApelink = "${cosmo.cosmocc}/bin/apelink";
            cosmoVbits = toString cosmo.platformBits.windows;
            cosmoModuleLink = nixpkgs.lib.concatMapStringsSep " \\\n          "
              (m: ''"${m.moduleObjs}"/*.o $(grp "${m.appletDir}") $(grp "${m.gnulibDir}")'')
              modules;
            megaCosmoDrv = cosmo.mkDerivation {
              inherit name;
              dontUnpack = true;
              dontConfigure = true;
              buildPhase = ''
                runHook preBuild
                mkdir -p multicall
                printf '${nixpkgs.lib.concatStringsSep "\\n" appletLines}\n' > multicall/applets.list
                ${multicallTableDispatcherC { inherit name; defaultApplet = defaultSan; }}
                # nullglob-safe per-bucket group: a bucket dir with no archives
                # (e.g. bash has no applet archives) contributes nothing.
                grp() { local f had=0 out="-Wl,--start-group"
                        for f in "$1"/*.a; do [ -e "$f" ] || continue; had=1; out="$out $f"; done
                        [ "$had" = 1 ] && printf -- '%s -Wl,--end-group ' "$out"; }
                ${autoDepsPrelude}
                # explicit depArchives + auto-derived (autodeps) in one group
                alldeps=( ${nixpkgs.lib.concatStringsSep " " depArchives} "''${autodeps[@]}" )
                depgrp=()
                [ "''${#alldeps[@]}" -gt 0 ] && depgrp=( -Wl,--start-group "''${alldeps[@]}" -Wl,--end-group )
                ${face} -O2 -o ${name} multicall/dispatcher.c \
                  ${cosmoModuleLink} \
                  "''${depgrp[@]}"
                ${cosmoApelink} -o ${name}.ape ${name}
                ${cosmoApelink} -V ${cosmoVbits} -o ${name}.exe ${name}
                runHook postBuild
              '';
              installPhase = ''
                runHook preInstall
                mkdir -p "$out/bin"
                install -m755 ${name}.ape "$out/bin/${name}.ape"
                install -m755 ${name}.exe "$out/bin/${name}.exe"
                runHook postInstall
              '';
            };
          in
          assert (dups == [ ]) ||
            throw ("mkMegaMulticall: applet name collision across packages: "
              + nixpkgs.lib.concatStringsSep ", " dups
              + " — pass nameOverrides to rename");
          # ONE post-build embed over the linked mega (unpinEmbedWrap, the same
          # primitive every shipped binary uses). aliases = every applet name except
          # the primary (which IS the binary). Man MERGE: per-package man embeds into
          # each tool's OWN binary, which the mega never ships, so re-stage every
          # folded package's share/man into one tree and embed once over the mega.
          # Same for RUNTIME DATA (file's magic.mgc). The mega binary is already
          # stripped at link (`-Wl,-s` on ELF; cosmo APEs ship unstripped), so the
          # wrap's strip is a no-op (stripCmd = ":"); cosmo emits `${name}.exe`/`.ape`
          # and the wrap embeds into each variant it finds.
          let
            manRoots = nixpkgs.lib.unique
              (nixpkgs.lib.filter (x: x != null) (map (m: m.manRoot or null) modules));
            combinedMan =
              if manRoots == [ ] then null
              else pkgs.buildPackages.runCommand "${name}-man" { } ''
                mkdir -p "$out/share/man"
                for r in ${nixpkgs.lib.concatStringsSep " " manRoots}; do
                  [ -d "$r/share/man" ] || continue
                  # --no-preserve=mode: sources are read-only store paths; without
                  # it the first package's 0555 section dirs would reject the next
                  # package's pages. -L derefs .so-redirect man symlinks.
                  cp -rL --no-preserve=mode "$r/share/man/." "$out/share/man/" 2>/dev/null || true
                done
              '';
            rtRoots = nixpkgs.lib.unique
              (nixpkgs.lib.filter (x: x != null) (map (m: m.runtimeDataRoot or null) modules));
            combinedRt =
              if rtRoots == [ ] then null
              else pkgs.buildPackages.runCommand "${name}-rtdata" { } ''
                mkdir -p "$out"
                for r in ${nixpkgs.lib.concatStringsSep " " rtRoots}; do
                  [ -d "$r" ] || continue
                  cp -rL --no-preserve=mode "$r/." "$out/" 2>/dev/null || true
                done
              '';
          in
          unpinEmbedWrap pkgs {
            primary = name;
            # Load-bearing filter for the N=1 self-fold whose package name is itself
            # an applet (flac+metaflac → binary `flac`, alias `metaflac`).
            aliases = nixpkgs.lib.filter (n: n != name) names;
            man = combinedMan != null;
            manRoot = combinedMan;
            inherit removeReferences;
            stripCmd = ":";
            runtimeStage =
              if combinedRt == null then null
              else ''
                cp -rL --no-preserve=mode ${combinedRt}/. "$__unpin_stage/"
                chmod -R u+w "$__unpin_stage" 2>/dev/null || true
              '';
          } (if cosmoMode then megaCosmoDrv else megaElfDrv);

        # Why not overlays for per-package fixes? `appendOverlays` invalidates
        # `pkgsBuildHost.stdenv` → cascade rebuild of compiler-rt-libc-static etc.
        # in pkgsStatic-darwin (uncached; Hydra only builds pkgsStatic-linux) =
        # 30-60 min of darwin CI per configureFlag. Fake-cross via differing config
        # strings broke autotools (cross mode disables AC_RUN_IFELSE, which
        # apple-sdk's atf needs). So `drv.override`/`.overrideAttrs` inside the
        # consumer closures is the only path keeping both the cached toolchain AND
        # native-mode configure.

        # Rebuild `drv` with every dep in `drv.override.__functionArgs` swapped
        # for its `pkgsStatic` counterpart (.a-only), falling back to
        # `dropSharedLibs` when no pkgsStatic variant exists. Used by tmux's darwin
        # closure: pkgsStatic.tmux itself fails to link (configure.ac passes
        # `-static` → libSystem probe fails), so keep regular tmux but static its
        # deps. Preferring pkgsStatic over postFixup-delete dodges the
        # dyld-at-build-time pitfall (ncurses' tic links libncursesw.dylib and runs
        # at build time).
        withDepsSharedPruned = pkgs: drv:
          let
            fnArgs = drv.override.__functionArgs or { };
            isPrunableDrv = v:
              builtins.isAttrs v
              && (v.type or null) == "derivation"
              && v ? overrideAttrs;
            pruneOne = name:
              let
                staticDep = pkgs.pkgsStatic.${name} or null;
                regularDep = pkgs.${name} or null;
              in
              if staticDep != null && isPrunableDrv staticDep
              then { inherit name; value = staticDep; }
              else if regularDep != null && isPrunableDrv regularDep
              then { inherit name; value = dropSharedLibs regularDep; }
              else null;
            overrides = builtins.listToAttrs (
              builtins.filter (x: x != null)
                (map pruneOne (builtins.attrNames fnArgs))
            );
          in
          drv.override overrides;

        # `mingwStaticCross pkgs` = `pkgs.pkgsCross.mingwW64` + an overlay that,
        # on mingw, (1) wraps stdenv with `makeStaticLibraries` (injects
        # --enable-static/-DBUILD_SHARED_LIBS=OFF/-Ddefault_library=static) and
        # (2) sets `hostPlatform.isStatic = true` — a white lie so upstream recipes
        # keying off isStatic (zlib, zstd, libpsl) produce .a-only without a
        # per-package override. Safe for mingw (mingw-w64/mcfgthread produce
        # byte-identical .a either way; no glibc→musl libc swap). The `if isMinGW`
        # gate keeps the linux pkgsBuildHost.stdenv cache-hashed.
        mingwStaticCross = pkgs: pkgs.pkgsCross.mingwW64.appendOverlays [
          (selfPkgs: superPkgs:
            if superPkgs.stdenv.hostPlatform.isMinGW or false
            then
              let
                base = superPkgs.stdenvAdapters.makeStaticLibraries superPkgs.stdenv;
                # mingw-overlay/<name>.nix entries become overlay pieces at <name>.
                overlayEntries = nixpkgs.lib.mapAttrs
                  (_: f: f selfPkgs superPkgs)
                  mingwOverlayFixes;
              in
              {
                stdenv = base // {
                  hostPlatform = base.hostPlatform // { isStatic = true; };
                };
              } // overlayEntries
            else { })
        ];

        # `darwinStaticCross dpkgs` = the darwin cross set + an overlay that, on
        # darwin, wraps stdenv with `makeStaticLibraries` so deps build `.a`-only.
        # Required for the engine darwin MODULE path: a dep that builds a dylib
        # through the engine fails twice — libtool emits the ELF `-soname` (the
        # engine cc reports isGNU) which ld64.lld rejects, and a re-exporting dylib
        # (libiconv → libcharset) trips install_name_tool's LLVM build on
        # LC_REEXPORT_DYLIB. Static-only sidesteps both.
        #
        # UNLIKE mingwStaticCross, does NOT set `hostPlatform.isStatic`: on darwin
        # that makes recipes add `-static` (a FULL static link), which ld64 rejects
        # (no static libSystem — the filterEnableStaticOnDarwin trap).
        # makeStaticLibraries toggles only the library build, never the executable
        # link mode. The `isDarwin` gate keeps the linux build host untouched.
        darwinStaticCross = dpkgs: dpkgs.appendOverlays [
          (_selfPkgs: superPkgs:
            if superPkgs.stdenv.hostPlatform.isDarwin or false
            then { stdenv = superPkgs.stdenvAdapters.makeStaticLibraries superPkgs.stdenv; }
            else { })
        ];

        # Finalize a mingw binary for shipping (input already built through
        # `mingwStaticCross`). Adds libtool-aware `LDFLAGS=-all-static` at
        # make-time so the FINAL link resolves to `.a` only; without it libtool
        # picks a `.dll.a` and the DLL-link hook copies the `.dll` next to the
        # binary. `staticDeps` threads via `.override` (NOT overlay — gcc uses
        # zlib/zstd → full xgcc rebuild). `filterConfigureFlag` strips flags the
        # package adds unconditionally (curl's `--without-ssl`).
        mingwStaticBinary =
          { pkg
          , staticDeps ? { }
          , extraInputs ? [ ]
          , extraConfigureFlags ? [ ]
          , extraCFlags ? [ ]
          , filterConfigureFlag ? (_: true)
          , extraOverrides ? (_: { })
          }:
          let
            overridden = if staticDeps == { } then pkg else pkg.override staticDeps;
            withMingwOverrides = overridden.overrideAttrs (old: {
              stripAllList = [ "bin" ];
              buildInputs = (old.buildInputs or [ ]) ++ extraInputs;
              configureFlags =
                (builtins.filter filterConfigureFlag (old.configureFlags or [ ]))
                ++ extraConfigureFlags;
              # Make-time only — NIX_LDFLAGS at configure breaks autoconf's
              # "C compiler works" probe.
              makeFlags = (old.makeFlags or [ ]) ++ [ "LDFLAGS=-all-static" ];
            } // extraOverrides old);
          in
          # mingw headers (nghttp2, libpsl, libcurl) default to
          # `__declspec(dllimport)`; static consumers need *_STATICLIB or the link
          # leaves `__imp_*` unresolved.
          if extraCFlags == [ ]
          then withMingwOverrides
          else appendCFlags withMingwOverrides extraCFlags;

        packageWithMan = pkgs: name: drv:
          let
            stripped = drv.overrideAttrs (_: { stripAllList = [ "bin" "out" ]; });
            outs = stripped.outputs or [ "out" ];
            # jq-style drvs have a `bin` output; bash/coreutils put binaries in `out`.
            primary = if builtins.elem "bin" outs then stripped.bin else stripped.out;
            hasMan = builtins.elem "man" outs;
          in
          pkgs.symlinkJoin {
            name = "${name}-${stripped.version}";
            paths = [ primary ] ++ nixpkgs.lib.optional hasMan stripped.man;
            passthru = { inherit (stripped) version pname; };
          };

        # Single output for both single- and multi-output drvs (strip vs
        # symlinkJoin bin+man), so `nix build` produces the bare `result` symlink
        # action-build verifies at `result/bin/<pkg>` (multi-output drvs would land
        # at `result-bin`/`result-man`).
        strippedOrJoined = pkgs: name: drv:
          let
            # A `module` output (multicall, opt-in) is a sidecar, not a shipped
            # output: ignore it when deciding strip-vs-join.
            shipOutputs = builtins.filter (o: o != "module") (drv.outputs or [ "out" ]);
            out =
              if shipOutputs == [ "out" ]
              then drv.overrideAttrs (_: { stripAllList = [ "bin" "out" ]; })
              else packageWithMan pkgs name drv;
          in
          # strip/symlinkJoin yield a synthetic meta dropping upstream
          # license/description/homepage. Carry them back so tooling (website
          # packages page, `unpin info`) reads them. `meta` isn't hashed, no
          # rebuilds.
          out // {
            meta = (out.meta or { }) // builtins.intersectAttrs
              { license = null; description = null; homepage = null; longDescription = null; }
              (drv.meta or { });
          };

        # The engine adapter stdenv for a (pkgs, toolchain) — lifted out of
        # mkStandaloneFlake so the catalog mega can build it ONCE and share it.
        engineStdenvForShared = { pkgs, toolchain }: unpinAdapterStdenv {
          inherit pkgs toolchain;
          target = pkgs.pkgsStatic.stdenv.hostPlatform.config;
          native = pkgs.stdenv.buildPlatform.system == pkgs.stdenv.hostPlatform.system;
          cxx = true;
          lto = true;
          captureLinks = true;
        };

        # The set-level engine stdenv swap on pkgsStatic (Layers A/B/C), as a pure
        # function of (pkgs, toolchain). This is the heaviest per-package fixpoint
        # (a full pkgsStatic re-instantiation), but it is package-INDEPENDENT given
        # a fixed pkgs+toolchain — so the mega computes it ONCE and threads it
        # through every fold (sharedEnginePkgsStatic), collapsing the slope. The
        # standalone path calls it the same way → byte-identical .drv.
        enginePkgsStaticFor = { pkgs, toolchain }:
          let
            engStdenv = engineStdenvForShared { inherit pkgs toolchain; };
            # libjpeg-turbo: the engine's full -flto MISCOMPILES it — CTest #121
            # bmpsizetest hangs (its 65500² whole-image path allocs ~12GB) → OOM
            # (thin-LTO instead segfaults lld; only no-LTO is clean, byte-for-byte
            # the stock gcc behaviour). Build the SHARED libjpeg with lto=false so
            # every codec consumer (aom/avif/heif/jxl/chafa/ffmpeg/jpeg-tools/
            # openjpeg/jbig2/poppler…) gets the correct build. This lives here, not
            # in native-overlay/libjpeg-turbo.nix, because the lto=false engine
            # stdenv needs the BASE pkgs the adapter wraps — an autoWire `apply`
            # only sees the post-swap set. See that overlay file for the rationale.
            engStdenvNoLto = unpinAdapterStdenv {
              inherit pkgs toolchain;
              target = pkgs.pkgsStatic.stdenv.hostPlatform.config;
              native = pkgs.stdenv.buildPlatform.system == pkgs.stdenv.hostPlatform.system;
              cxx = true;
              lto = false;
              captureLinks = true;
            };
            # Base (pre-swap) gnu static-musl stdenv — pins pkg-config off the
            # engine (below). Captured from the pristine pkgs so the pin is an
            # absolute value the pkgsStatic splice can't re-resolve to engStdenv.
            baseStaticStdenv = pkgs.pkgsStatic.stdenv;
            engineBashAttrs = [ "bash" "bashInteractive" "bashNonInteractive" ];
            withEngineStdenv = pkgs.pkgsStatic.extend
              (_final: prev:
                if prev.stdenv.hostPlatform.isMusl || prev.stdenv.hostPlatform.isStatic
                then {
                  stdenv = engStdenv;
                  # pkg-config is a BUILD tool (a nativeBuildInput), never linked
                  # into the shipped binary — so it must not be engine-compiled.
                  # The set-wide swap would otherwise reach the HOST pkg-config
                  # that freetype's postInstall embeds in freetype-config
                  # (`pkgsHostHost.pkg-config`): built with the engine clang its
                  # bundled glib code hits -Wint-conversion under clang-21 and
                  # fails, breaking every freetype consumer (poppler, fastfetch…).
                  # Overriding the top-level attr is defeated by pkgsStatic
                  # splicing (the wrapper re-resolves its unwrapped C program
                  # through the swapped stdenv); pin the UNWRAPPED build's stdenv
                  # to the base gnu one instead — byte-identical to plain nixpkgs
                  # pkgsStatic, zero effect on shipped code. Same by-name exception
                  # idiom as the bash/meson/dep fixes below.
                  pkg-config-unwrapped =
                    prev.pkg-config-unwrapped.override { stdenv = baseStaticStdenv; };
                }
                else { });
            withBashFix = withEngineStdenv.extend
              (_final: prev:
                if prev.stdenv.hostPlatform.isMusl || prev.stdenv.hostPlatform.isStatic
                then builtins.listToAttrs
                  (map (n: { name = n; value = unpinBashBuildFix prev prev.${n}; })
                    (builtins.filter (n: prev ? ${n}) engineBashAttrs))
                else { });
            withDepFixes = builtins.foldl'
              (acc: name:
                let entry = autoWiredFixes.${name}; in
                acc.extend
                  (_final: prev:
                    if (if entry.autoWire == "static"
                        then (prev.stdenv.hostPlatform.isStatic or false)
                        else prev.stdenv.hostPlatform.isMusl)
                       && prev ? ${name}
                    then { ${name} = entry.apply prev; }
                    else { }))
              withBashFix
              (builtins.attrNames autoWiredFixes);
            # See withMesonBuildCC above. armv7l is the only cross built on a
            # foreign-arch runner, so it is the only host where meson's build-
            # machine compiler must be pinned to the native builder. Curated list
            # of the engine meson packages (same by-name style as autoWiredFixes);
            # add new meson deps here as the catalog grows. Gated to aarch32 CROSS
            # → identity overlay (byte-identical) on every other arch; the
            # `prev ? ${n}` guard skips names absent from a given set, and the
            # whole branch is lazy so non-aarch32 never forces these attrs.
            mesonBuildCcPkgs = [
              "glib"
              "cairo"
              "pixman"
              "pango"
              "dav1d"
              "librsvg"
              "libopus"
              "librist"
              "libbluray"
              "rubberband"
              "dbus"
              "libdrm"
              "libgudev"
              "libsysprof-capture"
              "xorgproto"
            ];
            withMesonBuildCcFix = withDepFixes.extend
              (_final: prev:
                if prev.stdenv.hostPlatform.isAarch32
                   && prev.stdenv.buildPlatform != prev.stdenv.hostPlatform
                then builtins.listToAttrs
                  (map (n: { name = n; value = withMesonBuildCC prev prev.${n}; })
                    (builtins.filter (n: prev ? ${n}) mesonBuildCcPkgs))
                else { });
            # Swap libjpeg-turbo to the lto=false engine stdenv set-wide (see
            # engStdenvNoLto above). nixpkgs' `libjpeg` aliases `libjpeg_turbo`;
            # override the concrete attr and re-point the alias so consumers of
            # either name get the no-LTO build. Gated isMusl||isStatic like the
            # other set-wide engine fixes; identity on non-engine hosts.
            withLibjpegNoLto = withMesonBuildCcFix.extend
              (_final: prev:
                if (prev.stdenv.hostPlatform.isMusl || prev.stdenv.hostPlatform.isStatic)
                   && (prev ? libjpeg_turbo || prev ? libjpeg)
                then
                  let lj = (prev.libjpeg_turbo or prev.libjpeg).override { stdenv = engStdenvNoLto; };
                  in { libjpeg = lj; }
                     // nixpkgs.lib.optionalAttrs (prev ? libjpeg_turbo) { libjpeg_turbo = lj; }
                else { });
          in
          withLibjpegNoLto;

        # The Windows (mingw + cosmo) root nixpkgs and its engine-swapped variant,
        # lifted to lib-level thunks. They are PACKAGE-INDEPENDENT (no pkgsAttr, no
        # per-recipe input), so a catalog mega that refolds N recipes through ONE
        # lib instance shares this single evaluation across the whole fold — the
        # windows counterpart of the enginePkgsStatic sharing, but free (no
        # injection knob needed; the shared thunk IS the sharing). mkStandaloneFlake
        # just references these instead of rebuilding them inline → byte-identical.
        windowsPkgsShared =
          let
            basePkgs = nixpkgs.legacyPackages.${"x86_64-linux"};
            nixpkgsPatched = basePkgs.applyPatches {
              name = "nixpkgs-cosmo";
              src = nixpkgs.outPath;
              patches = [ ./cosmo-lib-systems.patch ];
            };
            cosmoOverlay = import ./cosmo { lib = nixpkgs.lib // lib; };
          in
          import nixpkgsPatched {
            system = "x86_64-linux";
            overlays = [ cosmoOverlay ];
            config = {
              allowUnsupportedSystem = true;
              replaceCrossStdenv = { buildPackages, baseStdenv }:
                if baseStdenv.hostPlatform.isCosmo or false
                then
                  let
                    cs = import ./cosmocc.nix { pkgs = buildPackages; };
                    wiring = cs.mkCrossWiring {
                      inherit buildPackages baseStdenv;
                      targetArch = baseStdenv.hostPlatform.parsed.cpu.name;
                      targetPrefix = "${baseStdenv.hostPlatform.config}-";
                    };
                  in
                  wiring.stdenv
                else baseStdenv;
            };
          };
        # Engine adapter for the mingw cross host (bitcode). Built from the ORIGINAL
        # un-swapped mingwW64 so it never sees the overlay below — no recursion.
        windowsEngineStdenvShared =
          let mc = windowsPkgsShared.pkgsCross.mingwW64;
          in unpinAdapterStdenv {
            pkgs = mc;
            hostPkgs = mc;
            target = mc.stdenv.hostPlatform.config;
            native = false;
            cxx = true;
            lto = true;
            captureLinks = true;
          };
        # windowsPkgsShared with the mingw cross stdenv swapped to the engine adapter
        # (set-level, guarded on isMinGW so the glibc build host is untouched).
        windowsEnginePkgsShared = windowsPkgsShared.extend (_final: prev: {
          pkgsCross = prev.pkgsCross // {
            mingwW64 = prev.pkgsCross.mingwW64.extend (_f: p:
              if p.stdenv.hostPlatform.isMinGW or false
              then { stdenv = windowsEngineStdenvShared; } else { });
          };
        });

        # mkMegaFromRecipes: fold N catalog packages into one mega WITHOUT paying
        # N nixpkgs+toolchain instantiations. Each package re-exposes its recipe as
        # the lazy `unpinRecipe` output (reading it never forces `packages.*`, so no
        # per-flake nixpkgs cost). Here we instantiate the base (or cross) nixpkgs +
        # the engine-swapped pkgsStatic + the toolchain ONCE, then rebuild every
        # module by re-running mkStandaloneFlake with those shared instances threaded
        # in — so the N module builds share one fixpoint and eval is flat in N
        # instead of linear. Each produced module is byte-identical to the package's
        # own (same pkgs value, same toolchain), so the mega is unchanged.
        #
        # Targets (the mega forces exactly ONE per call):
        #   native linux  : pkgs = the native set; moduleAttr = "default".
        #   linux cross   : pkgs = the native BUILD set; crossPkgs = the cross set;
        #                   system = build system; moduleAttr = "linux-<arch>".
        #   native darwin : pkgs = the darwin set; moduleAttr = "default"; toolchain
        #                   defaults to the darwin unpinToolchain.
        #   windows mingw : pkgs = the native build set; moduleAttr = "windows-x86_64";
        #                   moduleField = "windowsMulticallModule"; linkPkgs = the
        #                   mingw cross set the PE links for. Its heavy infra
        #                   (windowsPkgsShared / windowsEnginePkgsShared) is shared
        #                   for free via lib-level thunks, so no crossPkgs is needed.
        mkMegaFromRecipes =
          { pkgs                           # base/native nixpkgs (importNixpkgs + toolchain build host)
          , recipes                        # [ <pkg>.unpinRecipe, … ]
          , crossPkgs ? null               # cross set for a linux cross mega (else null)
          , linkPkgs ? null                # set the mega LINKS for (mingw PE); defaults below
          , system ? pkgs.stdenv.hostPlatform.system
          , moduleAttr ? "default"         # which packages.<sys> attr carries the module
          , moduleField ? "multicallModule"
          , toolchain ? unpinToolchain pkgs.stdenv.buildPlatform.system
          , nameOverrides ? { }
          , defaultApplet ? null
          }:
          let
            # The set whose pkgsStatic feeds the engine swap (linux/darwin path): the
            # cross set on a cross mega, else the native set. Windows ignores it (its
            # engine set is the shared lib thunk) — the built thunk just stays unforced.
            engineHostPkgs = if crossPkgs != null then crossPkgs else pkgs;
            # The set the mega links for. Cross/native: engineHostPkgs. Windows: the
            # mingw cross set (linkPkgs).
            megaLinkPkgs = if linkPkgs != null then linkPkgs else engineHostPkgs;
            # Build the heavy engine-swapped pkgsStatic ONCE for the whole fold (a
            # thunk; the windows path never forces it).
            sharedEnginePkgsStatic = enginePkgsStaticFor { pkgs = engineHostPkgs; inherit toolchain; };
            sharedCrossPkgs = if crossPkgs != null then { ${moduleAttr} = crossPkgs; } else { };
            moduleOf = recipe:
              (mkStandaloneFlake (recipe // {
                sharedPkgs = pkgs;
                sharedToolchain = toolchain;
                inherit sharedEnginePkgsStatic sharedCrossPkgs;
              }))
              .packages.${system}.${moduleAttr}.${moduleField};
          in
          mkMegaMulticall {
            pkgs = megaLinkPkgs;
            inherit toolchain nameOverrides defaultApplet;
            modules = map moduleOf recipes;
          };

        # Standalone-binary flake template. Returns:
        #   packages.<system>.default                = native build (pkgsStatic)
        #   packages.aarch64-darwin."darwin-x86_64"  = cross x86_64-darwin
        #   packages.x86_64-linux."windows-x86_64"   = mingw-cross build
        #   apps.<system>.default                    = `nix run` entry
        #
        # `name` is the user-facing id. `pkgsAttr` overrides the nixpkgs/nativeFixes
        # lookup when the nixpkgs attribute differs (nixpkgs `links2` → we ship
        # `links`). `binName` overrides when bin name ≠ name. `nativeBuild = false`
        # → windows-only (gvim). `linuxOnly = true` → suppresses every darwin attr,
        # for Linux-kernel-only tools (kmod, util-linux, shadow, procps-ng).
        mkStandaloneFlake = args@
          { self
          , name
          , build ? null
          , windowsBuild ? null
          # darwinBuild: consumer darwin (Mach-O) build closure, the analogue of
          # `windowsBuild`. Receives the engine+static darwin cross set and returns
          # the drv the module hook compiles. For a darwin module needing a source
          # tweak the stock package lacks (grep's restoreArgv0Dispatch). Null →
          # stock cross package.
          , darwinBuild ? null
          , binName ? name
          , pkgsAttr ? name
          , nativeBuild ? true
          , windows ? false
          , windowsCosmo ? false
          , linuxOnly ? false
          # No companion data tarball by default. Runtime data is embedded in
          # the binary (file's magic, vim/gvim's VFS runtime) and man pages go
          # in the embedded ZIP (embedMan), so `share/` is redundant.
          # Set true only for a package that genuinely needs a side asset.
          , package_data ? false
          , bootstrap_naming ? false
          , own_software ? false
          # Embed the package's own man pages into the binary via `withMan`
          # (as `unpin/man/*` ZIP entries), so `unpin man <pkg>` works offline with
          # no companion asset. Default-on across the catalog: packages with no
          # man (codec libs, coreutils/busybox) skip gracefully. Set false to
          # opt a package out.
          , embedMan ? true
          # Dead-store-ref scrub patterns for the NATIVE unpinEmbedWrap, for
          # packages that DON'T carry an engine `multicall` attr (single-binary or
          # cppRenameMulticall folds like acl/brotli/cpio). Same semantics as
          # `multicall.removeReferences` (name-substring patterns; opt-in; []
          # leaves the drv byte-identical) — this is just the reachable spelling
          # when there is no `multicall` attr to hang it on (that attr triggers the
          # engine module path). Unioned with multicall.removeReferences below.
          # Use for baked datadir constants the static binary never reaches at
          # runtime (e.g. autotools' own $out/share/locale from NLS). See
          # unpinEmbedWrap's `removeReferences`.
          , removeReferences ? [ ]
          # Override the man source for the windows/cosmo binary. By default the
          # cross build (which ships no man) grafts the version-locked pages from
          # the x86_64-linux nixpkgs build, which over-harvests (ffmpeg's
          # ffplay.1/libav*.3). Set a store path with `share/man` to embed exactly
          # that set instead. null = keep the nixpkgs graft.
          , winManRoot ? null
          # Opt-in smoke-test args, e.g. `[ "--version" ]`. action-build runs
          # `<bin> ${smoke[*]}` after each build on matching-ABI runners. Exit 0
          # alone is too lax (some tools print "Unknown option" and exit 0), so
          # pair with `smokePattern` for a stdout substring match. null skips.
          , smoke ? null
          , smokePattern ? null
          # Per-package exception to the darwin portability allow-list: Apple
          # PrivateFramework names (e.g. [ "MediaRemote" ]) the verify step accepts
          # for THIS package, beyond the always-allowed public Frameworks/libSystem/
          # libobjc. Default []. Use only when a macOS feature depends on a private
          # framework with no public equivalent (symbols should be weak-import +
          # NULL-guarded).
          , darwinAllowPrivateFrameworks ? [ ]
          # optimize: knobs for opt-level / stack protector / LTO / GC, merged
          # with `{ lto = false; opt = null; ssp = true; gc = true; }`:
          #
          #   lto = true   → mkPkgsLTO overlay (Linux native only). OFF by default:
          #                  the LTO chain has systemic recurring failures
          #                  (conftest leakage, ltrans refs, muslLTO, buildInput
          #                  miscompiles) and the 5-15% size win isn't worth it for
          #                  tiny CLIs. Opt in per-package for a hot path.
          #   opt = "-Os"  → appended to NIX_CFLAGS_COMPILE (wins over upstream).
          #                  null leaves it to upstream (~ -O2); under LTO null → -O2.
          #   ssp = false  → drop stack protector + the LTO retention flag.
          #   gc = false   → disable the function/data-sections + --gc-sections
          #                  prune (mkPkgsGC, Linux native). ON by default: benign,
          #                  shrinks 6-19% (jq 6%, aom 19%). LTO subsumes it. NOTE:
          #                  for multicall packages where `name` ≠ the nixpkgs attr,
          #                  set `pkgsAttr` to the real lib (aom → "libaom") or only
          #                  the multicall final link gets --gc-sections; that
          #                  post-link must also append `${lib.gcSectionsFlag pkgs}`.
          # Pin `meta.license` to an explicit SPDX id (or list), e.g.
          # "GPL-3.0-or-later". strippedOrJoined carries upstream automatically;
          # set this only when the build has none (custom mkDerivation — ffmpeg,
          # python) or inherits a noisy list to pin.
          , license ? null
          # Pin `meta.description` (one line). Set only when the build has none.
          , description ? null
          , optimize ? { }
          # Opt a package into the multicall MODULE artifact. When set, the
          # native-linux `packages.<sys>.default` build gains a `module` output
          # (post-processed from already-compiled objects, no recompile) and a
          # `passthru.multicallModule` manifest. Shape:
          #   multicall = {
          #     programs = [ { name = "grep"; objs = [ "src/grep.o" … ];
          #                    aliases = [ "egrep" "fgrep" ]; } ];
          #     internalArchives = [ "lib/libgreputils.a" ];  # private (gnulib)
          #     depArchives = [ "${pkgs.pkgsStatic.pcre2.out}/lib/libpcre2-8.a" ];
          #     keepAutoArchives = [ "libcrypt.a" ];  # rescue from the libc-split skip
          #     requires = { };   # cxx/group/frameworks/… overrides
          #   }
          # `keepAutoArchives` names basenames the auto-derive would otherwise drop as
          # a glibc-style libc split (see effectiveSkipArchives). musl folds crypt into
          # libc.a, so a `libcrypt.a` in a musl closure is always libxcrypt (real dep,
          # crypt_gensalt/yescrypt); a fold that needs it (shadow) rescues its own —
          # already engine-compiled in the build closure, so it rides as bitcode and
          # folds on every arch (unlike a hand-passed depArchive, which resolves to the
          # vanilla GCC-ELF instance and breaks the ppc64le -flto link's inline-PLT).
          # null = unchanged. Linux native only for now. `depArchives` is a
          # passthru reference, not linked into the shipped binary.
          , multicall ? null
          # Cosmo counterpart of `multicall`, emitted from the COSMO CROSS build
          # (the `windows-x86_64` artifact). cosmocc objects are ELF before
          # apelink, so objcopy --redefine-syms applies directly (no lld, no
          # -flto). Gains a `module` output (renamed objs/applet/gnulib in native
          # link order) and a `passthru.cosmoMulticallModule` manifest. Shape
          # (single-program only — coreutils single-binary, bash, dash):
          #   multicallCosmo = {
          #     program = "coreutils";                  # entry = unpin__<name>__<program>_main
          #     programObjs = [ "src/coreutils-coreutils.o" ];  # DIRECT at mega-link
          #     appletArchives = [ "src/libsinglebin_*.a" … ];  # scanned BEFORE gnulib
          #     gnulibArchives = [ "lib/libcoreutils.a" ];      # scanned AFTER applets
          #     aliases = [ "[" "cat" … ];              # every applet routes to entry
          #     depArchives = [ "${pkgs.readline}/lib/libreadline.a" … ];  # external .a
          #     requires = { };                         # cxx override (default false)
          #   }
          # null = unchanged. Independent of `multicall`/`engine`; a package can
          # carry both, neither, or one.
          , multicallCosmo ? null
          # Link the DNS fallback (__wrap_getaddrinfo) into the linux-static
          # artifact so it resolves names where /etc/resolv.conf is absent
          # (Android, minimal containers). OPT-IN: only on hostname-resolving
          # packages (curl, whois, nmap). NOT free elsewhere: the trailing `-lc` +
          # `--wrap=getaddrinfo` pulls ~25 KB of musl's resolver into EVERY binary
          # (a non-consumer once tipped bzip2's bss into a SIGSEGV). No-op on
          # darwin/windows. See withDnsFallback.
          , dnsFallback ? false
          # engine: which toolchain builds the NATIVE-LINUX artifact.
          #   "default"    → nixpkgs' static-musl stdenv, the catalog default.
          #   "unpin-llvm" → the SAME nixpkgs recipe through the vendored unpin-llvm
          #                  toolchain via unpinAdapterStdenv. The swap is
          #                  transparent: a consumer `build` gets a `pkgs` whose
          #                  pkgsStatic.<pkgsAttr> is already on the engine stdenv
          #                  (see rawBuild), no per-package plumbing. Composes with
          #                  neither lto nor gc (the adapter replaces the stdenv
          #                  those overlays wrap); nixpkgsFor falls back to plain
          #                  nixpkgs here.
          , engine ? "default"
          # Declarative embed for build-coupled VFS / runtime-data packages
          # (vim/perl/file/zsh/gvim/python/xvfb/xvnc/biber). Their `build` returns a
          # PRISTINE compiled base (injectVfs/win32-wrap applied, NO embed) so the
          # mkStandaloneFlake hooks reach the compile; the embed then runs once,
          # post-build, via unpinEmbedWrap — the single embed path every package
          # uses. Shape (each entry a function `pkgs: base: { … }` returning embed
          # opts, minus `primary`, which is `binName`):
          #   runtimeEmbed = {
          #     native  = pkgs: base: { man = true; runtimeStage = …; aliases = …; };
          #     windows = pkgs: base: { runtimeStage = …; manRoot = "…"; };
          #   };
          # `native` covers linux+darwin (branch on pkgs.stdenv.hostPlatform.isDarwin
          # inside if needed). Opts override the platform defaults (man = embedMan,
          # windows man graft, stripCmd, cosmoSymtabTrim). null → no custom embed
          # (man+aliases auto-discovered, the standard single-binary case).
          , runtimeEmbed ? null
          # Shared-infra injection for the catalog mega (mkMegaFromRecipes). When
          # the mega folds N packages it instantiates nixpkgs + the unpin-llvm
          # toolchain ONCE and threads them through here, so the N module builds
          # reuse one fixpoint instead of each re-instantiating its own (the eval
          # OOM fix). null → standalone behaviour: instantiate per-flake as before
          # (byte-identical .drv — both are `import nixpkgs {system}` / the same
          # vendored toolchain).
          , sharedPkgs ? null
          , sharedToolchain ? null
          # The engine-swapped pkgsStatic set, prebuilt once by the mega and shared
          # across the fold (the heaviest per-package fixpoint). null → build it
          # per-flake as before. Consumed by WHICHEVER target's host config matches
          # this set's (native default, a cross arch, or a darwin host) — the mega
          # forces exactly one target, so the match is unambiguous; other (unforced)
          # targets rebuild fresh for free.
          , sharedEnginePkgsStatic ? null
          # Cross-arch nixpkgs sets prebuilt once by the mega, keyed by the cross
          # module attr ("linux-riscv64", "linux-armv7l", …). null/{} → each cross
          # attr imports its own nixpkgs as before. Lets a cross mega share the one
          # cross fixpoint across the fold (the cross counterpart of sharedPkgs).
          , sharedCrossPkgs ? { }
          }:
          let
            # Re-expose the caller's recipe (exactly what the package author wrote,
            # minus the injection knobs) so the mega can refold it against shared
            # infra via `inputs.<pkg>.unpinRecipe` — a LAZY output that never forces
            # `packages.*`, so reading it costs ~nothing (no nixpkgs instantiation).
            unpinRecipe = builtins.removeAttrs args
              [ "sharedPkgs" "sharedToolchain" "sharedEnginePkgsStatic" "sharedCrossPkgs" ];
            tc = system: if sharedToolchain != null then sharedToolchain else unpinToolchain system;
            runtimeEmbedNative = if runtimeEmbed == null then null else runtimeEmbed.native or null;
            runtimeEmbedWindows = if runtimeEmbed == null then null else runtimeEmbed.windows or null;
            optimize_ = { lto = false; opt = null; ssp = true; gc = true; } // optimize;
            inherit (optimize_) lto opt ssp gc;
            ltoOpt = if opt == null then "-O2" else opt;
            # LTO/GC overlays apply on Linux only; darwin/cross fall back to stock
            # pkgs. LTO subsumes gc (lto wins when both set).
            # Plain nixpkgs import. Darwin dep fixes are NOT wired here as
            # `overlays` — an overlay on the nixpkgs IMPORT joins the
            # stdenv-bootstrap fixpoint and re-hashes the whole darwin base closure
            # (uncached → full rebuild). A leaf-wrapper fix goes there instead (the
            # ncurses <sys/ttydev.h> fix rides inside embedFallbackTerminfoOnly).
            importNixpkgs = system:
              if sharedPkgs != null then sharedPkgs else import nixpkgs { inherit system; };
            nixpkgsFor = forAllNative (system:
              # unpin-llvm replaces the whole stdenv, so the gc/lto overlays would
              # be silent no-ops; use plain nixpkgs.
              if engine == "unpin-llvm" then importNixpkgs system
              else if lto && isLinuxSys system
              then mkPkgsLTO { inherit system; opt = ltoOpt; inherit ssp; pkgName = pkgsAttr; }
              else if gc && isLinuxSys system
              then mkPkgsGC { inherit system ssp opt; pkgName = pkgsAttr; }
              else importNixpkgs system);

            # Apply opt/ssp knobs. No-op at default (opt = null + ssp = true) so
            # cache.nixos.org hits stay intact.
            applyOptSsp = drv:
              if opt == null && ssp then drv
              else
                let
                  flags = (nixpkgs.lib.optional (opt != null) opt)
                       ++ (nixpkgs.lib.optional (!ssp) "-fno-stack-protector");
                in
                (appendCFlags drv flags).overrideAttrs (old: {
                  hardeningDisable = (old.hardeningDisable or [ ])
                    ++ (if ssp then [ ] else [ "stackprotector" ]);
                });

            # Pin the artifact's meta.license to the caller-supplied SPDX id(s)
            # when `license` is set; otherwise keep whatever strippedOrJoined
            # carried from upstream. meta isn't hashed, so this never rebuilds.
            withLicense = drv:
              if license == null then drv
              else drv // { meta = (drv.meta or { }) // { license = license; }; };

            # Same pinning for meta.description; meta isn't hashed either.
            withDescription = drv:
              if description == null then drv
              else drv // { meta = (drv.meta or { }) // { description = description; }; };

            defaultRawBuild = nativeFixes.${pkgsAttr} or (pkgs: pkgs.pkgsStatic.${pkgsAttr});
            # The unpin-llvm engine swaps the recipe's `stdenv` for our adapter.
            # A CUSTOM `build` (opaque closure) instead gets a `pkgs` whose
            # pkgsStatic.<pkgsAttr> is already on the engine stdenv, so the recipe
            # reads as off-engine with no per-package plumbing. linux-static host
            # only; darwin/cross/off-engine untouched (byte-identical).
            # Delegates to the lifted lib-level helper, threading the shared
            # toolchain. (Construction unchanged → byte-identical .drv.) The
            # engine swap is set-wide on pkgsStatic + unconditional lto/capture so
            # a dep is byte-identical whether it ships standalone or folded into a
            # multicall consumer; the capture shim is runtime-gated on
            # $UNPIN_CAPTURE_LINKS and inert for non-multicall builds.
            engineStdenvFor = pkgs: engineStdenvForShared {
              inherit pkgs;
              toolchain = tc pkgs.stdenv.buildPlatform.system;
            };
            rawBuild = pkgs:
              let
                # Engine on linux (native or cross — one LLVM toolchain
                # cross-emits every target via `clang -target`, no qemu) and on a
                # native darwin host. Both ride a stdenv swap on `pkgsStatic`
                # (Layer A below).
                useEngine = engine == "unpin-llvm"
                  && (pkgs.stdenv.hostPlatform.isLinux || pkgs.stdenv.hostPlatform.isDarwin);
                # SET-LEVEL stdenv swap so the top package AND its whole link
                # closure compile on the engine (all-deps-bitcode; a shallow `//`
                # would leave deps gcc ELF). The `isMusl || isStatic` guard is
                # load-bearing: the overlay also reaches buildPackages, and an
                # unguarded swap forces the engine onto the build host → trips
                # `isFromBootstrapFiles`. isMusl selects the linux target host;
                # darwin has no musl split but its pkgsStatic host is isStatic
                # (buildPackages/bootstrap aren't), so isStatic selects it.
                # Byte-identical on linux.
                #
                # The engine-swapped pkgsStatic (Layers A/B/C). Now a lib-level
                # helper (enginePkgsStaticFor) so the catalog mega can build it ONCE
                # and inject it (sharedEnginePkgsStatic) — the heaviest per-package
                # fixpoint, shared. Standalone calls the helper directly (identical
                # construction → byte-identical .drv). Match by HOST CONFIG so the
                # injected set is reused by whichever target it was built for —
                # native default, a cross arch (riscv64/…), or a darwin host — and
                # ignored by the others (which the mega never forces). The cross
                # attr's `withLLDLink` wrapper is a no-op under the engine adapter
                # stdenv (its isLLDTarget gate fails), so sharing the unwrapped set
                # is byte-identical to the per-flake wrapped build (proven).
                enginePkgsStatic =
                  if !useEngine then pkgs.pkgsStatic
                  else if sharedEnginePkgsStatic != null
                       && sharedEnginePkgsStatic.stdenv.hostPlatform.config
                          == pkgs.pkgsStatic.stdenv.hostPlatform.config
                  then sharedEnginePkgsStatic
                  else enginePkgsStaticFor {
                    inherit pkgs;
                    toolchain = tc pkgs.stdenv.buildPlatform.system;
                  };
                enginePkgs = pkgs // { pkgsStatic = enginePkgsStatic; };
              in
              if build != null
              then build (if useEngine then enginePkgs else pkgs)
              else if useEngine
              then defaultRawBuild enginePkgs
              else defaultRawBuild pkgs;
            stripped = pkgs:
              let
                # multicall MODULE opt-in: native-linux only. The hook adds a
                # `module` output by post-processing the objects the build
                # already compiled (no recompile), riding the same builder as
                # the shipped binary. No-op when `multicall == null` or off-Linux.
                sanMc = nixpkgs.lib.replaceStrings [ "." "-" "+" ] [ "_" "_" "_" ];
                # Per-platform program set. Most packages ship the same programs
                # everywhere, so `multicall.programs` is authoritative. A package
                # whose darwin build is a genuine SUBSET (no /proc analogue, so it
                # ships fewer applets — e.g. procps-ng's watch/uptime/tload) sets
                # `multicall.darwinPrograms` to that subset; the module hook,
                # selfFold and manifest then fold exactly those on a darwin host.
                # This is the engine-self-fold replacement for `darwin = false`:
                # instead of opting darwin OUT of the module, it opts it in with
                # the right (smaller) list. Windows keeps `multicall.programs`.
                mcProgramsRaw =
                  if multicall != null
                     && pkgs.stdenv.hostPlatform.isDarwin
                     && multicall ? darwinPrograms
                  then multicall.darwinPrograms
                  else (if multicall == null then [ ] else multicall.programs);
                # A program may be built on some targets only — binutils' gold/dwp
                # have no RISC-V backend (gold's configure.tgt omits it; gold is
                # frozen, superseded by lld), so binutils' own configure skips them
                # on a riscv64 host and no `ld-new`/`dwp` link sidecar exists there.
                # A `supportedTarget` predicate (target `hostPlatform` → bool) drops
                # such a program on unsupported targets. It filters the ONE list that
                # feeds the module hook, the manifest applets AND the dispatcher
                # (all `mcPrograms` below), so they stay consistent — the fold then
                # matches exactly what upstream built (gold/dwp on the 5 arches that
                # have it, skipped on riscv64), with no missing-sidecar hard-error
                # and no dangling dispatcher entry. Purely eval-time (no IFD): the
                # arch is a target-platform property, so evaluating the flake never
                # forces a build. Default (no predicate) = always included.
                mcPrograms = nixpkgs.lib.filter
                  (p: (p.supportedTarget or (_: true)) pkgs.stdenv.hostPlatform)
                  mcProgramsRaw;
                # The bitcode module rides the engine's -flto objects. Linux and
                # darwin both default-on (the darwin standalone already builds
                # regardless); a package sets multicall.darwin = false to opt out.
                # Emitted NATIVELY on a darwin host, never cross-built from linux.
                wantModule = multicall != null
                  && (pkgs.stdenv.hostPlatform.isLinux
                      || (pkgs.stdenv.hostPlatform.isDarwin && (multicall.darwin or true)));
                # engine = "unpin-llvm" → bitcode objects → use the bitcode-LTO
                # emitter (llvm-link + opt -internalize); "default" keeps objcopy.
                useBitcodeModule = wantModule && engine == "unpin-llvm";
                rawHooked =
                  if useBitcodeModule
                  then multicallModuleHookLTO
                    {
                      package = name;
                      programs = mcPrograms;
                      internalArchives = multicall.internalArchives or [ ];
                      inferLinkInputs = multicall.inferLinkInputs or true;
                      llvm = "${tc pkgs.stdenv.buildPlatform.system}/bin/llvm";
                    }
                    (rawBuild pkgs)
                  else if wantModule
                  then multicallModuleHook
                    {
                      package = name;
                      programs = mcPrograms;
                      internalArchives = multicall.internalArchives or [ ];
                      isTargetDarwin = false;
                    }
                    (rawBuild pkgs)
                  else rawBuild pkgs;
                # iconv: Apple libiconv-113's STATIC build fails through the engine
                # (cross: meson/static-modules.gperf; native: atf self-test
                # miscompiles). Drop Apple libiconv, append GNU libiconvReal (clean
                # static .a) built with the engine stdenv. Harmless for non-iconv
                # packages.
                darwinIconvFixed = drv:
                  if engine == "unpin-llvm" && pkgs.stdenv.hostPlatform.isDarwin
                  then
                    let
                      noIconv = nixpkgs.lib.filter (x: (x.pname or "") != "libiconv");
                    in
                    drv.overrideAttrs (old: {
                      # gnulib tools carry libiconv in propagatedBuildInputs too —
                      # filter BOTH or Apple libiconv survives.
                      buildInputs =
                        (noIconv (old.buildInputs or [ ]))
                        ++ [ (pkgs.pkgsStatic.libiconvReal.override { stdenv = engineStdenvFor pkgs; }) ];
                      propagatedBuildInputs = noIconv (old.propagatedBuildInputs or [ ]);
                    })
                  else withDarwinIconv pkgs drv;
                core = darwinIconvFixed (dropSharedLibs (filterEnableStaticOnDarwin (applyOptSsp rawHooked)));
                # DNS fallback linux-only for now; the Rust tools opt into
                # darwin/windows via withDnsFallback directly.
                base = if dnsFallback && pkgs.stdenv.hostPlatform.isLinux
                       then withDnsFallback pkgs.pkgsStatic core else core;
                # Ship by embedding man/aliases/runtime into the PRISTINE base in a
                # post-build runCommand (unpinEmbedWrap): the base build is then
                # shared byte-for-byte with library consumers, so there is ONE
                # derivation per package — openssl as a shipped CLI vs as dnsutils'
                # libcrypto dep. This is the single embed path: standard single
                # binaries (man+aliases auto-discovered) and VFS/runtime packages
                # (`runtimeEmbed.native` supplies runtimeStage/explicit aliases/man)
                # alike. Self-folding multi-program packages take the mega path
                # (which also embeds via unpinEmbedWrap). The only remaining legacy
                # branch is a not-yet-migrated flake that still embeds in its own
                # build (passthru.unpinEmbedsMan) — kept working during the migration.
                useEmbedWrap = !selfFold && !(base.unpinEmbedsMan or false)
                  && (embedMan || runtimeEmbedNative != null);
                nativeEmbedOpts = { primary = binName; man = embedMan; removeReferences = removeReferences ++ (if multicall == null then [ ] else multicall.removeReferences or [ ]); }
                  // (if runtimeEmbedNative != null then runtimeEmbedNative pkgs base else { });
                # Legacy in-build man embed, retained ONLY for un-migrated
                # unpinEmbedsMan flakes during the migration (deleted once all 9 VFS
                # flakes declare runtimeEmbed). withMan FORKS the build — the
                # divergence unpinEmbedWrap avoids.
                legacyMaybeMan0 =
                  if embedMan && !(base.unpinEmbedsMan or false)
                  then withMan pkgs { primary = binName; } base
                  else base;
                # When a `module` output rides along, force the SAME final strip
                # selection (`[bin out]`) strippedOrJoined/packageWithMan apply
                # downstream, so their internal strip is a no-op (identical .drv)
                # and the `module` we reference is the very build the shipped binary
                # comes from — no second build. Shipped bytes unchanged.
                legacyMaybeMan =
                  if wantModule
                  then legacyMaybeMan0.overrideAttrs (_: { stripAllList = [ "bin" "out" ]; })
                  else legacyMaybeMan0;
                # The module-bearing drv the manifest references. unpinEmbedWrap:
                # the pristine `base` (the shipped binary is base's bin stripped —
                # the SAME build as base.module). Legacy: the [bin out]-forced fork
                # the shipped binary comes from.
                moduleSource = if useEmbedWrap then base else legacyMaybeMan;
                # SELF-FOLD: a multi-program package (find+xargs, flac+metaflac)
                # must still ship ONE binary, so apply the mega fold to its single
                # module (N=1). Drops extra upstream binaries not in `programs`.
                # `defaultProgram` runs on a bare invocation (default = binName if
                # an applet, else null → dispatcher lists programs).
                selfFold = wantModule && builtins.length mcPrograms > 1;
                selfFoldDefault =
                  let dp = multicall.defaultProgram or binName;
                  in if builtins.elem dp (map (a: a.name) multicallManifest.applets)
                     then dp else null;
                selfFolded = mkMegaMulticall {
                  inherit pkgs name;
                  modules = [ multicallManifest ];
                  defaultApplet = selfFoldDefault;
                };
                shipped =
                  if useEmbedWrap then unpinEmbedWrap pkgs nativeEmbedOpts base
                  else if selfFold then strippedOrJoined pkgs name selfFolded
                  else strippedOrJoined pkgs name legacyMaybeMan;
                result = withLicense (withDescription shipped);
                # The manifest the mega-builder consumes. moduleArchive/gnulib
                # depArchives reference the `module` output of the same built drv;
                # external depArchives are verbatim store paths (passthru, NOT
                # linked into the shipped binary).
                multicallManifest = {
                  package = name;
                  # Bitcode: ONE module.bc with internalArchives folded in.
                  # ELF/objcopy: module.a + renamed private archives as depArchives.
                  moduleFormat = if useBitcodeModule then "bitcode" else "elf-archive";
                  moduleArchive =
                    if useBitcodeModule
                    then "${moduleSource.module}/lib/module.bc"
                    else "${moduleSource.module}/lib/module.a";
                  # Native (asm/SIMD) objects the bitcode link dropped, rescued into
                  # a sidecar the mega-link adds alongside module.bc. Always present
                  # (possibly empty) on the bitcode path; null otherwise.
                  nativeArchive =
                    if useBitcodeModule
                    then "${moduleSource.module}/lib/module_native.a"
                    else null;
                  depArchives =
                    (if useBitcodeModule then [ ]
                     else map (a: "${moduleSource.module}/lib/${baseNameOf a}") (multicall.internalArchives or [ ]))
                    ++ (let d = multicall.depArchives or [ ];
                        in if builtins.isFunction d then d pkgs else d);
                  applets = nixpkgs.lib.concatMap
                    (p:
                      let entry = "unpin__${sanMc name}__${sanMc p.name}_main"; in
                      [{ name = p.name; inherit entry; }]
                      ++ map (al: { name = al; inherit entry; }) (p.aliases or [ ]))
                    mcPrograms;
                  requires = { cxx = false; group = true; } // (multicall.requires or { });
                  # Auto-derived external dep DIRS (pure store paths, no IFD); the
                  # mega builder globs <dir>/lib/*.a at build time. `depArchives`
                  # stays as an additive override for archives not in the closure.
                  depInputDirs = multicallExternalDepDirs moduleSource;
                  # Basenames to rescue from the auto-derive's libc-split skip list
                  # (e.g. "libcrypt.a" for a package that folds libxcrypt). Empty by
                  # default — only libxcrypt-consuming folds (shadow) set it.
                  keepAutoArchives = multicall.keepAutoArchives or [ ];
                  # Man source for the mega to MERGE: the built drv's man-bearing
                  # output (split `man`, else out). null when this build ships no
                  # man; the merge skips nulls.
                  manRoot =
                    if embedMan
                    then "${moduleSource.man or moduleSource}"
                    else null;
                  # Runtime-data source for the mega to MERGE (file's magic.mgc).
                  # `multicall.runtimeDataRoot` is a store path or a `pkgs:` function
                  # for cross. null when the package ships none.
                  runtimeDataRoot =
                    let r = multicall.runtimeDataRoot or null;
                    in
                    if r == null then null
                    else if builtins.isFunction r then r pkgs
                    else r;
                  # Name-substring patterns whose store refs are DEAD baked paths to
                  # scrub from the shipped binary (single-program via unpinEmbedWrap;
                  # multi-program/mega via mkMegaMulticall's embed). Empty by default
                  # → no scrub, drv byte-identical.
                  removeReferences = multicall.removeReferences or [ ];
                };
              in
              if wantModule then result // { multicallModule = multicallManifest; } else result;

            # Windows runs on x86_64-linux runners. `allowUnsupportedSystem`
            # because most nixpkgs `meta.platforms` exclude mingw/cosmo. Dispatch:
            #   windowsBuild   → consumer closure (mingw or cosmocc). Per-binary
            #                    cosmo recipes in `<consumer>/cosmo.nix`, mingw
            #                    inline in the consumer's `windowsBuild`.
            #   windowsCosmo   → `(cosmoStaticCross pkgs).${pkgsAttr}`; the cosmo
            #                    cross stdenv's apelink hook auto-converts ELF →
            #                    PE32+. For cosmo builds with no consumer quirks
            #                    (most use `windowsBuild = import ./cosmo.nix`).
            #   windows        → plain `(mingwStaticCross pkgs).${pkgsAttr}`.
            windowsEnabled = windows || windowsBuild != null || windowsCosmo;
            # windowsPkgs is the single root for BOTH cross targets:
            #   pkgsCross.mingwW64  →  vanilla nixpkgs cross
            #   pkgsCross.cosmo     →  cosmocc-as-cross-stdenv (replaceCrossStdenv +
            #                          cosmoOverlay)
            # applyPatches registers `cosmo` as a kernel + example crossSystem
            # (./cosmo-lib-systems.patch). Both the overlay and replaceCrossStdenv
            # self-guard on `isCosmo`, so vanilla mingw drvs are unchanged.
            # Lifted to a lib-level thunk (windowsPkgsShared) so a catalog mega's
            # refolds share one evaluation. Byte-identical (same expression).
            windowsPkgs = windowsPkgsShared;
            windowsRawBuild =
              if windowsBuild != null then windowsBuild
              else if windowsCosmo then (pkgs: (cosmoStaticCross pkgs).${pkgsAttr})
              else (pkgs: (mingwStaticCross pkgs).${pkgsAttr});
            # Cosmo multicall MODULE opt-in (symmetric to the linux `multicall`
            # path). When `multicallCosmo` is set, post-process the cosmo cross
            # build with multicallModuleHookCosmo (renamed ELF objs — cosmo objects
            # are ELF before apelink) and emit `passthru.cosmoMulticallModule` from
            # the same build the `windows-x86_64` artifact ships.
            sanMcW = nixpkgs.lib.replaceStrings [ "." "-" "+" ] [ "_" "_" "_" ];
            wantCosmoModule = multicallCosmo != null && (windowsCosmo || windowsBuild != null);
            # Mingw BITCODE multicall MODULE opt-in — the engine counterpart of
            # the cosmo path. When engine + multicall + a mingw (NOT cosmo) windows
            # binary, route the mingw cross build through the engine adapter
            # (bitcode), post-process with multicallModuleHookLTO and emit a
            # `passthru.windowsMulticallModule` the mega folds with `-target
            # …-windows-gnu -flto`. multicallCosmo == null keeps the two windows
            # module paths mutually exclusive. OPT-IN (`multicall.windows = true`),
            # NOT implied by windowsBuild: deps must cross-build cleanly through the
            # engine for mingw first (file's zlib uses a gcc-only win32/Makefile.gcc).
            # grep/sed/file validated; htop/bc stay on their current path.
            wantWindowsModule =
              engine == "unpin-llvm" && multicall != null && (multicall.windows or false)
              && multicallCosmo == null && windowsEnabled;
            # Lifted to lib-level thunks (windowsEnginePkgsShared, built on
            # windowsEngineStdenvShared) so a catalog mega's refolds share one
            # evaluation. The per-package gate (wantWindowsModule) stays here; the
            # heavy engine-swapped set is the shared thunk. Byte-identical.
            windowsEnginePkgs =
              if !wantWindowsModule then windowsPkgs else windowsEnginePkgsShared;
            windowsRawHooked = pkgs:
              if wantCosmoModule
              then multicallModuleHookCosmo
                {
                  package = name;
                  inherit (multicallCosmo) program programObjs;
                  appletArchives = multicallCosmo.appletArchives or [ ];
                  gnulibArchives = multicallCosmo.gnulibArchives or [ ];
                }
                (windowsRawBuild pkgs)
              else if wantWindowsModule
              then multicallModuleHookLTO
                {
                  package = name;
                  inherit (multicall) programs;
                  internalArchives = multicall.internalArchives or [ ];
                  inferLinkInputs = multicall.inferLinkInputs or true;
                  llvm = "${unpinToolchain windowsPkgs.stdenv.buildPlatform.system}/bin/llvm";
                  # mingw API is __declspec(dllexport); strip so internalize folds
                  # the module to one external (see hook's stripStep).
                  stripDllexport = true;
                }
                (windowsRawBuild pkgs)
              else windowsRawBuild pkgs;
            # Man source for the windows/cosmo binary. The cross build ships no
            # man, so the version-locked x86_64-linux nixpkgs graft is borrowed ONLY
            # when the cross build ships none of its own (the rare help2man package);
            # an explicit `winManRoot` wins outright. `winManGraft` is null for
            # custom-named multicall packages (no matching nixpkgs attr).
            winManNixpkgs = nixpkgs.legacyPackages.${"x86_64-linux"};
            winManGraft =
              let p = winManNixpkgs.${pkgsAttr} or null;
              in if p == null then null else (p.man or p.out or p);
            windowsBase = dropSharedLibs (applyOptSsp (windowsRawHooked
              (if wantWindowsModule then windowsEnginePkgs else windowsPkgs)));
            # Force a full [bin out] strip in the cross build itself — the cosmo /
            # mingw stdenv's OWN strip (APE-aware) — so unpinEmbedWrap copies an
            # already-stripped binary (stripCmd = ":") and never runs the engine
            # llvm-strip on a cosmo APE. The `module` output rides in this same
            # build, so the manifests reference the very build the binary ships from
            # (the [bin out] forcing the linux path used for the same reason).
            windowsForEmbed = windowsBase.overrideAttrs (_: { stripAllList = [ "bin" "out" ]; });
            # Windows embed defaults; a VFS flake's `runtimeEmbed.windows` overrides
            # (manRoot graft, runtimeStage, explicit aliases). The cross build ships
            # no man, so the man source is `winManRoot` (explicit) or the
            # version-locked nixpkgs graft (`winManGraft`). cosmoSymtabTrim drops
            # cosmo's `.symtab.amd64` ZIP member (no-op on mingw).
            windowsEmbedOpts = {
              primary = binName;
              man = embedMan;
              manRoot = if winManRoot != null then "${winManRoot}" else null;
              manFallback = if winManGraft == null then null else "${winManGraft}";
              stripCmd = ":";
              cosmoSymtabTrim = true;
            } // (if runtimeEmbedWindows != null then runtimeEmbedWindows windowsPkgs windowsForEmbed else { });
            windowsPkg0 = withLicense (
              # Un-migrated flake that still embeds in its own windowsBuild keeps the
              # legacy in-build embed + strippedOrJoined (deleted post-migration).
              if windowsBase.unpinEmbedsMan or false
              then strippedOrJoined windowsPkgs name
                (withCosmoStrip windowsPkgs { primary = binName; } windowsForEmbed)
              else unpinEmbedWrap windowsPkgs windowsEmbedOpts windowsForEmbed);
            # The manifest the mega-builder's cosmoMode consumes. The module
            # buckets reference the same built drv's `module` output; external
            # depArchives are verbatim store paths (passthru, NOT linked into the
            # shipped binary).
            cosmoMulticallManifest =
              let entry = "unpin__${sanMcW name}__${sanMcW multicallCosmo.program}_main";
              in {
                moduleFormat = "cosmo-elf";
                moduleObjs = "${windowsForEmbed.module}/objs";
                appletDir = "${windowsForEmbed.module}/applet";
                gnulibDir = "${windowsForEmbed.module}/gnulib";
                depArchives =
                  let d = multicallCosmo.depArchives or [ ];
                  in if builtins.isFunction d then d windowsPkgs else d;
                # Auto-derived from the cosmo cross build's input closure
                # (e.g. bash → cosmo readline/ncurses); globbed at build time.
                depInputDirs = multicallExternalDepDirs windowsForEmbed;
                applets =
                  [{ name = multicallCosmo.program; inherit entry; }]
                  ++ map (al: { name = al; inherit entry; }) (multicallCosmo.aliases or [ ]);
                requires = { cxx = false; } // (multicallCosmo.requires or { });
              };
            # Bitcode multicall manifest the mega folds (mingw counterpart of the
            # linux/cosmo manifests). moduleArchive/nativeArchive reference the same
            # built drv's `module`; external depArchives are verbatim store paths
            # (passthru, NOT linked into the shipped windows binary).
            windowsMulticallManifest = {
              package = name;
              moduleFormat = "bitcode";
              moduleArchive = "${windowsForEmbed.module}/lib/module.bc";
              nativeArchive = "${windowsForEmbed.module}/lib/module_native.a";
              depArchives =
                let d = multicall.depArchives or [ ];
                in if builtins.isFunction d then d windowsEnginePkgs else d;
              depInputDirs = multicallExternalDepDirs windowsForEmbed;
              applets = nixpkgs.lib.concatMap
                (p:
                  let entry = "unpin__${sanMcW name}__${sanMcW p.name}_main"; in
                  [{ name = p.name; inherit entry; }]
                  ++ map (al: { name = al; inherit entry; }) (p.aliases or [ ]))
                multicall.programs;
              requires = { cxx = false; group = true; } // (multicall.requires or { });
              manRoot =
                if embedMan then "${windowsForEmbed.man or windowsForEmbed}" else null;
              runtimeDataRoot =
                let r = multicall.runtimeDataRoot or null;
                in
                if r == null then null
                else if builtins.isFunction r then r windowsEnginePkgs
                else r;
            };
            windowsPkg =
              if wantCosmoModule
              then windowsPkg0 // { cosmoMulticallModule = cosmoMulticallManifest; }
              else if wantWindowsModule
              then windowsPkg0 // { windowsMulticallModule = windowsMulticallManifest; }
              else windowsPkg0;

            # `linuxOnly` drops every Darwin attr from `packages.<sys>` so the
            # auto-discovered CI matrix skips darwin runners. For tools whose
            # nixpkgs `meta.platforms` excludes darwin (kmod, util-linux, shadow,
            # procps-ng — Linux-only kernel APIs).
            wantsNative = system: nativeBuild && !(linuxOnly && isDarwinSys system);
          in
          {
            packages = forAllNative (system:
              let pkgs = nixpkgsFor.${system}; in
              nixpkgs.lib.optionalAttrs (wantsNative system) { default = stripped pkgs; }
              // nixpkgs.lib.optionalAttrs (wantsNative system && system == "aarch64-darwin") {
                "darwin-x86_64" = stripped pkgs.pkgsCross.x86_64-darwin;
              }
              // nixpkgs.lib.optionalAttrs (nativeBuild && system == "x86_64-linux") {
                # withLLDLink: the gc overlay is Linux-native only, so the cross
                # scopes get the standard lld link via NIX_CFLAGS_LINK here — keeps
                # the linker uniform across every non-mac target. The cross nixpkgs
                # set is `sharedCrossPkgs.<attr>` when the catalog mega prebuilt it
                # (one fixpoint shared across the fold), else imported per-flake.
                "linux-i686" = stripped (withLLDLink pkgsAttr
                  (sharedCrossPkgs."linux-i686" or pkgs.pkgsCross.musl32));
                # musl-power = powerpc64le-unknown-linux-musl. Debian calls it
                # "ppc64el" but uname returns "ppc64le" and the Rust ecosystem
                # (rustup, binstall) labels it the same way — we follow uname.
                "linux-ppc64le" = stripped (withLLDLink pkgsAttr
                  (sharedCrossPkgs."linux-ppc64le" or pkgs.pkgsCross.musl-power));
                # riscv64 has no pre-cooked musl variant in nixpkgs.pkgsCross
                # (only glibc). Spell the crossSystem out by triple.
                "linux-riscv64" = stripped (withLLDLink pkgsAttr
                  (sharedCrossPkgs."linux-riscv64" or (import nixpkgs {
                    inherit system;
                    crossSystem = { config = "riscv64-unknown-linux-musl"; };
                  })));
              }
              // nixpkgs.lib.optionalAttrs (nativeBuild && system == "aarch64-linux") {
                # armv7l-unknown-linux-musleabihf: pkgsCross has no musl example
                # for armv7l (muslpi is armv6), so spell the crossSystem out (like
                # riscv64). Spelling it musl-direct rather than relying on
                # pkgsStatic's glibc→musl swap keeps the glibc top scope from
                # leaking into consumer `build` closures (the Rust path); inner
                # static drvs are drv-hash-identical either way. The triple = HF
                # (VFPv3) + 64-bit atomics (LDREXD/STREXD): Pi 2/3/4 32-bit,
                # BeagleBone, the dominant ARM 32-bit Linux hardware, matching the
                # Rust convention. Drops armv6 (Pi 1/Zero) — worth it, since 64-bit
                # atomics (libssh2, glib ≥ 2.68) fail to link on armv6 (musl ships
                # no libatomic in pkgsStatic).
                "linux-armv7l" = stripped (withLLDLink pkgsAttr
                  (sharedCrossPkgs."linux-armv7l" or (import nixpkgs {
                    inherit system;
                    crossSystem = { config = "armv7l-unknown-linux-musleabihf"; };
                  })));
              }
              // nixpkgs.lib.optionalAttrs (windowsEnabled && system == "x86_64-linux") {
                "windows-x86_64" = windowsPkg;
              });

            apps = forAllNative (system:
              nixpkgs.lib.optionalAttrs (wantsNative system) {
                default = {
                  type = "app";
                  program = "${self.packages.${system}.default}/bin/${binName}";
                };
              });

            # UNOFFICIAL "tier-3" arches, deliberately NOT in the CI matrix
            # (action-build discovers the matrix from `.#packages` only), yet
            # available from a clone: `nix build .#cross.powerpc`. `cross` is a
            # FLAT attrset, so `.#cross.<arch>` resolves with no currentSystem
            # insertion — hence the hardcoded `x86_64-linux` build host (flake
            # purity forbids builtins.currentSystem; a non-x86_64-linux cloner
            # needs an x86_64-linux builder). Each entry maps a uname-style name to
            # its musl triple, built like the official crosses. Add one per arch
            # AFTER validating it builds + smoke-runs under qemu.
            cross = let
              mk = triple: stripped (withLLDLink pkgsAttr (import nixpkgs {
                system = "x86_64-linux";
                crossSystem = { config = triple; };
                # `.#cross` is best-effort: a niche arch may be absent from a
                # package's `meta.platforms` whitelist only because no maintainer
                # blessed it, so bypass the gate (like the windows block). No-op for
                # already-whitelisted arches.
                config.allowUnsupportedSystem = true;
              }));
              # x86-64 micro-architecture feature levels (psABI 2020): same triple
              # as default x86_64, higher `-march` baseline via gcc.arch. A vN binary
              # SIGILLs below its level, so this is a perf OPT-IN, not portability
              # (default x86_64 stays v1, the "runs anywhere" floor). v2≈Nehalem
              # (SSE4.2), v3≈Haswell (AVX2/FMA), v4 (AVX-512).
              mkV = arch: stripped (withLLDLink pkgsAttr (import nixpkgs {
                system = "x86_64-linux";
                crossSystem = { config = "x86_64-unknown-linux-musl"; gcc.arch = arch; };
                config.allowUnsupportedSystem = true;
              }));
            in nixpkgs.lib.optionalAttrs nativeBuild (builtins.mapAttrs (_: mk) {
              # ── Official CI targets, mirrored so `.#cross.<arch>` is a UNIFORM
              # interface. These spell out the exact triples the official
              # `.#packages` crosses use, so the derivations are IDENTICAL (cache
              # hits, byte-for-byte the CI binary; allowUnsupportedSystem is an eval
              # gate, not a hash input). x86_64 is the native `.#default`.
              i686 = "i686-unknown-linux-musl";
              ppc64le = "powerpc64le-unknown-linux-musl";
              riscv64 = "riscv64-unknown-linux-musl";
              aarch64 = "aarch64-unknown-linux-musl";
              armv7l = "armv7l-unknown-linux-musleabihf";

              # ── Unofficial tier-3 arches (curated, NOT in the CI matrix) ──
              # i586 (Pentium baseline). Distinct from `i686`: has CMPXCHG8B but no
              # CMOV, so an i686 binary SIGILLs on it. Niche: AMD Geode (ALIX
              # routers, OLPC XO-1), Vortex86, K6 — distros dropped it (Debian
              # "i386"/Alpine x86 are i686). NOT i386/i486 (dead; i486 lacks
              # CMPXCHG8B → libatomic for near-zero gain).
              i586 = "i586-unknown-linux-musl";
              powerpc = "powerpc-unknown-linux-musl";
              m68k = "m68k-unknown-linux-musl";
              loongarch64 = "loongarch64-unknown-linux-musl";
              # Raspberry Pi 1 / Zero / Zero W (BCM2835, ARM1176 = ARMv6 hard-
              # float). uname/Rust name `armv6l`; NOT Alpine's `armhf` (=ARMv6)
              # nor Debian's `armhf` (=ARMv7) — those names collide, uname wins.
              # Note: ARMv6 lacks LDREXD, so 64-bit atomics route through GCC's
              # libatomic (lock fallback) — needs explicit `-latomic` for
              # atomic-using packages; bash is single-threaded so it links clean.
              armv6 = "armv6l-unknown-linux-musleabihf";
              # Routers / NAS / IoT (OpenWrt) — MIPS little-endian. The single
              # static-musl binary fits devices with no package manager + tiny
              # flash. Biggest living "weird hardware" niche.
              mipsel = "mipsel-unknown-linux-musl";
              # IBM Z / mainframe (Linux on Z) — big-endian, enterprise niche.
              s390x = "s390x-unknown-linux-musl";
              # 32-bit RISC-V — embedded / microcontroller-class boards.
              riscv32 = "riscv32-unknown-linux-musl";
              # MIPS32 BIG-endian — older BE routers / embedded that the
              # little-endian `mipsel` above doesn't cover. Routes via ld.bfd
              # (isMips) like mipsel.
              mips = "mips-unknown-linux-musl";
              # MIPS64 (n64 ABI). musl's mips64 port is n64 ONLY, so spell out
              # `muslabi64` — the bare `...-musl` parses as gcc's default n32 and
              # mismatches musl. el = Loongson 3; BE = Cavium Octeon + BE network
              # gear. isMips → ld.bfd.
              mips64el = "mips64el-unknown-linux-muslabi64";
              mips64 = "mips64-unknown-linux-muslabi64";
              # PowerPC 64-bit BIG-endian — distinct from the shipped `ppc64le`
              # (LE). Retro/niche: PS3 Linux (Cell), Power Mac G5 64-bit,
              # AIX-era POWER. Routes via ld.bfd (isPower) like powerpc.
              powerpc64 = "powerpc64-unknown-linux-musl";
              # NOTE: sparc64 is intentionally absent — musl has no SPARC port
              # at all (`configure: unknown or unsupported target
              # "sparc64-unknown-linux-musl"`), so it can't be built under the
              # static-musl model these binaries rely on. It would need glibc,
              # which breaks self-containment. Don't re-add without a libc story.
              #
              # NOTE: x32 (x86_64 ILP32) is kept OUT — not impossible (musl has an
              # x32 port that builds + smoke-runs, see playground/x32-spike) but
              # nixpkgs' lib.systems has no `muslx32` ABI, so it'd need PATCHING the
              # nixpkgs source in 3 spots (lib.systems evaluates before pkgs, so no
              # overlay reaches it). Every other entry is a free curated triple; x32
              # alone would force an applyPatches on the catalog-wide nixpkgs. Not
              # worth the niche. (Smoke also needs qemu-system; qemu-user has no x32.)
            }
            // builtins.mapAttrs (_: mkV) {
              # x86-64 perf feature levels (see mkV above). v1 == default x86_64.
              "x86_64-v2" = "x86-64-v2";
              "x86_64-v3" = "x86-64-v3";
              "x86_64-v4" = "x86-64-v4";
            });

            # Read by unpins/action-build to drive CI config.
            manifest = {
              inherit name package_data bootstrap_naming own_software nativeBuild;
              # null unless the caller opted in; otherwise a list of CLI args,
              # JSON-encoded so build.yml runs `<bin> <args>` after each build.
              smoke = if smoke == null then null else smoke;
              # Optional grep-E pattern matching the smoke command's stdout+stderr.
              smoke_pattern = if smokePattern == null then null else smokePattern;
              # Per-package darwin portability exception (PrivateFramework names).
              darwin_allow_private_frameworks = darwinAllowPrivateFrameworks;
            };
            inherit unpinRecipe;
          };

        # Rust-crate flake template. A thin wrapper over mkStandaloneFlake
        # supplying Rust-aware build closures. Two source modes (nixpkgs attr vs
        # own-source, see `src`) × two dep shapes (pure Rust vs vendored C, see
        # `vendoredC`). Crates with real external C/TLS deps (ring, openssl-sys)
        # are out of scope — see unpins/unpin.
        #
        #   native linux/darwin → pkgs.pkgsStatic.<pkgsAttr> (recipe as-is).
        #   cross-musl (i686/armv7l/ppc64le/riscv64/aarch64) → pure Rust: NO C
        #     cross toolchain — rustup's rust-std for *-musl bundles musl's
        #     libc.a + crt and the host ld.lld links any ELF arch; rustc/cargo run
        #     native. With vendoredC, the C catalog's cached scopes supply the C
        #     compiler/linker instead.
        #   cross darwin → nixpkgs cross rustPlatform + the pkgsStatic.libiconv pin
        #     + a build-arch -L for proc-macro dylib links.
        #   windows → pkgs.pkgsCross.mingwW64.<pkgsAttr>.
        #
        # dnsFallback is forced off (its unsalted NIX_LDFLAGS leaks the
        # arch-specific libunpindns.a into crate build-script links); asking for it
        # here is an eval-time error. The consumer passes its own `rust-overlay`
        # input, so nix-lib takes no new input and the C lock files are untouched.
        mkRustCrate =
          { self
          , name
          , rust-overlay
          , pkgsAttr ? name
          # Own-source crate (the project's own Rust tools — unpin-man,
          # unpin-readme): pass all three of src / version / cargoLock (path
          # to the Cargo.lock). Default (null) reuses the nixpkgs recipe for
          # `pkgsAttr` — src, cargoHash and meta come from nixpkgs.
          , src ? null
          , version ? null
          , cargoLock ? null
          # True when the crate's dep closure compiles vendored C through a
          # build.rs (the cc crate — e.g. unpin-man's mandoc render subset).
          # Chain-free linking is impossible then: the musl crosses build
          # through the SAME top cross scopes the C catalog already caches
          # (musl32, musl-power, the spelled-out riscv64/armv7l), so no new
          # toolchain is ever built — and rust-overlay's rustc still avoids
          # any cross-rustc source bootstrap.
          , vendoredC ? false
          , ...
          }@args:
          let
            ownSource = src != null;

            # The buildRustPackage shape shared by every own-source scope —
            # the proven unpin/unpin-readme/unpin-man recipe.
            mkOwn = { rustPlatform, env ? { }, auditable ? true }:
              (rustPlatform.buildRustPackage {
                pname = name;
                inherit version src auditable env;
                cargoLock.lockFile = cargoLock;
                doCheck = false;
              }).overrideAttrs (_: { stripAllList = [ "bin" ]; });

            rustPkgsFor = system: import nixpkgs {
              inherit system;
              overlays = [ rust-overlay.overlays.default ];
            };
            toolchainFor = system: triple:
              (rustPkgsFor system).rust-bin.stable.latest.default.override {
                targets = [ triple ];
              };

            # Chain-free cross-musl (pure Rust): rust-std bundles musl's libc.a +
            # crt, the native ld.lld links any ELF arch; rustc/cargo run native.
            muslCrossPure = pkgs:
              let
                # Eval-only peek: pkgsStatic elaborates the static-musl host. No
                # derivation from the cross scope is ever built.
                triple = pkgs.pkgsStatic.stdenv.hostPlatform.rust.rustcTarget;
                npkgs = rustPkgsFor pkgs.stdenv.buildPlatform.system;
                rust = toolchainFor pkgs.stdenv.buildPlatform.system triple;
                base = if ownSource then null else npkgs.${pkgsAttr};
                bin =
                  if ownSource then args.binName or name
                  else base.meta.mainProgram or name;
              in
              npkgs.stdenv.mkDerivation {
                pname = "${pkgsAttr}-${triple}";
                version = if ownSource then version else base.version;
                src = if ownSource then src else base.src;
                meta = if ownSource then { mainProgram = bin; } else base.meta;
                cargoDeps =
                  if ownSource
                  then npkgs.rustPlatform.importCargoLock { lockFile = cargoLock; }
                  else base.cargoDeps;
                nativeBuildInputs = [
                  rust
                  npkgs.rustPlatform.cargoSetupHook
                  npkgs.lld
                ];
                # ld.lld by name → rustc infers the gnu-lld flavor;
                # link-self-contained uses rust-std's bundled musl crt/libc; -C
                # strip replaces the fixup strip (can't edit a foreign-arch ELF).
                env.RUSTFLAGS = "-C linker=ld.lld -C link-self-contained=yes -C target-feature=+crt-static -C strip=symbols";
                dontStrip = true;
                buildPhase = ''
                  runHook preBuild
                  cargo build --release --offline --target ${triple}
                  runHook postBuild
                '';
                installPhase = ''
                  runHook preInstall
                  install -Dm755 target/${triple}/release/${bin} $out/bin/${bin}
                  runHook postInstall
                '';
              };

            # Cross-musl with vendored C: the scope's makeRustPlatform bakes
            # --target + CC_<T>/CARGO_TARGET_<T>_LINKER to that scope's cached C
            # cross toolchain; rust-overlay supplies rustc/cargo native. crt-static
            # because rust-overlay's musl specs default it off; auditable=false (the
            # unpin precedent).
            muslCrossVendored = pkgs:
              let
                rust = toolchainFor pkgs.stdenv.buildPlatform.system
                  pkgs.stdenv.hostPlatform.rust.rustcTarget;
                rp = pkgs.makeRustPlatform { cargo = rust; rustc = rust; };
              in
              if ownSource then
                mkOwn {
                  rustPlatform = rp;
                  auditable = false;
                  env.RUSTFLAGS = "-C target-feature=+crt-static";
                }
              else
                (pkgs.${pkgsAttr}.override { rustPlatform = rp; }).overrideAttrs (_: {
                  RUSTFLAGS = "-C target-feature=+crt-static";
                });

            rustBuild = pkgs:
              let
                host = pkgs.stdenv.hostPlatform;
                cross = host.config != pkgs.stdenv.buildPlatform.config;
              in
              if !cross then
                (if ownSource then
                  mkOwn {
                    rustPlatform = pkgs.pkgsStatic.rustPlatform;
                    env.RUSTFLAGS = "-C relocation-model=static";
                  }
                else pkgs.pkgsStatic.${pkgsAttr})
              # Within-darwin cross (CI builds x86_64-darwin from arm64): build
              # against the host's default rustPlatform. rustc's `-liconv` (target
              # and build-host links) is handled centrally by withDarwinIconv, so
              # no per-path iconv wiring here.
              else if host.isDarwin then
                (if ownSource then mkOwn { rustPlatform = pkgs.rustPlatform; }
                else pkgs.${pkgsAttr})
              else if vendoredC then muslCrossVendored pkgs
              else muslCrossPure pkgs;

            # auditable=false on mingw: rustc + LTO + cargo-auditable
            # overflows mingw's 32-bit relocation limit (unpin precedent).
            rustWindowsBuild = pkgs:
              if ownSource then
                mkOwn {
                  rustPlatform = pkgs.pkgsCross.mingwW64.rustPlatform;
                  auditable = false;
                }
              else pkgs.pkgsCross.mingwW64.${pkgsAttr};
          in
          assert nixpkgs.lib.assertMsg (!(args.dnsFallback or false))
            "mkRustCrate: dnsFallback is unsupported for Rust crates (the unsalted NIX_LDFLAGS breaks crate build scripts) — see unpins/unpin for bespoke wiring";
          assert nixpkgs.lib.assertMsg (!ownSource || (version != null && cargoLock != null))
            "mkRustCrate: own-source mode needs all three of src / version / cargoLock";
          mkStandaloneFlake (
            builtins.removeAttrs args [ "rust-overlay" "src" "version" "cargoLock" "vendoredC" ]
            // {
              build = args.build or rustBuild;
              windowsBuild = args.windowsBuild or rustWindowsBuild;
              dnsFallback = false;
            }
          );

        # mkPkgsLTO: pkgsStatic with a chain-wide LTO overlay. Every drv in
        # the closure rebuilds with -flto + gcc-ar + --gc-sections. Stack
        # protector kept via -Wl,-u,__stack_chk_fail. See ./lto.nix.
        # Consumed by mkStandaloneFlake when `lto = true`.
        mkPkgsLTO = import ./lto.nix { inherit nixpkgs appendCFlags; };

        # mkPkgsGC: pkgsStatic with a chain-wide function/data-sections overlay
        # (cheap dead-code stripping; see gc.nix). Enabled via
        # `optimize.gc = true`. Linux-native only.
        mkPkgsGC = import ./gc.nix { inherit nixpkgs appendCFlags appendLinkFlags lldRSafe; };

        # Native cosmoStdenv. Result is `stdenv // { cosmocc,
        # cosmoCCUnwrapped, cosmoBintoolsUnwrapped, platformBits, mkCrossWiring,
        # version }`; consumers usually want `.mkDerivation` and `.platformBits`.
        cosmoStdenv = pkgs: import ./cosmocc.nix { inherit pkgs; };

        # `cosmoStaticCross pkgs` — symmetric with `pkgsCross.mingwW64`/
        # `pkgsStatic`: takes a build-host pkgs set (with cosmo wiring registered,
        # e.g. windowsPkgs) and returns the cosmo cross set. Per-binary quirks live
        # in the consumer's `windowsBuild = import ./cosmo.nix`. Cross-arch cosmo
        # (aarch64-cosmo from x86_64-linux) needs a buildPackages.pkgsCross stanza
        # — not exposed yet (no catalog package needs it).
        cosmoStaticCross = pkgs: pkgs.pkgsCross.cosmo;

      };

      # Per-target fixes, auto-loaded from sibling directories (consumed by
      # mkStandaloneFlake/mingwStaticCross). Fix files use both nixpkgs.lib and
      # our helpers, fused into one `lib` so they write `lib.X` uniformly.
      # `nativeFixes` is re-exposed inside that lib (and to consumer `build`
      # closures via `unpins-lib.lib.nativeFixes.<dep>`, e.g. tmux reusing
      # `lib.nativeFixes.libevent`). Safe under laziness — cross-fix references
      # resolve only when the consumer calls with `pkgs`.
      fixLibBase = nixpkgs.lib // lib;
      # A native-overlay file is EITHER a bare `pkgs: drv` fix (applied by name —
      # in defaultRawBuild, or by a consumer's own build closure) OR a self-
      # declaring `{ autoWire = "musl" | "static"; apply = pkgs: drv; }` for a
      # transitive engine DEP that no consumer fixes by hand. The latter are
      # folded into the pkgsStatic engine overlay automatically (autoWiredFixes,
      # consumed in mkStandaloneFlake) — replacing the old hand-kept
      # engineDepFixAttrs list. Either shape, `nativeFixes.<n>` normalizes to the
      # `pkgs: drv` function so every existing consumer is unchanged; the
      # {autoWire, apply} metadata is carried only by autoWiredFixes.
      rawNativeFixes = import ./native-overlay { lib = fixLibBase // { inherit nativeFixes; }; };
      nativeFixes = builtins.mapAttrs
        (_: v: if builtins.isFunction v then v else v.apply)
        rawNativeFixes;
      autoWiredFixes = nixpkgs.lib.filterAttrs
        (_: v: builtins.isAttrs v && v ? autoWire)
        rawNativeFixes;
      mingwOverlayFixes = import ./mingw-overlay { lib = fixLibBase; };
    in
    {
      lib = lib // { inherit nativeFixes; };
      # LOCAL DEBUG (uncommitted): expose the darwin-host unpin-llvm toolchain
      # build so we can validate it assembles/builds on a darwin build host
      # (the mac→mac engine step). Not part of the committed nix-lib surface.
      packages.x86_64-darwin.unpin-toolchain = lib.unpinToolchain "x86_64-darwin";
    };
}
