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

        # =================================================================
        # unpin-stdenv (route A): a bespoke stdenv over the standalone
        # `unpin-llvm` multicall toolchain — clang/lld + an on-demand,
        # variant-aware musl/libc++ sysroot, no nixpkgs cc-wrapper. Lifted
        # verbatim from the playground spike (playground/unpin-stdenv).
        #
        # The `toolchain` derivation (the `unpin-llvm` package exposing
        # `bin/llvm`) is passed in by the CONSUMER, NOT taken as a nix-lib
        # flake input: nix-lib is fetched as `github:unpins/nix-lib`, and
        # `unpin-llvm` is not yet published, so a hard input here would make
        # nix-lib unresolvable for the whole catalog. Parameterising it keeps
        # nix-lib's closure {nixpkgs} only — every catalog package that does
        # NOT call these functions is completely unaffected. A consumer wires
        # `inputs.unpinLlvm` itself and passes
        # `toolchain = unpinLlvm.packages.<system>.default`.
        #
        # § keystone: a pre-baked, read-only sysroot per target. Linking (not
        # -c) triggers the on-demand build of libc/CRTs (and, when `cxx`,
        # libc++/libc++abi/libunwind); the resulting RO store-path is the
        # lock/write-free cache for every package built against this target.
        # Bake BOTH the non-PIC and PIC variant of each half: the cache is
        # variant-aware (-fPIC ⇒ a distinct entry), and many build systems
        # force -fPIC into CFLAGS even for a static target (zlib's configure:
        # `CFLAGS="${CFLAGS--O3} -fPIC"`). Without the PIC variant pre-baked,
        # such a build misses the RO sysroot, the toolchain tries to populate
        # the read-only store cache, the link fails, and configure silently
        # mis-detects. `native` gates the sanity run (cross can't run on the
        # builder); `cxx` gates the C++ half.
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

        # § unpinToolchain: the vendored `unpin-llvm` build (nix-lib/toolchain),
        # built from nix-lib's OWN pinned nixpkgs for the given build system — so
        # the toolchain's LLVM version is locked together with nix-lib (the
        # "versioned together" property). Lazy: only forced when a consumer calls
        # mkUnpinStdenv. Used as the default `toolchain` below so consumers don't
        # have to wire `unpin-llvm` themselves.
        # origPkgs replicates exactly what mkStandaloneFlake's `nixpkgsFor` hands a
        # package's `build` under the catalog defaults (optimize.gc = true,
        # ssp = true, opt = null) — i.e. the gc-sections overlay scoped to the
        # `llvm` package's chain. The toolchain build pulls pkgsStatic.{zlib,zstd}
        # (which are in that scope) as buildInputs, so this is what makes the
        # vendored toolchain byte-identical to the catalog `unpin-llvm` it was
        # validated as (same .drv → same already-built output, no rebuild).
        unpinToolchain = system:
          import ./toolchain {
            origPkgs = mkPkgsGC { inherit system; ssp = true; opt = null; pkgName = "llvm"; };
            inherit unpinPackTool;
          };

        # § mkUnpinStdenv (route A: bespoke, no cc-wrapper). Wrappers inject
        # -target/optClass/-flto after "$@"; the setup-hook exports
        # CC/CXX/AR/… + XDG_CACHE_HOME pointing at the RO sysroot. Returns
        # `{ sysroot, unpinCC, cc, mkDerivation }` where mkDerivation is
        # stdenvNoCC + this toolchain.
        #
        # stackSize: musl's default THREAD stack is 128 KB (it reads the ELF
        # PT_GNU_STACK memsz); glibc's is 8 MB. Software developed on glibc
        # routinely assumes that — a 137 KB single stack frame in ffmpeg's
        # ffv1 encoder, deep recursion, large on-stack buffers in a pthread.
        # So we bake the glibc-parity 8 MB as the DEFAULT for every package:
        # it's address-space only (lazily paged → no RAM cost), invisible to
        # thread-free packages, and kills a whole class of glibc→musl porting
        # crashes. Override per package via `stackSize` (null/false disables).
        # The flag is link-only: a guard strips it from compile-only calls
        # (-c/-S/-E/-M) so a configure probe under -Werror doesn't read the
        # clang -Wunused-command-line-argument as "flag unsupported".
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

        # § unpinAdapterStdenv (route B: a drop-in nixpkgs stdenv over unpin-llvm).
        # Where mkUnpinStdenv (route A) demands a hand-written recipe (CC/CXX +
        # configure+make, like the playground mkLz4/mkJq), this wraps the same
        # `llvm` toolchain in a real nixpkgs cc-wrapper so an UNMODIFIED nixpkgs
        # recipe builds through it: `pkgs.pkgsStatic.<name>.override { stdenv =
        # unpinAdapterStdenv {...}; }`. Modelled on cosmocc.nix's stdenv wiring.
        #
        # Three things make it work (each a trap learned the hard way):
        #  1. passthru.isGNU = true (NOT isClang) on the unwrapped cc — otherwise
        #     the nixpkgs clang wrapper injects `--gcc-toolchain=…` + gcc -B/-L,
        #     poisoning clang's self-contained VFS sysroot. isGNU + libc = null
        #     (in both wrapCCWith and wrapBintoolsWith) keeps the wrapper from
        #     adding ANY libc/gcc-for-libs flags: unpin-llvm brings its own
        #     compiler-rt/libc++/musl. Same trick cosmocc uses.
        #  2. The shims append ${optClass} after "$@" (route-A parity) so every
        #     invocation hits the SAME on-demand sysroot variant the seed warms.
        #  3. A WRITABLE, build-local XDG_CACHE_HOME seeded from the RO pre-baked
        #     sysroot. unpin-llvm's sysroot is keyed by a per-flag variant hash;
        #     a generic recipe uses flag combos the RO bake didn't cover, and
        #     writing into the /nix/store RO path fails ("mkdir … failed" → link
        #     silently falls back to a broken dynamic musl). The seed makes known
        #     variants hit warm; any new variant builds on demand in the copy.
        #
        # lto: when true, the cc/c++ shims also append `-flto`, so every object
        # the recipe compiles is LLVM BITCODE (not ELF). This is the prerequisite
        # for the bitcode-LTO multicall module emitter (multicallModuleHookLTO):
        # llvm-link/opt operate on bitcode, and a whole-program-LTO mega-link
        # folds the modules. Off by default (the engine's normal path stays -O2
        # ELF, which the objcopy-based multicallModuleHook needs). -flto is safe
        # on both compile and link; the cpp (-E) shim deliberately omits it
        # (clang warns "argument unused" under -E, which a -Werror configure
        # probe would read as unsupported). Mixing bitcode app objects with the
        # ELF musl libc.a from the RO sysroot is the standard LTO-app/non-LTO-libc
        # case — clang LTO-compiles the bitcode, then links libc.a normally.
        unpinAdapterStdenv =
          { pkgs, toolchain ? unpinToolchain pkgs.stdenv.buildPlatform.system
          , target, optClass ? "-O2", cxx ? true, native ? false, lto ? false
          , captureLinks ? false }:
          let
            sysroot = unpinSysroot { inherit pkgs toolchain; triple = target; inherit optClass native cxx; };
            ltoArg = if lto then " -flto" else "";
            # Records each executable link to a per-output sidecar (objs + .a,
            # split local vs /nix/store) — the source the multicall hook reads
            # back for a program's objs/internalArchives. Inputs are resolved to
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
              b="$(basename "$out")"
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
              mk() {
                cat > "$out/bin/$1" <<EOF
              #!/bin/sh
              ${captureCall}
              exec ${toolchain}/bin/llvm $2 -target ${target} "\$@" ${optClass}${ltoArg}
              EOF
                chmod +x "$out/bin/$1"
              }
              mk clang clang ; mk cc clang ; mk gcc clang
              mk clang++ clang++ ; mk c++ clang++ ; mk g++ clang++
              cat > $out/bin/cpp <<EOF
              #!/bin/sh
              exec ${toolchain}/bin/llvm clang -E -target ${target} "\$@"
              EOF
              chmod +x $out/bin/cpp
            '';
            # Target-PREFIXED tool names (`${target}-ar`, …). nixpkgs' cross
            # bintools-wrapper sources its tools as `$ldPath/${targetPrefix}ar`
            # etc., so a genuine cross (which `pkgsStatic.buildPackages.wrap…`
            # produces — see the wrapper block below) only finds them when they
            # carry the target prefix. Unprefixed tools left RANLIB empty under a
            # cross wrapper. The cc-wrapper, by contrast, sources UNPREFIXED
            # `clang`, so `ccUnwrapped` stays unprefixed.
            bintoolsUnwrapped = pkgs.runCommand "unpin-bintools-unwrapped-${target}"
              { passthru = { isGNU = true; targetPrefix = "${target}-"; }; } ''
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
            '';
            # Wrap from `pkgsStatic.buildPackages`, NOT `pkgsStatic` directly —
            # i.e. build the cc/bintools wrapper exactly the way nixpkgs builds
            # the wrapper for ANY cross stdenv, instead of enumerating helpers.
            #
            # A cc/bintools wrapper is a BUILD-platform derivation: its helper
            # executables — `coreutils` (`date`/`mktemp` in build phases),
            # `gnugrep` (the wrapper scripts' grep), `expand-response-params`
            # (run by every `ld` as `expandResponseParams "$@"`), and any future
            # ones — run on the build host. But a *spliced* package coerces to
            # its hostTarget value by default, so `pkgsStatic.wrapCCWith` (the
            # host/target set) defaults every helper to the static TARGET build.
            # `pkgsStatic` is itself always a gnu→musl cross, so even the native
            # case picks up musl-static helpers; on a real cross (ppc64le/
            # riscv64) they become FOREIGN binaries the build then execs →
            # `cannot execute binary file: Exec format error` (the grep/sed/
            # coreutils CI failures; masked locally only by a qemu binfmt
            # handler). The previous fix enumerated the three helpers and pinned
            # them to `buildPackages` by hand — a list to maintain as nixpkgs
            # adds wrapper helpers.
            #
            # `pkgsStatic.buildPackages.wrap…With` is the wrapper as a genuine
            # build-platform derivation: callPackage's splice resolves EVERY
            # helper to the build platform automatically — no per-tool list, no
            # foreign binary in the closure, no qemu. This is what nixpkgs' own
            # cross stdenv does. Two details make it work for our hand-rolled
            # toolchain: the salt still comes from `targetPlatform.config` = the
            # musl host (identical to the host-set wrapper, so bash's strict
            # `--host=…-musl` lookup still resolves), and the wrapper now runs in
            # genuine cross mode (host=build gnu, target=musl), which sources
            # PREFIXED bintools — hence `bintoolsUnwrapped`'s `${target}-` names
            # above. The cc-wrapper sources unprefixed `clang`, so `ccUnwrapped`
            # stays unprefixed.
            staticBuild = pkgs.pkgsStatic.buildPackages;
            # A genuine-cross wrapper names every tool `${target}-…` and emits NO
            # unprefixed alias (cross tools are prefixed-only). Our single LLVM
            # driver is target-agnostic, so consumers expect the bare names too:
            # the stdenv sets `CC=${target}-cc`, but bash pins `CC=${cc}/bin/cc`
            # by abspath and stray Makefiles call bare `gcc`/`ar`. Re-add an
            # unprefixed alias for every `${target}-` tool — restoring exactly the
            # tool set the old native-mode wrapper exposed (bash's CC_FOR_BUILD
            # pin already disambiguates the bare-`gcc` shadow on a real cross),
            # without disturbing the build-platform helper splice above.
            unprefixAliases = ''
              for f in "$out"/bin/${target}-*; do
                [ -e "$f" ] || continue
                b=''${f##*/}; u=''${b#${target}-}
                [ -e "$out/bin/$u" ] || ln -s "$b" "$out/bin/$u"
              done
            '';
            bintools = staticBuild.wrapBintoolsWith {
              bintools = bintoolsUnwrapped; libc = null; extraBuildCommands = unprefixAliases;
            };
            cc = staticBuild.wrapCCWith {
              inherit bintools; cc = ccUnwrapped; libc = null; extraPackages = [ ];
              extraBuildCommands = unprefixAliases;
            };
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
              '');
            captureHook = pkgs.makeSetupHook { name = "unpin-capture-links"; }
              (pkgs.writeText "unpin-capture-links.sh" ''
                export UNPIN_CAPTURE_LINKS=1
                export UNPIN_LINK_DIR="''${NIX_BUILD_TOP:-$TMPDIR}/.unpin-links"
              '');
          in
          # dontPatchELF: static-musl has no interp/RPATH for patchelf to touch.
          # hardeningDisable=all: match route-A's minimal flag set (clang accepts
          # the hardening flags, but fortify needs libc support musl only partly
          # provides). NOTE no dontStrip — unlike cosmocc's APE (apelink needs the
          # symtab), unpin-llvm's static-musl ELF strips fine and should, so
          # strippedOrJoined's final strip applies.
          pkgs.stdenvAdapters.addAttrsToDerivation
            { dontPatchELF = true; hardeningDisable = [ "all" ]; }
            ((pkgs.overrideCC pkgs.pkgsStatic.stdenv cc).override (old: {
              extraNativeBuildInputs = (old.extraNativeBuildInputs or [ ]) ++ [ seedHook ]
                ++ nixpkgs.lib.optional captureLinks captureHook;
            }));

        # Append `flags` (string or list) to NIX_CFLAGS_COMPILE.
        #
        # `__structuredAttrs = true` drvs (bash, findutils, grep, dash, …)
        # carry the flag inside `env.NIX_CFLAGS_COMPILE`. Writing a top-level
        # `NIX_CFLAGS_COMPILE` on top of that collides — nix's mkDerivation
        # refuses with "attribute set cannot contain any attributes passed to
        # derivation". So we detect where the existing value lives and append
        # in-place; never both.
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

        # Final-link flag set for a downstream link that happens OUTSIDE the
        # target pkg's own build (e.g. a multicall.nix post-link). These are
        # the unpins-standard linker options, applied uniformly:
        #
        #   * non-darwin  → lld is the linker (`-fuse-ld=lld`, GNU-compatible
        #     LLVM linker; needs `lld` on PATH — see lldFinalLink), plus
        #     `--gc-sections` (dead-section prune; benign without
        #     function-sections, the real win comes from the gc overlay's
        #     chain-wide -ffunction-sections on Linux-native) and
        #     `--icf=safe` (fold identical address-not-taken functions; a
        #     measured no-op on C, kept for catalog uniformity and the C++
        #     template tools). `--icf=all`/`--ignore-data-address-equality`
        #     deliberately NOT used: they break function/data-pointer identity
        #     (~−1.3% on aom but risks silent miscompiles in codec tables).
        #   * darwin      → "" (unchanged). The darwin compiler is clang + Apple
        #     ld64 (not lld) and the unpins allowlist/codesign path is sensitive
        #     to link changes, so we deliberately do NOT touch the mac link here.
        #     (ld64 could atom-dead-strip via `-dead_strip`, but that's a
        #     separate, mac-only change requiring its own rebuild + re-verify.)
        #
        # Only valid on a FULL link ($CC-driven), never on `ld -r` relocatable
        # partial-links (--gc-sections/--icf error there) — hence this lives on
        # the multicall post-link, not the global cc-wrapper.
        #
        # cosmo (Cosmopolitan APE; isWindows && !isMinGW) is excluded: cosmocc
        # is its own toolchain and doesn't take `-fuse-ld=lld`. It keeps its
        # native link (returns "").
        # Which targets use lld (the unpins standard linker). Excludes:
        #   * darwin → clang + Apple ld64 (allowlist/codesign is link-sensitive)
        #   * cosmo (isWindows && !isMinGW) → cosmocc, its own toolchain
        #   * riscv64 → lld can't link our C++ codec chains here: it emits
        #     "relocation refers to a symbol in a discarded section" (.L data
        #     and .LEHE C++ landing-pad labels) even with NO --gc-sections/--icf
        #     — a RISC-V linker-relaxation × section-discard bug in lld that
        #     GNU ld doesn't have. avif fails to link; the C-only aom happened
        #     to survive, but "lld for C but GNU for C++" is too fragile a
        #     split, so riscv64 stays on GNU ld wholesale (size-neutral — lld's
        #     options don't bite on the crosses anyway).
        # Which targets use lld (the unpins standard linker). Excludes the
        # two exotic cross arches whose lld backend has linker bugs GNU ld
        # doesn't — both stay on GNU ld (size-neutral: lld gives no size win
        # on the crosses, the gc gain is Linux-native only):
        #   * riscv64 → lld emits "relocation refers to a symbol in a
        #     discarded section" (RISC-V relaxation × section-discard) even
        #     without --gc-sections/--icf.
        #   * ppc64le → lld doesn't synthesize the PowerPC out-of-line FP
        #     save/restore routines (_savefpr_*/_restfpr_*, libgcc crtsavres)
        #     that GNU ld generates on demand, so any FP-heavy static link
        #     (e.g. busybox's awk/decompress) fails with undefined _restfpr_N.
        isLLDTarget = pkgs:
          let h = pkgs.stdenv.hostPlatform;
          in !(h.isDarwin)
          && !(h.isWindows && !(h.isMinGW or false))
          && !(h.isRiscV or false)
          && !(h.isPower or false)
          # m68k is a GNU-binutils-only target: ld.lld has no m68k backend
          # ("unknown emulation: m68kelf"), so fall back to ld.bfd like
          # riscv/power above. Without this, any $CC link via lld aborts.
          && !(h.isM68k or false)
          # Same story for the other tier-3 niche crosses exposed under
          # `.#cross`: lld's mips/s390x support is absent or incomplete, so
          # route them through ld.bfd (the binutils cross always ships it).
          # Safe even where lld *might* work — bfd still does --gc-sections;
          # matches what riscv/power already do.
          && !(h.isMips or false)
          && !(h.isS390 or false);

        # `ld.lld` aborts on a relocatable link that also carries `--icf`
        # ("-r and --icf may not be used together"). lldStdOpts carries
        # `--icf=safe`, and it reaches EVERY $CC link via NIX_CFLAGS_LINK /
        # makeFlagsArray — including the `$CC -r` relocatable partial-links
        # some build systems emit (busybox's kbuild links applets/built-in.o
        # that way). `--gc-sections` is -r-safe (lld ignores it on a
        # relocatable link); only `--icf` is fatal. So wrap ld.lld: strip
        # `--icf*` when the args contain -r/-i/--relocatable, pass everything
        # else straight through. The wrapper dir symlinks the rest of lld/bin,
        # so it's a drop-in target for `-B<dir>` and PATH — `-fuse-ld=lld`
        # resolves to the wrapper. `buildPkgs` is the build-platform scope
        # holding lld/bash/runCommand; callers pass the recursion-safe one
        # (e.g. `basePkgs.buildPackages` in a cross scope, see withLLDLink).
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
        # `-B<lld>/bin` makes the compiler driver find `ld.lld` for
        # `-fuse-ld=lld` WITHOUT needing lld on PATH — so this flag is fully
        # self-sufficient and every multicall package gets the standard linker
        # by just appending `${lib.gcSectionsFlag pkgs}` to its post-link, no
        # per-package nativeBuildInputs edit. (lld/bin ships ld.lld/lld-link
        # but no `ld`/`as`/`ar`, so -B can't shadow the binutils the build
        # otherwise uses.)
        gcSectionsFlag = pkgs:
          if isLLDTarget pkgs then
            "-B${lldRSafe pkgs.buildPackages}/bin ${lldStdOpts pkgs}"
          else "";

        # `lld` build tool for the scope. gcSectionsFlag's `-B` already makes
        # `ld.lld` findable, so this is only needed where a link uses
        # `-fuse-ld=lld` WITHOUT going through gcSectionsFlag (e.g. the
        # gc-overlay single-binary makeFlagsArray). Empty list off the lld
        # targets (darwin keeps ld64, cosmo keeps cosmocc).
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

        # Append to NIX_CFLAGS_LINK (cc-wrapper LINK-time flags),
        # structuredAttrs-aware like appendCFlags. Unlike NIX_LDFLAGS this
        # reaches ONLY $CC-driven links, never a direct `ld -r`, so
        # --gc-sections/--icf are safe to carry here.
        # Append to NIX_CFLAGS_LINK (cc-wrapper LINK-time flags),
        # structuredAttrs-aware like appendCFlags. Unlike NIX_LDFLAGS this
        # reaches ONLY $CC-driven links, never a direct `ld -r`, so
        # --gc-sections/--icf are safe to carry here.
        #
        # The `old ? env && old.env ? VAR` test is the right signal (NOT
        # `old.__structuredAttrs`, which is NOT visible in overrideAttrs' `old`):
        # when a structuredAttrs build presets `env.NIX_CFLAGS_LINK` (e.g. whois'
        # " -static") we MUST append inside `env`, since adding a top-level
        # NIX_CFLAGS_LINK would overlap and nixpkgs rejects the duplicate. When
        # the var is absent, a top-level scalar is exported fine even under
        # structuredAttrs (verified: withDnsFallback's top-level NIX_LDFLAGS
        # reaches whois' linker).
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
        # __wrap_getaddrinfo / __wrap_freeaddrinfo, linked into every
        # linux-static artifact. musl's resolver falls back to 127.0.0.1 when
        # /etc/resolv.conf is absent — which is the case on Android (no
        # resolv.conf; DNS lives behind Bionic + netd, unreachable from a
        # non-Bionic static binary), so every catalog binary fails to resolve.
        # The wrapper delegates to the real resolver in every normal case. It
        # takes over only when the OS resolver can't be REACHED (EAI_AGAIN) for a
        # real hostname AND the user OPTED IN to a fallback resolver — via
        # $UNPIN_DNS or a `dns =` line in unpin's config file, which the shim
        # reads itself so every unpins program honours it without an env var. The
        # fallback is OFF by default: with nothing configured it surfaces the real
        # error and calls a weak hook (unpin_dns_note_unreachable) that unpin
        # overrides to teach the user how to opt in — there is no built-in public
        # default, so it never fires without consent. If UDP/53 is itself blocked
        # (captive portals, port-53 firewalls), it can escalate to DoH over
        # HTTPS/443 through an OPTIONAL weak hook (unpin_readurl — a generic
        # "fetch this URL" call) that a binary carrying a TLS stack provides from
        # that stack: the Rust tools (unpin/unpin-readme) do, over rustls; a
        # networked C tool could over its libcurl/OpenSSL. Left unprovided, the
        # binary stays UDP-only at zero cost. See dns-fallback/dns-fallback.c for
        # the full contract.
        #
        # Built with the TARGET stdenv so it compiles per arch/OS — one C file,
        # three link mechanisms selected by #ifdef (see dns-fallback.c): musl/
        # mingw via `--wrap`, darwin via a getaddrinfo redefinition + dlsym. The
        # interposed symbol is also what Rust's std::net resolution emits, so this
        # fixes the Rust binaries (unpin/unpin-readme) with no Rust-side change.
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

        # Wrap a built drv's final link with the DNS fallback (linux-static
        # only; darwin/windows keep their native resolver). `--wrap` rides
        # NIX_LDFLAGS (not NIX_CFLAGS_LINK — that gets wiped in postConfigure by
        # some builds, e.g. whois). The lldRSafe ld wrapper strips `--wrap` from
        # any `-r` relocatable partial-link routed through ld.lld, so the wrap
        # applies only at the final full link. The archive is pulled by the
        # linker only when (and only when) getaddrinfo is referenced.
        #
        # `staticPkgs` is the static scope the drv was actually built in
        # (`pkgs.pkgsStatic` — NOT the native `pkgs` `stripped` receives, whose
        # hostPlatform is the glibc build host). Both the guard and the
        # archive's toolchain come from it, so the .a matches the consumer's
        # arch (native or cross-musl) exactly.
        # Interpose getaddrinfo per toolchain (see dns-fallback.c's header):
        #   - linux musl / windows mingw: GNU ld `--wrap`. NIX_LDFLAGS lands at
        #     the END of the link line, after the toolchain's own libc, and a
        #     static archive only satisfies references that come BEFORE it — so we
        #     re-state the libc AFTER our archive (`-lc` on linux; `-lws2_32`
        #     `-lmsvcrt` on windows, for the socket + CRT calls it makes).
        #     rustc's `-nodefaultlibs` link is what exposes this.
        #   - darwin: ld64 has no `--wrap`, so the archive DEFINES getaddrinfo/
        #     freeaddrinfo and we `-force_load` it to win over libSystem; the real
        #     ones are reached at runtime via dlsym(RTLD_NEXT).
        # The archive is pulled by the linker only when getaddrinfo is referenced.
        withDnsFallback = staticPkgs: drv:
          let h   = staticPkgs.stdenv.hostPlatform;
              lib = "${dnsFallbackLib staticPkgs}/lib";
          in if (h.isLinux && (h.isStatic or false))
             then appendLdFlags drv
               ("--wrap=getaddrinfo --wrap=freeaddrinfo -L${lib} -l:libunpindns.a -lc")
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
        # standard options, via NIX_CFLAGS_LINK (build-system agnostic —
        # cmake/meson/make all pass it to the cc-wrapper at link). Covers what
        # the gc overlay (Linux-native only, makeFlagsArray) and gcSectionsFlag
        # (multicall post-link) don't: SINGLE-BINARY packages on the cross
        # targets. Also harmlessly covers multicall on those scopes (libXApps
        # inherits pkgName's env; redundant with gcSectionsFlag). No-op on
        # darwin/cosmo and when pkgName is absent. Returns a full pkgs scope
        # (like mkPkgsGC) so `pkgs.pkgsStatic.<name>` reaches the overlay.
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

        # Remove .so/.dylib/.la/.dll/.dll.a from a drv's outputs; leave .a + headers + bins.
        # Build-system agnostic (postFixup, not configure flags).
        #
        # Why: GNU ld and Apple ld64 both prefer shared over .a in -L paths, and ld64 has
        # no `-Bstatic` analog. Removing the shared artifact post-build is the only
        # platform-neutral way to force a static link without patching the consumer.
        #
        # Self-guarded: pkgsStatic drvs already produce only .a; skip them to avoid busting
        # cache.nixos.org without changing the output.
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

        # Curated terminfo entries baked into libtinfo.a via ncurses
        # `--with-fallbacks=`. Covers what users actually hit across the
        # three OSes: legacy (xterm/vt100/ansi/dumb), Linux console
        # (linux), multiplexers (screen/tmux), Windows shells (mintty/
        # cygwin/ms-terminal/vscode), modern emulators (alacritty/foot/
        # kitty/ghostty), DE defaults (gnome/konsole), suckless (st),
        # rxvt, putty, macOS Terminal.app (nsterm), iTerm2 direct-color.
        #
        # Why bake at all: the unpins promise is "single binary that
        # runs anywhere" — we can't assume `/usr/share/terminfo` or
        # `/etc/terminfo` exists on the host (scratch containers, Alpine
        # without ncurses-terminfo-base, raw Windows, ...). Embedding
        # ~35 essentials keeps libedit / ncurses-TUI consumers
        # functional with zero data files. See docs/runtime-data.md for
        # the "complete coverage" path (data archive) — not yet wired.
        #
        # Modern entries that ncurses 6.6 (nixpkgs 26.05) doesn't ship
        # — `xterm-ghostty`, `xterm-kitty`, `rxvt-unicode*` — come from
        # `extra-terminfo.src` (appended pre-tic via
        # `embedFallbackTerminfo*`'s postPatch). The `xterm-…` aliases
        # are the names Ghostty/kitty actually set in $TERM by default;
        # ncurses' own `kitty`/`ghostty` entries lack those aliases, so
        # we ship the upstream-canonical entries separately.
        fallbackTerminals =
          "xterm,xterm-color,xterm-256color,ansi,vt100,vt102,vt220,dumb,"
          + "linux,mintty,cygwin,ms-terminal,vscode,"
          + "screen,screen-256color,tmux,tmux-256color,"
          + "alacritty,alacritty-direct,foot,"
          + "kitty,xterm-kitty,xterm-ghostty,wezterm,"
          + "gnome,gnome-256color,konsole,konsole-256color,"
          + "st,st-256color,Eterm,"
          + "rxvt,rxvt-256color,rxvt-unicode,rxvt-unicode-256color,"
          + "iterm2-direct,nsterm,putty,putty-256color";

        # Patch ncurses to (a) append `extra-terminfo.src` to the source
        # database so newer entries (ghostty, ...) are known to tic at
        # build time, then (b) add `--with-fallbacks=<fallbackTerminals>`
        # so each entry is compiled into libtinfo.a as a C array. Host
        # terminfo files still take precedence at runtime (database
        # lookup stays enabled).
        embedFallbackTerminfo = ncurses: ncurses.overrideAttrs (oa: {
          postPatch = (oa.postPatch or "") + ''
            cat ${./extra-terminfo.src} >> misc/terminfo.src
          '';
          configureFlags = (oa.configureFlags or [ ]) ++ [
            "--with-fallbacks=${fallbackTerminals}"
          ];
        });

        # Same as embedFallbackTerminfo plus `--disable-database` — the
        # compiled libtinfo.a no longer tries the runtime path lookup.
        # For Windows targets (cosmo, mingw) where the binary's
        # compiled-in `/nix/store/.../share/terminfo` doesn't exist on
        # the user's machine and there's no system convention to fall
        # back on; the only source of truth becomes the baked array.
        embedFallbackTerminfoOnly = ncurses: ncurses.overrideAttrs (oa: {
          postPatch = (oa.postPatch or "") + ''
            cat ${./extra-terminfo.src} >> misc/terminfo.src
          '';
          configureFlags = (oa.configureFlags or [ ]) ++ [
            "--disable-database"
            "--with-fallbacks=${fallbackTerminals}"
          ];
        });

        # Strip `--enable-static`/`--disable-shared` from configureFlags on
        # darwin. Background: pkgsStatic adds both flags to every derivation.
        # The configure.ac in many GNU-ish packages (dash, htop, ...)
        # translates `--enable-static` into `export LDFLAGS="-static"`, which
        # then breaks every subsequent AC_CHECK_LIB probe — darwin has only
        # libSystem.dylib, no libSystem.a. The probes fail and consumers
        # think their deps are missing (libedit, libsensors, ...).
        #
        # Filtering the flags lets each pkgsStatic input still contribute a
        # `.a` to the link line; only libSystem stays implicitly-dynamic,
        # matching the catalog's darwin policy. Applied automatically inside
        # `mkStandaloneFlake`'s native pipeline so individual fix files don't
        # need to repeat the workaround.
        #
        # Not applied to mingw / cosmo cross builds (no libSystem issue, and
        # --enable-static there is genuinely a static link request).
        filterEnableStaticOnDarwin = drv:
          if (drv.stdenv.hostPlatform.isDarwin or false)
          then drv.overrideAttrs (old: {
            configureFlags = nixpkgs.lib.filter
              (f: f != "--enable-static" && f != "--disable-shared")
              (old.configureFlags or [ ]);
          })
          else drv;

        # Darwin libiconv handling, applied automatically to every darwin build
        # in mkStandaloneFlake's pipeline (like filterEnableStaticOnDarwin) so
        # individual packages stop re-solving the same two iconv traps. macOS
        # keeps iconv in a standalone libiconv (not libSystem), and the darwin
        # portability allow-list permits only libSystem/libobjc/Frameworks — so
        # anything that references iconv must link it, and statically:
        #
        #  * Target link (every darwin build): C objects that reference iconv
        #    (libxml2.a's encoding.o, ...) and rustc's default `-liconv` need a
        #    libiconv to resolve against. Use the *static* libiconv — a leaf in
        #    pkgsStatic, so it doesn't drag in the broken cctools-static cascade
        #    — so the final binary carries no libiconv.2.dylib load command (the
        #    allow-list rejects that). The bare `-liconv` is appended to the
        #    unsalted NIX_LDFLAGS the target cc-wrapper reads; harmless when
        #    nothing references iconv (a static archive contributes only the
        #    objects that resolve undefined symbols — none, here).
        #
        #  * Build-host link (darwin CROSS only): cargo/cmake build scripts and
        #    proc-macro dylibs are linked for the BUILD host, and rustc appends
        #    `-liconv` there too, against the build cc-wrapper's salted
        #    NIX_LDFLAGS_<buildSalt> — which has no default path for it, so the
        #    build dies with "library not found for -liconv". Hand it a -L to the
        #    build-arch libiconv. CROSS-ONLY: on a native build the build salt
        #    equals the target salt, so this -L would instead pull a *dynamic*
        #    libiconv into the final binary and trip the allow-list.
        #
        # Darwin-only; linux/windows/cosmo drvs pass through untouched (windows
        # never reaches this pipeline anyway). See docs/platforms/darwin.md
        # ("the libiconv catch").
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

        # Embed a package's multi-call alias list into `$out/bin/<primary>` as a
        # `unpin/aliases` entry of the binary's embedded ZIP, so unpin's
        # installer can spawn argv[0]-dispatch links (xz → xzcat/unxz/lzma…) at
        # `unpin install` time. The container is a plain ZIP (one name per line
        # in `unpin/aliases`), located/read by unpin via the ZIP's native EOCD —
        # see docs/embedded-metadata.md and `unpin/src/meta.rs`. Embedding is the
        # shared `__unpin_embed_subtree` (see `unpinEmbedSh`).
        #
        # Two input modes (exactly one required):
        #   aliases = [ "xzcat" "unxz" "lzma" ];   # explicit list, Nix-eval-time
        #   aliasesFromSymlinksIn = "bin";         # harvest $out/bin/* symlinks
        #
        # `aliasesFromSymlinksIn` is the multicall pattern (coreutils,
        # busybox): upstream creates one symlink per applet next to the real
        # multicall binary. We collect them in postInstall, wipe the symlinks
        # (we ship one binary, the alias links are unpin's job at install time)
        # then embed the list in postFixup so the embed runs AFTER stdenv strip.
        #
        # Alias security (no marker needed): aliases are honored at install time
        # only for catalog-owner packages, and every name passes the blocklist —
        # both upstream of the reader. See docs/embedded-metadata.md §4.

        # Build-host-native tool that packs a staging `unpin/` tree into a
        # zstd-in-zip (ZIP method 93) overlay — the format `withMan` uses for the
        # man payload. Compresses with libzstd; shipped binaries decode method 93
        # with `unpin`'s pure-Rust ruzstd reader (unpin/src/meta.rs). Sources
        # vendored from unpins/unpin-vfs. `-DMINIZ_NO_TIME` zeroes entry mtimes
        # so the overlay is byte-reproducible.
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
        # staging tree (the ZIP-root layout: `unpin/...` metadata entries and/or
        # a VFS runtime tree) to the binary's embedded ZIP
        # (docs/embedded-metadata.md).
        # Every binary ends up with exactly ONE ZIP whose offsets are
        # file-adjusted (absolute) — the self-extracting-archive convention, so
        # `unzip <binary>` reads clean and cosmo's zipos can parse it (zipos
        # rejects zip-relative offsets). Two paths:
        #
        #  * cosmo: REWRITE the runtime's existing tail-ZIP. We must not append
        #    a second ZIP after it (cosmo finds its `/zip/` store via the
        #    end-of-file EOCD, and a trailing ZIP would shadow it), so
        #    unpin-vfs-pack `--carry` copies the existing entries verbatim —
        #    deflate/store preserved so cosmo still reads them, `.symtab.amd64`
        #    dropped — and adds ours as zstd (method 93) in the same archive.
        #  * everything else: there is no tail-ZIP, so truncate the binary back
        #    to its pre-embed size and append our ZIP.
        # Both ACCUMULATE the subtree in a per-binary staging dir and repack the
        # whole accumulated tree as one unpin-vfs-pack ZIP — zstd entries except
        # `unpin/aliases` deflate so pre-zstd readers still decode it. A later
        # call (withMan after withAliases) replaces the overlay with a superset
        # — idempotent, never two ZIPs.
        #
        # On Mach-O the overlay sits past LC_CODE_SIGNATURE, outside the signed
        # range — the kernel ignores it (smoke-proven on Apple Silicon).
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

        # ---- withUnpinEmbed: the ONE call that builds a package's embedded
        # container ---------------------------------------------------------
        #
        # Stages every kind of embedded payload into a single ZIP-root tree
        # and packs the binary's single EOF ZIP ONCE:
        #
        #   * aliases       → `unpin/aliases` (explicit list or symlink harvest)
        #   * man pages     → `unpin/man/*` via mkmeta.py (`man = true`, or an
        #                     explicit `manRoot`; optional `manFallback`)
        #   * runtime tree  → arbitrary entries at the ZIP root, served by the
        #                     unpin-vfs self-EOF mode (`runtimeStage` snippet,
        #                     run with $__unpin_stage = the empty ZIP root)
        #
        # withAliases / withMan / withRuntimeData below are thin wrappers over
        # this; composing several of them still works (the accumulator in
        # `unpinEmbedSh` repacks a superset), it just repacks once per call —
        # a package that passes everything here pays for ONE pack.
        #
        # When man is included, the result carries `passthru.unpinEmbedsMan =
        # true` and mkStandaloneFlake skips its own withMan application, so
        # the consumer's single call really is the only embed step.
        #
        # Failure policy: a missing primary binary is a hard error when the
        # call ships aliases or a runtime tree (the caller knows the layout),
        # but a warn-and-skip for man-only calls — embedMan is default-on
        # across the catalog and a man-less package is degraded, not broken.
        # An empty runtime stage always fails: a missing runtime tree is a
        # broken program.
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

            # Alias names are embedded verbatim — nix-lib does NOT validate
            # them. All alias policy (charset/length/leading-char rules,
            # Windows-reserved names, the catalog-owner gate, and the
            # credential-shadowing confirmation) lives solely in unpin and is
            # enforced at install time by `validate_alias` /
            # `alias_needs_confirmation` in unpin/src/aliases.rs — the single
            # canonical reference. Keeping a second copy here only let the two
            # drift (the build rejected names the installer had since relaxed,
            # e.g. uppercase or punctuation applet names). The build just ships
            # the declared list; the installer decides what is safe to link.
            explicitCsv =
              if hasExplicit
              then nixpkgs.lib.concatStringsSep "," aliases
              else "";

            # Pick the output the binary actually lives in. nixpkgs convention:
            # multi-output drvs put bins under the `bin` output (jq, htop in
            # some configs); pkgsStatic typically collapses to `out` even with
            # `info`/`debug` siblings (so `bin` is absent → fall back to `out`).
            # In the inline shell snippets below, `''${${binOutputName}}` renders
            # as e.g. `${bin}` or `${out}` for bash to expand to the path.
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
                  ${nixpkgs.lib.optionalString (runtimeStage != null) ''
                  ${runtimeStage}
                  # -print -quit: no pipe — stdenv phases run `set -o pipefail`,
                  # and a `find | grep -q` would die of grep's early-exit
                  # SIGPIPE on any tree bigger than the pipe buffer,
                  # misreading it as empty.
                  if [ -z "$(find "$__unpin_stage" -mindepth 1 \( -type f -o -type l \) -print -quit)" ]; then
                    echo "withUnpinEmbed: runtime stage produced no files for ${primary}" >&2
                    exit 1
                  fi
                  ''}
                  ${nixpkgs.lib.optionalString aliasesActive ''
                  ${if hasExplicit
                    then "__unpin_aliases='${explicitCsv}'"
                    else ''__unpin_aliases="$(cat "$NIX_BUILD_TOP/.unpin-aliases")"''}
                  # Short-circuit: nothing to stage when the collected list
                  # ended up empty (auto-mode: no symlinks matched the
                  # validator). Aliases are a security boundary, but that is
                  # enforced at install time (catalog-owner gate + blocklist),
                  # not here — we just ship the declared list.
                  if [ -z "$__unpin_aliases" ]; then
                    echo "withAliases: no aliases to embed for ${primary}, skipping" >&2
                  else
                    mkdir -p "$__unpin_stage/unpin"
                    printf '%s' "$__unpin_aliases" | tr ',' '\n' > "$__unpin_stage/unpin/aliases"
                  fi
                  ''}
                  ${nixpkgs.lib.optionalString manEnabled ''
                  # Locate the man tree to embed.
                  ${if manRoot != null then ''
                  # Externally supplied man source (windows/cosmo path).
                  __unpin_manroot="${manRoot}"
                  if [ ! -d "$__unpin_manroot/share/man" ]; then
                    echo "withMan: manRoot ${manRoot} has no share/man" >&2
                    __unpin_manroot=""
                  fi
                  '' else ''
                  # Harvest from the drv's own outputs (native path). nixpkgs
                  # puts man in the `man` output when present; pkgsStatic
                  # single-output drvs keep it in `out`/the bin output under
                  # share/man.
                  __unpin_manroot=""
                  for __unpin_d in "''${man:-}" "''${${binOutputName}}" "''${out:-}"; do
                    if [ -n "$__unpin_d" ] && [ -d "$__unpin_d/share/man" ]; then
                      __unpin_manroot="$__unpin_d"; break
                    fi
                  done${nixpkgs.lib.optionalString (manFallback != null) ''

                  # Cross build shipped no man pages of its own — either no
                  # share/man at all, or a share/man with no actual pages
                  # (e.g. a prune emptied man1/ and left only an empty tree).
                  # Borrow the version-locked pages from a man-bearing build
                  # (windows graft). -print -quit: no pipe (pipefail/SIGPIPE,
                  # see above).
                  if [ -d "${manFallback}/share/man" ] \
                     && { [ -z "$__unpin_manroot" ] \
                          || [ -z "$(find "$__unpin_manroot/share/man" \( -type f -o -type l \) -print -quit 2>/dev/null)" ]; }; then
                    __unpin_manroot="${manFallback}"
                  fi''}
                  ''}
                  if [ -z "$__unpin_manroot" ]; then
                    echo "withMan: no share/man found for ${primary}, skipping" >&2
                  else
                    # mkmeta.py populates a staging `unpin/man/` tree (roff
                    # files + symlinks for `.so`) in its OWN temp dir — merged
                    # into the shared stage only on success, so an exit-3 skip
                    # leaves no partial unpin/man behind. Exit 3 = no man pages
                    # (legit skip); any other nonzero = real failure → fail the
                    # build (don't silently ship man-less).
                    __unpin_manstage="$(mktemp -d)"
                    __unpin_rc=0
                    python3 ${./mkmeta.py} "$__unpin_manroot" "$__unpin_manstage" || __unpin_rc=$?
                    if [ "$__unpin_rc" = 3 ]; then
                      echo "withMan: no man pages for ${primary}, skipping" >&2
                    elif [ "$__unpin_rc" != 0 ]; then
                      echo "withMan: mkmeta.py failed (exit $__unpin_rc) for ${primary}" >&2
                      exit "$__unpin_rc"
                    else
                      cp -a "$__unpin_manstage/." "$__unpin_stage/"
                    fi
                    rm -rf "$__unpin_manstage"
                  fi
                  ''}
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

        # Thin wrapper over withUnpinEmbed — embed only the alias list. See
        # the doc block above unpinPackTool for the alias model (two input
        # modes, symlink harvest, security gates).
        withAliases = pkgs:
          { primary
          , aliases ? null
          , aliasesFromSymlinksIn ? null
          }: drv:
          if aliases == null && aliasesFromSymlinksIn == null then
            throw "withAliases: requires `aliases` or `aliasesFromSymlinksIn`"
          else
            withUnpinEmbed pkgs { inherit primary aliases aliasesFromSymlinksIn; } drv;

        # Thin wrapper over withUnpinEmbed — embed only the package's man
        # pages as `unpin/man/<name>.<section>` entries, so `unpin man <pkg>`
        # reads docs straight out of the binary. `manRoot`: when null, harvest
        # man from the drv's own outputs (`$man`/`$out`) — the native path.
        # When set to a store path, read `$manRoot/share/man` instead — an
        # explicit external override (consumer-supplied `winManRoot`).
        # `manFallback`: optional store path consulted ONLY on the harvest-own
        # path (manRoot == null) when the drv ships no man of its own — the
        # windows/cosmo default. Composition with withAliases/withRuntimeData
        # is order-free: all calls accumulate into the binary's one ZIP.
        withMan = pkgs: { primary, manRoot ? null, manFallback ? null }: drv:
          withUnpinEmbed pkgs { inherit primary manRoot manFallback; man = true; } drv;

        # Thin wrapper over withUnpinEmbed — embed only a runtime tree (vim's
        # share/vim, perl's @INC, …), read back at run time by the unpin-vfs
        # self-EOF mode (-DUNPIN_VFS_SELF, github:unpins/unpin-vfs). `stage`
        # is a shell snippet run in postFixup (i.e. AFTER strip) with
        # `$__unpin_stage` pointing at an empty directory that is the ZIP
        # root: populate it with the tree exactly as the VFS should serve it.
        # An empty stage fails the build: unlike man pages, a missing runtime
        # tree is a broken program, not a degraded one.
        withRuntimeData = pkgs: { primary, stage }: drv:
          withUnpinEmbed pkgs { inherit primary; runtimeStage = stage; } drv;

        # Drop Cosmopolitan's `.symtab.amd64` from a cosmo APE's tail-ZIP.
        # That entry is the symbol table cosmocc's apelink adds for crash
        # backtraces (`--ftrace`/`--strace`), ~30-80 KB deflated and unused at
        # runtime — stdenv `strip` can't reach it (it's a ZIP member, not an
        # ELF section). `zip -d` removes just that member, preserving the PE
        # prefix, `.cosmo`, any `usr/share/zoneinfo/*`, and our `unpin/*` entries.
        # Self-guarding: no-op on mingw PE (no tail-ZIP). Apply AFTER withMan
        # so it trims what's left once the man block is embedded.
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

        # Shared multicall dispatcher generator. Returns the shell block that
        # writes `multicall/dispatcher.c` — the tiny C front-end every multicall
        # binary shares: a `copy_basename` (strips dir + the `.exe` suffix), an
        # applet table built at build time from `multicall/apps.list` (one applet
        # name per line — THE contract; the caller populates it before invoking),
        # and a `main` with the unified dispatch contract below.
        #
        # Canonical behaviour, uniform across the catalog (replaces the old
        # hand-copied per-package dispatchers that had drifted apart):
        #   * Applet name -> C symbol via `tr -c 'A-Za-z0-9_' '_'`, so hyphenated
        #     applets (srt-live-transmit) map to a legal identifier with no
        #     per-package sanitiser.
        #   * Dispatch (`base` = basename(argv[0]), CANON = `name`):
        #       - `base != CANON` and `base` is an applet -> ALIAS path: run it
        #         via argv[0]. `--unpin-program` is ignored here, so an alias
        #         symlink is locked to its identity (`ls --unpin-program=rm`
        #         runs ls, never rm).
        #       - otherwise (CANON, a path, or a renamed copy like CI's
        #         `smoke.exe`) -> MULTITOOL path: `--unpin-program=NAME` as the
        #         first argument selects the applet (coreutils' `--coreutils-prog`
        #         convention); an unknown NAME errors on stderr, exit 1. There is
        #         no positional `<pkg> <applet>` form — the explicit flag is the
        #         single, unambiguous selector (so a canonical name that is also
        #         an applet, e.g. `zip`, is never confused with `zip <applet>`).
        #   * A canonical name that is itself an applet (bzip2/zip/flac/unzip)
        #     runs that applet on a bare invocation.
        #   * Bare invocation (and `--help`/`-h`/`help`) lists the programs on
        #     stdout and exits 0; unless `defaultApplet` is set (libwebp: a bare
        #     `libwebp` runs cwebp) — then bare runs that, listing is unreachable.
        #
        # Params: `name` (banner + default argv0) and optional `defaultApplet`.
        # The list source / sanitiser / fallback-style that used to vary per
        # package are now fixed here; the only knob is `defaultApplet`.
        #
        # Invoke at COLUMN 0 in the consumer's postBuild so the `CBODY` heredoc
        # terminators reach the emitted script at column 0 (a shell requirement)
        # and the enclosing indented-string keeps a sane min-indent. The consumer
        # must have written `multicall/apps.list` earlier in postBuild. Drv-hash
        # changes vs the old inline dispatchers (intended). See docs/multicall.md.
        multicallDispatcherC = { name, defaultApplet ? null }:
          let
            sanDefault = nixpkgs.lib.replaceStrings [ "-" "." "+" ] [ "_" "_" "_" ]
              (if defaultApplet == null then "" else defaultApplet);
            # When to honor `--unpin-program=` on a NON-canonical, non-applet
            # name. With a defaultApplet the self-detect aliases (bunzip2,
            # zipinfo — names NOT in apps.list that route to the defaultApplet)
            # must stay argv[0]-locked, so the flag is honored only on the exact
            # canonical name. Without a defaultApplet there are no such aliases
            # (every alias is a real applet, already locked on the alias path),
            # and a renamed copy (CI's smoke.exe) needs the flag — so honor it
            # unconditionally there.
            flagGuard = if defaultApplet == null then "1" else "is_canon";
            fallbackC =
              if defaultApplet == null
              then ''        if (argc < 2) { list_programs(stdout); return 0; }
        if (!strcmp(argv[1], "--help") || !strcmp(argv[1], "-h") || !strcmp(argv[1], "help")) {
            list_programs(stdout); return 0;
        }
        fprintf(stderr, "${name}: select a program with --unpin-program=<name>. Available:");
        for (const struct applet *a = applets; a->name; a++)
            fprintf(stderr, "%s%s", a == applets ? " " : ", ", a->name);
        fprintf(stderr, "\n");
        return 1;''
              else ''        (void)list_programs;  /* defaultApplet replaces the listing fallback */
        return ${sanDefault}_main(argc, argv);'';
          in
          ''
      {
        echo '#include <string.h>'
        echo '#include <stdio.h>'
        while IFS= read -r a; do
          [ -n "$a" ] || continue
          san=$(printf '%s' "$a" | tr -c 'A-Za-z0-9_' '_')
          echo "int ''${san}_main(int, char **);"
        done < multicall/apps.list
        echo 'struct applet { const char *name; int (*fn)(int, char **); };'
        echo 'static const struct applet applets[] = {'
        while IFS= read -r a; do
          [ -n "$a" ] || continue
          san=$(printf '%s' "$a" | tr -c 'A-Za-z0-9_' '_')
          echo "    {\"$a\", ''${san}_main},"
        done < multicall/apps.list
        cat <<'CBODY'
    {0, 0}
};
static void copy_basename(char *dst, size_t cap, const char *src) {
    const char *p = src, *s;
    s = strrchr(p, '/'); if (s) p = s + 1;
#ifdef _WIN32
    s = strrchr(p, '\\'); if (s) p = s + 1;
#endif
    size_t n = strlen(p); if (n >= cap) n = cap - 1;
    memcpy(dst, p, n); dst[n] = 0;
    if (n > 4 && strcmp(dst + n - 4, ".exe") == 0) dst[n - 4] = 0;
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
    char base[64];
    const char *a0 = (argc > 0 && argv[0]) ? argv[0] : "${name}";
    copy_basename(base, sizeof base, a0);
    int is_canon = strcmp(base, "${name}") == 0;
    /* Alias path: a symlink whose basename is an applet (and not the canonical
       binary "${name}") -> run that applet via argv[0]. The --unpin-program
       selector is deliberately NOT honored here, so an alias is locked to its
       argv[0] identity (ls --unpin-program=rm runs ls, never rm). */
    if (!is_canon)
        for (const struct applet *a = applets; a->name; a++)
            if (strcmp(base, a->name) == 0) return a->fn(argc, argv, environ);
    /* Multitool path: the canonical name "${name}" or a renamed copy (a path,
       or CI's smoke.exe). Select the applet explicitly with the first argument
       --unpin-program=NAME. The ${flagGuard} guard keeps self-detect aliases
       argv[0]-locked when a defaultApplet is present (see flagGuard above). */
    if (${flagGuard} && argc >= 2 && strncmp(argv[1], "--unpin-program=", 16) == 0) {
        const char *sel = argv[1] + 16;
        for (const struct applet *a = applets; a->name; a++)
            if (strcmp(sel, a->name) == 0) {
                /* Reuse the argv[1] slot as the applet's argv[0]=NAME. */
                argv[1] = (char *)sel;
                return a->fn(argc - 1, argv + 1);
            }
        fprintf(stderr, "${name}: no program '%s'\n", sel);
        return 1;
    }
    /* The canonical name when it is itself an applet (bzip2/zip/flac/unzip
       style) runs that applet on a bare invocation. */
    if (is_canon)
        for (const struct applet *a = applets; a->name; a++)
            if (strcmp(base, a->name) == 0) return a->fn(argc, argv, environ);
${fallbackC}
}
CBODY
      } > multicall/dispatcher.c'';

        # Recipe-A multicall dispatcher generator (the `ld -r` family:
        # e2fsprogs/util-linux/shadow/findutils/procps-ng). Sibling to
        # multicallDispatcherC; a SEPARATE helper because the input model differs
        # fundamentally — these have a NAME→FUNCTION table that is many-to-one
        # (e2fsprogs: mkfs.ext2/3/4 → mke2fs_main; e2label/findfs → tune2fs_main),
        # so the symbol can't be derived from the applet name. The caller writes
        # `multicall/applets.list` as a TSV, one row per dispatchable name:
        #
        #     <applet-name>\t<fn-base>      (the C symbol is <fn-base>_main)
        #
        # Aliases are just extra rows pointing at the same <fn-base> (the upstream
        # tool re-checks argv[0] itself). util-linux/shadow/procps-ng already
        # produce this TSV from their Makefile parse; e2fsprogs/findutils write it
        # from a static list. The dispatcher this emits follows the SAME contract
        # as multicallDispatcherC: an alias symlink (`base != CANON` matching an
        # applet) runs via argv[0] and ignores `--unpin-program`; the canonical
        # name (or a renamed copy) selects an applet with `--unpin-program=NAME`
        # as the first argument (no positional form). `copy_basename` strips a
        # `/`/`\\` dir prefix (the `\\` is unconditional — cosmo APE argv[0] can
        # carry it and `_WIN32` isn't defined for cosmo), a trailing `.exe`, and a
        # libtool `lt-` prefix before matching. Invoke at COLUMN 0, after the TSV.
        #
        # Optional `defaultApplet` (a <fn-base>, NOT an applet name — its symbol
        # `<defaultApplet>_main` must exist): a bare invocation runs it instead of
        # printing usage. procps-ng uses `src_ps_pscommand` so `procps-ng
        # --version` and a renamed binary route to ps. See docs/multicall.md.
        #
        # Applet entries are called as `fn(argc, argv, environ)` — the THREE-arg
        # main form. Some programs (notably bash) declare `main(argc,argv,env)`
        # and read the environment from the THIRD main argument, NOT the environ
        # global; a 2-arg call leaves that parameter holding a garbage register
        # → SIGSEGV at startup. Passing environ is ABI-safe for the common 2-arg
        # mains (coreutils, grep, …) — they simply ignore the extra register.
        # The cosmo path links the renamed main DIRECTLY, so the 3rd arg reaches
        # it. The bitcode-LTO path interposes a trampoline per program; that
        # trampoline is ALSO 3-arg and forwards all three (see
        # multicallModuleHookLTO) — a 2-arg trampoline would drop environ and the
        # 3rd-arg-main would receive NULL (verified: it does, deterministically).
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
        echo 'extern char **environ;'
        while IFS="$(printf '\t')" read -r tool san; do
          [ -n "$tool" ] || continue
          echo "int ''${san}_main(int, char **, char **);"
        done < multicall/applets.list
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
        # Add a `module` output to a package's NORMAL build carrying a
        # self-describing multicall module: `module.a` (the package's own
        # objects, with `main`→`unpin__<pkg>__<prog>_main` and every other
        # defined global namespaced `unpin__<pkg>__<prog>__<sym>`) plus the
        # package's PRIVATE bundled archives (gnulib) with their callbacks INTO
        # the program rewritten to the namespaced names. Produced purely by
        # post-processing — `objcopy --redefine-syms` over the objects the build
        # ALREADY compiled — so no recompile and no second build: it rides the
        # same builder as the shipped binary (overrideAttrs composes in place,
        # so the .o tree is still present in postBuild even under withAliases).
        #
        # The manifest (applets / depArchives / requires) is a Nix value the
        # caller assembles around this — see mkStandaloneFlake's `multicall`
        # arg, which attaches it as `passthru.multicallModule`. The mega-builder
        # (mkMegaMulticall) links N such modules into one busybox-style binary.
        #
        # Distinguishes a PRIVATE bundled lib (gnulib: `internalArchives` —
        # callbacks namespaced, own defs untouched so they stay dedupable across
        # packages) from a CLEAN external dep (pcre2/zlib: `depArchives` in the
        # manifest — never touched, deduped by member at mega-link). Linux
        # native only for now (ELF symbol shapes + objcopy redef map). See
        # docs/multicall.md and the mega-multicall plan.
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
        # The adapter (lto = true) compiled every object as LLVM BITCODE, so the
        # ELF-only objcopy --redefine-syms of multicallModuleHook can't apply
        # (llvm-objcopy refuses bitcode). Instead, per program:
        #
        #   1. a tiny trampoline `unpin__<pkg>__<prog>_main` calls the program's
        #      `main` (no recompile of the program — the trampoline is the only
        #      thing compiled here; the program's bitcode objects are used as-is);
        #   2. a REAL linker (`ld.lld -r --lto-emit-llvm`, NOT llvm-link) folds
        #      the program's bitcode objects + the trampoline + the PRIVATE
        #      internalArchives (gnulib) into one bitcode module — lld's
        #      on-demand archive pull (first-def-wins dedup + back-ref
        #      resolution) is what llvm-link's whole-load/single-pass can't do;
        #      see the detailed note on `perProgram` below for why;
        #   3. `opt -passes=internalize` keeping ONLY the trampoline entry
        #      localizes everything else — the real `main` (NOT auto-preserved by
        #      LLVM 21's new-PM InternalizePass, unlike legacy -internalize) and
        #      every shared/callback global — to internal linkage, so two
        #      programs' same-named statics can't collide at the mega-link.
        #
        # The per-program internalized modules are llvm-link'd into one
        # module.bc; llvm-link auto-renames colliding internals (main → main.1,
        # …) while the external entries stay distinct. CLEAN external depArchives
        # (pcre2/zlib) are NOT folded — they stay external in the manifest,
        # deduped by member at the mega-link (which links with -flto -fuse-ld=lld
        # for whole-program LTO across all modules). Linux-native only.
        #
        # Needs llvm-link + opt, which the vendored multicall `llvm` carries
        # (toolchain Patch 4); they're passed as `llvm` = "${toolchain}/bin/llvm".
        multicallModuleHookLTO =
          { package                 # "grep" — namespace component
          , programs                # [ { name; objs = [ "src/x.o" ]; } ]
          , internalArchives ? [ ]  # builddir-relative private .a (gnulib, bitcode)
          , llvm                    # "${toolchain}/bin/llvm" (has llvm-link + opt)
          , inferLinkInputs ? false # read objs + local .a from the capture sidecar
                                    # ($UNPIN_LINK_DIR/<prog>.link) instead of the
                                    # hand-listed objs/internalArchives
          }: drv:
          let
            san = n: nixpkgs.lib.replaceStrings [ "." "-" "+" ] [ "_" "_" "_" ] n;
            entryOf = p: "unpin__${san package}__${san p.name}_main";
            spaceSep = nixpkgs.lib.concatStringsSep " ";
            # Fold the program's bitcode objects + trampoline + the PRIVATE
            # archives into one module with a REAL linker (ld.lld -r), not
            # llvm-link. llvm-link has no proper archive semantics: it either
            # whole-loads every archive (duplicate strong defs when a shared
            # helper is bundled into several members — coreutils' every
            # libsinglebin_*.a carries its own blake2b-ref.o/cksum.o; gnulib
            # lists backupfile twice → "symbol multiply defined") or, with
            # --only-needed, does a single left-to-right pass that can't satisfy
            # cross-archive back-references (basenc → base32's isubase32, df →
            # gnulib c_iscntrl). lld pulls archive members on demand, takes the
            # first definition and skips the rest (dedup), and resolves
            # back-references by default (no --start-group needed) — exactly the
            # native single-binary link. `-r` keeps it relocatable so libc/dep
            # symbols stay undefined for the mega-link; `--lto-emit-llvm` writes
            # the merged result as bitcode (inputs are bitcode) instead of
            # codegen'ing it, so the cross-module LTO chain stays intact. The
            # program objects are passed as objects (always included, never GC'd
            # under -r). Then opt internalizes everything but the entry.
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
                ${llvm} opt -passes=internalize -internalize-public-api-list=${entryOf p} \
                  ${linkBc} -o multicall/mod_${san p.name}.bc
              '';
          in
          drv.overrideAttrs (old: {
            outputs = (old.outputs or [ "out" ]) ++ [ "module" ];
            postBuild = (old.postBuild or "") + ''
              set -e
              mkdir -p multicall "$module/lib"
              # surface the capture sidecars for inspection
              if [ -d "''${UNPIN_LINK_DIR:-/nonexistent}" ]; then
                mkdir -p "$module/links"
                cp "$UNPIN_LINK_DIR"/*.link "$module/links/" 2>/dev/null || true
              fi
              ${nixpkgs.lib.concatMapStringsSep "\n" perProgram programs}
              ${llvm} llvm-link ${spaceSep (map (p: "multicall/mod_${san p.name}.bc") programs)} \
                -o "$module/lib/module.bc"
            '';
          });

        # Cosmo (APE) multicall MODULE emitter for engine = "cosmocc". The
        # bitcode/LTO emitter can't be used — ld.lld won't link cosmo objects
        # (the IFUNC/IPLT wall, see the cosmo-PE spike) — so the cosmo mega-link
        # is a NATIVE link through cosmocc + ld.bfd + apelink, and the module
        # carries plain renamed ELF objects/archives (cosmo objects are ELF
        # before apelink, so `objcopy --redefine-syms` applies directly).
        #
        # FULL per-package namespacing (stronger than multicallModuleHook's
        # per-program scheme): every DEFINED global across the program objects
        # AND the package's own archives is renamed `unpin__<pkg>__<sym>`
        # (`main` → `unpin__<pkg>__<prog>_main`). The same map is applied to the
        # objects and to BOTH archive buckets, so a package's internal
        # references follow the rename and stay resolved, while libc's undefined
        # symbols are untouched — making every package hermetic and
        # cross-package symbol collisions impossible (no reliance on archive
        # member dedup, which the cosmo native link can't guarantee across
        # packages — cf. the "blake2 multiply defined" failure in the LTO path).
        #
        # Three staged buckets preserve the package's NATIVE link order at the
        # mega-link (mkMegaMulticall's cosmo branch links them in this order):
        #   objs/    program objects — linked DIRECT (always pulled), so a
        #            program object that strongly overrides an archive symbol
        #            (coreutils csplit.o's own xalloc_die) wins before any
        #            archive is scanned;
        #   applet/  per-applet archives — scanned (in a --start-group) BEFORE
        #            gnulib, so the override is satisfied from the applet object,
        #            not gnulib's default (which would then collide);
        #   gnulib/  the private bundled archive(s) — scanned AFTER applets.
        # Single-program packages (coreutils single-binary, bash, dash) only.
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
        # that ships N sibling programs from one source tree (each its own
        # subdir Makefile, sharing a clean static lib with no callbacks into the
        # programs) is folded into ONE binary at bin/<primary>, every other
        # program name an argv[0] alias.
        #
        # Each program is recompiled with a per-program `-include <p>.rename.h`
        # that renames `main`→<san>_main and namespaces every other defined
        # global behind `<san>__`, so two programs can't collide. Objects stay
        # normal compiled .o (no partial link), so the cross lld's `--gc-sections`
        # is happy (unlike the older ld -r + objcopy fold, which trips i686's
        # linkonce thunks) and the same recipe works on ELF, Mach-O (leading-`_`
        # strip + `S`-type data symbols) and cosmo APE. Shared static libs
        # (libacl.a, libexfat.a) are NOT renamed — called identically by every
        # program, no collisions — so they stay one copy, passed via `linkExtra`.
        #
        # Generalized from the per-package mc.nix used by acl/psmisc/dosfstools/
        # exfatprogs (bc/e2fsprogs keep bespoke variants: bc is procps-class —
        # its shared number.o calls back into per-program rt_error — so it can't
        # share lib objects). See docs/multicall.md.
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
        # build derivation itself instead of being hand-named per package. We
        # walk the TRANSITIVE propagated-input closure (+ direct buildInputs) and
        # return their store-path DIRECTORIES — pure strings, NO
        # import-from-derivation: we never readDir at eval time, so evaluating a
        # package flake does not force building its deps. The mega builder globs
        # `<dir>/lib/*.a` at BUILD time (the deps are real build inputs there).
        # libc/cc are implicit stdenv deps and never appear in this closure, so
        # there is nothing to exclude; unreferenced archives are inert under
        # archive-link semantics (the link wraps them in --start-group). Reads
        # buildInputs off the FINAL build drv, so a recipe's `.override` that adds
        # deps (coreutils' acl/attr) is reflected.
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
        # passthru.multicallModule manifests mkStandaloneFlake attaches) into ONE
        # busybox-style binary "unpinbox". Each manifest carries:
        #   moduleFormat  "bitcode" (the -flto emitter) | "elf-archive" (objcopy)
        #   moduleArchive  store path to module.bc / module.a
        #   depArchives    external clean .a (pcre2, zlib) — passthru store paths
        #   applets        [ { name; entry } ]  entry = unpin__<pkg>__<prog>_main
        #   requires       { cxx; group; … }
        #
        # The dispatcher (multicallTableDispatcherC) routes argv[0]-basename or a
        # leading `--unpin-program=NAME` to the matching entry. Bitcode modules
        # link with `clang -flto -fuse-ld=lld` (whole-program LTO across every
        # package); the module.bc files are plain objects (always pulled), the
        # external depArchives are passed once, deduped by store path (the linker
        # pulls only the members each module needs). The link runs through
        # unpinAdapterStdenv so the on-demand musl sysroot (libc, libc++) is
        # seeded and each entry's libc/pcre2 U-symbols resolve.
        #
        # Applet-name collisions across packages are a HARD error (the plan's
        # recommended policy) — pass `nameOverrides = { old = new; }` to rename.
        # `cppRenameMulticall` is the degenerate single-package fold; this is the
        # cross-package one. See docs/multicall.md and the mega-multicall plan.
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
            depArchives = nixpkgs.lib.unique
              (nixpkgs.lib.concatMap (m: m.depArchives) modules);
            # Auto-derived external dep dirs (per-module input closure). The
            # builder globs <dir>/lib/*.a at build time and skips libc-family
            # archives (the engine/cosmo provides libc — a deep closure that
            # surfaces musl's libc.a must not clash with it).
            depInputDirs = nixpkgs.lib.unique
              (nixpkgs.lib.concatMap (m: m.depInputDirs or [ ]) modules);
            # Shell prelude (shared by both builders) that fills a `autodeps`
            # array from depInputDirs, filtering the libc split archives.
            autoDepsPrelude = ''
              autodeps=()
              for d in ${nixpkgs.lib.concatStringsSep " " depInputDirs}; do
                for a in "$d"/lib/*.a; do
                  [ -e "$a" ] || continue
                  case "$(basename "$a")" in
                    libc.a|libm.a|libpthread.a|librt.a|libdl.a|libresolv.a|libutil.a|libcrypt.a|libxnet.a|libnsl.a) continue ;;
                  esac
                  autodeps+=("$a")
                done
              done
            '';
            face = if anyCxx then "$CXX" else "$CC";
            # A group is needed when there is more than one archive to back-ref
            # across — explicit depArchives OR auto-derived dirs both count.
            needGroup = anyGroup || depArchives != [ ] || depInputDirs != [ ];
            groupOpen = nixpkgs.lib.optionalString needGroup "-Wl,--start-group";
            groupClose = nixpkgs.lib.optionalString needGroup "-Wl,--end-group";
            adapter = unpinAdapterStdenv {
              inherit pkgs toolchain target;
              # Cross mega: when pkgs is a cross set the link runs through the
              # cross stdenv (lld cross-links the per-arch modules); only the
              # sysroot sanity run is gated off. toolchain stays the build-host
              # one (buildPlatform.system) — clang -target emits the host arch.
              native = pkgs.stdenv.buildPlatform.system == pkgs.stdenv.hostPlatform.system;
              cxx = anyCxx;
              lto = anyBitcode;
            };

            # ── Bitcode/ELF path (engine default | unpin-llvm): one ELF via the
            # unpin-llvm adapter, whole-program LTO across modules with lld. ──
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
                # -Wl,-s strips the symbol table at link (after LTO codegen bound
                # the entries) — the entries are dead in the symtab once linked,
                # so the shipped binary carries none. The UNPIN_META ZIP is
                # embedded post-link by withAliases, so it survives the strip.
                # Explicit depArchives + auto-derived (autodeps) ride in one group.
                ${face} -fuse-ld=lld -Wl,-s -o ${name} \
                  multicall/dispatcher.c \
                  ${nixpkgs.lib.concatStringsSep " " moduleArchives} \
                  ${groupOpen} ${nixpkgs.lib.concatStringsSep " " depArchives} "''${autodeps[@]}" ${groupClose}
                runHook postBuild
              '';
              installPhase = ''
                runHook preInstall
                mkdir -p "$out/bin"
                install -m755 ${name} "$out/bin/${name}"
                runHook postInstall
              '';
            };

            # ── Cosmo path (engine cosmocc): native cosmocc link in each
            # package's NATIVE order (objs DIRECT, then applet group, then
            # gnulib group), then apelink to a fat APE (every OS, runs locally)
            # and a thin Windows PE32+. cosmo objects can't go through lld. ──
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
          # withAliases embeds UNPIN_META into the primary binary; for cosmo it
          # resolves `${name}` → `${name}.exe` (withUnpinEmbed's .exe fallback),
          # so the shipped Windows artifact carries the alias set. The fat
          # `.ape` rides alongside for local cross-OS testing.
          withAliases pkgs { primary = name; aliases = names; }
            (if cosmoMode then megaCosmoDrv else megaElfDrv);

        # Why not overlays for per-package fixes? `appendOverlays` invalidates
        # `pkgsBuildHost.stdenv` → cascade rebuild of compiler-rt-libc-static, ninja,
        # python3 in pkgsStatic-darwin (none cached; Hydra only builds pkgsStatic-linux).
        # 30-60 min of darwin CI to add one configureFlag. Fake-cross via differing
        # config strings was tried and broke autotools (cross mode disables AC_RUN_IFELSE,
        # which apple-sdk's atf needs). So `drv.override` / `.overrideAttrs` inside the
        # consumer's `build`/`windowsBuild` closures (and the lib-only
        # native-overlay/ + mingw-overlay/ overlay fragments) is the only path
        # keeping both the cached toolchain AND autotools-native-mode configure
        # runs.

        # Rebuild `drv` with every dep in `drv.override.__functionArgs` swapped for
        # its `pkgsStatic` counterpart (.a-only, no shared libs at all), falling back
        # to `dropSharedLibs` on the regular version when no pkgsStatic variant exists.
        #
        # Used by `tmux/flake.nix`'s darwin build closure: pkgsStatic.tmux itself fails to link
        # (configure.ac passes `-static` globally → libSystem probe fails), so we keep
        # regular tmux but swap its deps for the static variants. Preferring pkgsStatic
        # over postFixup-delete dodges the dyld-at-build-time pitfall (ncurses ships
        # `tic`/`infocmp` binaries dynamically linked to `libncursesw.dylib`; deleting
        # the dylib breaks tmux-terminfo, which `tic`s at build time).
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

        # `mingwStaticCross pkgs` = `pkgs.pkgsCross.mingwW64` + overlay that, on mingw:
        #
        # (1) Wraps stdenv with `makeStaticLibraries` → injects `--enable-static
        #     --disable-shared` (autotools), `-DBUILD_SHARED_LIBS=OFF` (cmake),
        #     `-Ddefault_library=static` (meson) into every mkDerivation.
        #
        # (2) Sets `stdenv.hostPlatform.isStatic = true`. A "white lie" at the platform
        #     attr level — NOT a re-instantiation. Upstream recipes key off isStatic
        #     directly (zlib's `shared ? !isStatic`, zstd's static knob, libpsl's .pc
        #     handling, ...) and produce .a-only outputs when they see it. Without this
        #     fudge we'd per-package-override each one.
        #
        # Safe for mingw: isStatic here is a build-flag convention; mingw-w64 / mcfgthread
        # produce byte-identical .a either way (no libc swap analogous to glibc→musl).
        # cc/bintools and the cross gcc come verbatim from cache.nixos.org — the overlay
        # only wraps mkDerivation.
        #
        # `if isMinGW` gate: pkgsBuildHost of the cross set is linux, so the then-branch
        # doesn't fire there and pkgsBuildHost.stdenv keeps its cache hash.
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

        # Finalize a mingw binary for shipping. Input must already be built through
        # `mingwStaticCross` (libs are .a-only; `--enable-static --disable-shared`
        # already injected by the stdenv adapter).
        #
        # Adds the piece the per-library adapter can't reach: libtool-aware
        # `LDFLAGS=-all-static` at make-time so the FINAL link resolves to `.a` only.
        # Without it, libtool picks any `.dll.a` in the link path and the DLL-link hook
        # copies the matching `.dll` next to the binary.
        #
        # `staticDeps` threads via `.override` (libtool sees `.a` in the dep's lib
        # output); NOT applied as overlay — gcc itself uses zlib/zstd → full xgcc
        # rebuild. `filterConfigureFlag` strips flags the package adds unconditionally
        # (curl's `--without-ssl` when `opensslSupport = false`).
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
              # Make-time only. Passing via NIX_LDFLAGS at configure breaks autoconf's
              # "C compiler works" probe.
              makeFlags = (old.makeFlags or [ ]) ++ [ "LDFLAGS=-all-static" ];
            } // extraOverrides old);
          in
          # mingw headers (nghttp2, libpsl, libcurl, ...) default to
          # `__declspec(dllimport)`. Static consumers need *_STATICLIB defined or
          # the link leaves `__imp_*` unresolved.
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

        # Single output for both single- and multi-output drvs (strip vs symlinkJoin
        # bin+man). Keeps `nix build` producing the bare `result` symlink that
        # action-build's verify step looks for at `result/bin/<pkg>` — multi-output drvs
        # would otherwise land at `result-bin`/`result-man` and verify fails.
        strippedOrJoined = pkgs: name: drv:
          let
            # A `module` output (multicall .a-generation, opt-in) is a sidecar,
            # not a shipped runtime output: ignore it when deciding strip-vs-join
            # and let it ride through the strip branch untouched. Identity for
            # every package that doesn't carry one.
            shipOutputs = builtins.filter (o: o != "module") (drv.outputs or [ "out" ]);
            out =
              if shipOutputs == [ "out" ]
              then drv.overrideAttrs (_: { stripAllList = [ "bin" "out" ]; })
              else packageWithMan pkgs name drv;
          in
          # strip/symlinkJoin yield a synthetic meta that drops the upstream
          # license/description/homepage. Carry them back onto the artifact so
          # tooling (the website packages page, `unpin info`) can read them with
          # no per-package table. `meta` is not part of the derivation hash, so
          # this adds no rebuilds.
          out // {
            meta = (out.meta or { }) // builtins.intersectAttrs
              { license = null; description = null; homepage = null; longDescription = null; }
              (drv.meta or { });
          };

        # Standalone-binary flake template. Returns:
        #   packages.<system>.default                = native build (pkgsStatic)
        #   packages.aarch64-darwin."darwin-x86_64"  = cross x86_64-darwin
        #   packages.x86_64-linux."windows-x86_64"   = mingw-cross build
        #   apps.<system>.default                    = `nix run` entry
        #
        # `name` is the user-facing id (catalog/gh-repo/binary). `pkgsAttr`
        # overrides the nixpkgs / nativeFixes / pkgsCross.cosmo lookup when the
        # nixpkgs attribute differs (e.g. nixpkgs ships `links2`, we ship as
        # `links`). Falls back to `pkgs.pkgsStatic.${pkgsAttr}` /
        # `pkgs.pkgsCross.mingwW64.${pkgsAttr}` / `pkgs.pkgsCross.cosmo.${pkgsAttr}`.
        # Consumers wanting full control pass `build` / `windowsBuild` directly.
        # `binName` overrides when bin name ≠ name. `nativeBuild = false` →
        # windows-only (e.g. gvim: static GTK infeasible on linux, MacVim is its
        # own .app bundle). `linuxOnly = true` → suppresses every darwin attr
        # from packages.<sys>, used for Linux-kernel-only tools (kmod,
        # util-linux, shadow, procps-ng, iproute2).
        mkStandaloneFlake =
          { self
          , name
          , build ? null
          , windowsBuild ? null
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
          # Override the man source for the windows/cosmo binary. The cross
          # build ships no man of its own, so by default we graft the
          # version-locked pages from the x86_64-linux nixpkgs build of
          # `pkgsAttr` (see `winManSrc` below). That harvests EVERY page the
          # upstream ships — including tools/libs the unpins binary doesn't
          # actually carry (e.g. ffmpeg's ffplay.1 / libav*.3). Set this to a
          # store path with `share/man` to embed exactly that set instead, so
          # the windows binary's man matches what native/darwin embed (parity).
          # null = keep the nixpkgs graft (default; unchanged for every package
          # that doesn't opt in).
          , winManRoot ? null
          # Opt-in smoke-test args, e.g. `[ "--version" ]`. action-build
          # runs `<bin> ${smoke[*]}` after each build on runners with a
          # matching ABI (and on a Windows runner for windows-x86_64).
          # Exit 0 alone is too lax — some tools print "Unknown option"
          # and still exit 0 (links does this on Windows). Pair with
          # `smokePattern` to also require a stdout substring match.
          # Skip both with null when the binary lacks a quick non-
          # interactive probe.
          , smoke ? null
          , smokePattern ? null
          # Per-package exception to the darwin portability allow-list. A list
          # of Apple PrivateFramework names (e.g. [ "MediaRemote" ]) that
          # action-build's "Verify binary is portable" step will accept for
          # THIS package only, in addition to the always-allowed public
          # /System/Library/Frameworks/*, libSystem and libobjc. Default []:
          # the strict contract is unchanged for every package that doesn't
          # opt in. Use only when an upstream macOS feature genuinely depends
          # on a private framework with no public equivalent (the symbols
          # should be weak-import + NULL-guarded so the feature degrades
          # gracefully if a future macOS drops the framework).
          , darwinAllowPrivateFrameworks ? [ ]
          # optimize: knobs for opt-level / stack protector / LTO / GC.
          # Defaults merged with
          # `{ lto = false; opt = null; ssp = true; gc = true; }`. Keys:
          #
          #   lto = true       → enable mkPkgsLTO overlay; chain-LTO consumer
          #                       + its level-1 buildInputs (Linux native
          #                       only — mingw/cosmocc fall through). OFF by
          #                       default since the LTO chain has produced
          #                       systemic recurring failures (autoconf
          #                       conftest leakage, ltrans debug-info refs,
          #                       muslLTO symbol internalization, buildInput
          #                       test-suite miscompiles). For tiny static
          #                       CLIs the size win is 5-15% and the latency
          #                       win is invisible (ms-scale runs), so the
          #                       maintenance cost was not justified. Opt
          #                       in per-package when a hot path genuinely
          #                       benefits.
          #   opt = "-Os"      → appended to NIX_CFLAGS_COMPILE (wins over
          #                       upstream). null leaves it to upstream
          #                       (~ -O2). When LTO is active, null is
          #                       resolved to -O2 inside the overlay.
          #   ssp = false      → drop stack protector + skip the LTO
          #                       `-Wl,-u,__stack_chk_fail` retention flag.
          #   gc = false       → disable the function/data-sections +
          #                       --gc-sections dead-code prune (mkPkgsGC,
          #                       Linux native only). ON by default: it is a
          #                       benign codegen knob (no LTO-class failures)
          #                       that shrinks every binary 6-19% measured
          #                       (jq 6%, aom 19% — the win scales with how
          #                       much dead code the deps carry). LTO subsumes
          #                       it (lto = true makes gc a no-op). NOTE for
          #                       multicall packages whose `name` ≠ the nixpkgs
          #                       attr: set `pkgsAttr` to the real lib (e.g.
          #                       aom → "libaom") or the overlay finds nothing
          #                       to rebuild and only the multicall final link
          #                       gets --gc-sections (weak prune). The
          #                       multicall.nix post-link must also append
          #                       `${lib.gcSectionsFlag pkgs}` to reach that
          #                       external link.
          # Pin the artifact's `meta.license` to an explicit SPDX id (or list of
          # them), e.g. "GPL-3.0-or-later". The upstream license is carried
          # automatically by `strippedOrJoined`; set this only when the build has
          # none (a custom mkDerivation — ffmpeg, python) or inherits a noisy
          # multi-component list you want pinned to the effective license. Read
          # by the website packages page; reusable by `unpin info`.
          , license ? null
          # Pin the artifact's `meta.description` (one line; read by the
          # website packages page and reusable by `unpin info`). The upstream
          # description is carried automatically by `strippedOrJoined`; set
          # this only when the build has none (a custom mkDerivation —
          # ffmpeg, python).
          , description ? null
          , optimize ? { }
          # Opt a package into the multicall MODULE artifact (the .a-generation
          # scheme). When set, the NATIVE-LINUX `packages.<sys>.default` build
          # gains a `module` output (module.a + namespaced private archives,
          # produced by post-processing the objects the build already compiled —
          # no recompile) and a `passthru.multicallModule` manifest the
          # mega-builder consumes. Shape:
          #   multicall = {
          #     programs = [ { name = "grep"; objs = [ "src/grep.o" … ];
          #                    aliases = [ "egrep" "fgrep" ]; } ];
          #     internalArchives = [ "lib/libgreputils.a" ];  # private (gnulib)
          #     depArchives = [ "${pkgs.pkgsStatic.pcre2.out}/lib/libpcre2-8.a" ];
          #     requires = { };   # cxx/group/frameworks/… overrides
          #   }
          # null = unchanged (every package that doesn't opt in is untouched;
          # CI matrix and shipped binary bytes are unaffected by this option's
          # existence). Linux native only for now — darwin/windows/cosmo and
          # procps-class shared-callback packages are deferred. The `depArchives`
          # closure is a passthru reference only (not linked into the shipped
          # binary), so it doesn't bloat `packages.<sys>.default`.
          , multicall ? null
          # Cosmo counterpart of `multicall`: opt a package into the cosmo
          # (APE) multicall MODULE, emitted from the COSMO CROSS build (the
          # `windows-x86_64` artifact) instead of the native-linux one. cosmocc
          # objects are ELF before apelink, so multicallModuleHookCosmo's objcopy
          # `--redefine-syms` applies directly — no lld (the cosmo IFUNC/IPLT
          # wall) and no -flto. When set (and the package builds for cosmo), the
          # cosmo build gains a `module` output (renamed objs/ + applet/ + gnulib/
          # in native link order) and a `passthru.cosmoMulticallModule` manifest
          # the mega-builder's cosmoMode consumes. Shape (single-program only —
          # coreutils single-binary, bash, dash):
          #   multicallCosmo = {
          #     program = "coreutils";                  # entry = unpin__<name>__<program>_main
          #     programObjs = [ "src/coreutils-coreutils.o" ];  # DIRECT at mega-link
          #     appletArchives = [ "src/libsinglebin_*.a" … ];  # scanned BEFORE gnulib
          #     gnulibArchives = [ "lib/libcoreutils.a" ];      # scanned AFTER applets
          #     aliases = [ "[" "cat" … ];              # every applet routes to entry
          #     depArchives = [ "${pkgs.readline}/lib/libreadline.a" … ];  # external .a
          #     requires = { };                         # cxx override (default false)
          #   }
          # null = unchanged. Independent of `multicall`/`engine` (those drive the
          # native-linux artifact); a package can carry both, neither, or just one.
          , multicallCosmo ? null
          # Link the DNS fallback (__wrap_getaddrinfo) into the linux-static
          # artifact so it resolves names where /etc/resolv.conf is absent
          # (Android, minimal containers). OPT-IN: set `dnsFallback = true` only
          # on packages that actually resolve hostnames (curl, whois, nmap, …).
          # It is NOT free on programs that never resolve: the appendix ends in
          # `-lc` (needed so __wrap_getaddrinfo's own libc deps — inet_pton,
          # fopen, getaddrinfo, … — resolve after the archive), and that trailing
          # `-lc` plus `--wrap=getaddrinfo` makes ld pull ~25 KB of musl's
          # resolver into EVERY binary, used or not. On a real DNS consumer the
          # archive is genuinely linked so this is correct and free; on a
          # non-consumer it is dead bloat that shifted bzip2's bss enough to tip
          # its decompressor into a SIGSEGV (`bzip2 --help`). Hence opt-in, not
          # catalog-wide. No-op on darwin/windows. See withDnsFallback.
          , dnsFallback ? false
          # engine: which toolchain builds the NATIVE-LINUX artifact.
          #   "default"    → nixpkgs' static-musl stdenv (gcc/clang via cc-wrapper),
          #                  the catalog default — unchanged for every package.
          #   "unpin-llvm" → build the SAME unmodified nixpkgs recipe through the
          #                  vendored unpin-llvm toolchain via unpinAdapterStdenv
          #                  (pkgsStatic.<pkgsAttr>.override { stdenv = …; }). Only
          #                  the native-linux path is rerouted; cross-linux,
          #                  darwin and windows keep their existing toolchains
          #                  (a deliberate follow-up — unpin-llvm has those
          #                  backends but the cross wiring isn't done yet). The
          #                  swap is transparent: a consumer-supplied `build`
          #                  receives a `pkgs` whose pkgsStatic.<pkgsAttr> is
          #                  already on the engine stdenv, so the recipe needs no
          #                  engine plumbing (see rawBuild). Composes with neither
          #                  lto nor gc (the adapter replaces the stdenv those
          #                  overlays wrap, so they'd be silent no-ops); nixpkgsFor
          #                  falls back to plain nixpkgs under this engine.
          , engine ? "default"
          }:
          let
            optimize_ = { lto = false; opt = null; ssp = true; gc = true; } // optimize;
            inherit (optimize_) lto opt ssp gc;
            ltoOpt = if opt == null then "-O2" else opt;
            # LTO and GC overlays apply on Linux only — musl is Linux-specific
            # and the cross-darwin path doesn't have an analogous chain we want
            # to rewire yet. Darwin/cross fall back to stock pkgs. LTO already
            # includes function/data-sections + --gc-sections, so it subsumes
            # gc; when both are set, lto wins and gc is a no-op.
            nixpkgsFor = forAllNative (system:
              # unpin-llvm replaces the whole stdenv (overrideCC), so the gc/lto
              # overlays — which rewrite the nixpkgs cc-wrapper stdenv — would be
              # silent no-ops under it. Use plain nixpkgs to avoid the wasted eval
              # and the false impression they're active.
              if engine == "unpin-llvm" then import nixpkgs { inherit system; }
              else if lto && isLinuxSys system
              then mkPkgsLTO { inherit system; opt = ltoOpt; inherit ssp; pkgName = pkgsAttr; }
              else if gc && isLinuxSys system
              then mkPkgsGC { inherit system ssp opt; pkgName = pkgsAttr; }
              else import nixpkgs { inherit system; });

            # Apply opt/ssp knobs to a built drv. No-op when both at
            # default (opt = null + ssp = true) so cache.nixos.org hits
            # stay intact for packages that don't override.
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
            # The unpin-llvm engine swaps the recipe's `stdenv` for our toolchain
            # adapter. For the DEFAULT recipe we override it directly. For a package
            # with a CUSTOM `build` (an opaque pkgs -> drv closure we can't reach
            # into) we instead hand the closure a `pkgs` whose pkgsStatic.<pkgsAttr>
            # is ALREADY built with the engine stdenv — so the recipe reads exactly
            # as off-engine (`pkgs.pkgsStatic.gnugrep.overrideAttrs …`), no engine
            # plumbing per package; just set `engine = "unpin-llvm"`. The shallow
            # `//` swaps only that one top package, leaving its deps and the rest of
            # pkgsStatic normal (external depArchives stay plain ELF). linux-static
            # host only; darwin/cross/off-engine get `pkgs` untouched, so every
            # existing package is byte-identical. A bitcode-LTO multicall module
            # (engine + multicall) needs every object as bitcode, so the adapter
            # gets lto = true ONLY then; engine-only packages keep the -O2 ELF path.
            wantBitcodeModule = engine == "unpin-llvm" && multicall != null;
            engineStdenvFor = pkgs: unpinAdapterStdenv {
              inherit pkgs;
              target = pkgs.pkgsStatic.stdenv.hostPlatform.config;
              # `native` only gates the sysroot's sanity RUN (a foreign binary
              # can't exec on the build host). For a cross pkgs (pkgsCross.*)
              # the wrapped stdenv stays a REAL cross stdenv — clang just swaps
              # `-target` — so configure runs in cross mode (AC_RUN_IFELSE off,
              # build tools are build-host arch); no "exec format error".
              native = pkgs.stdenv.buildPlatform.system == pkgs.stdenv.hostPlatform.system;
              cxx = true;
              lto = wantBitcodeModule;
              captureLinks = wantBitcodeModule;
            };
            rawBuild = pkgs:
              let
                # Linux (native OR cross). The one LLVM toolchain cross-emits
                # every target via `clang -target`; `engineStdenvFor` wraps the
                # REAL cross stdenv (pkgsCross.*) so configure behaves as a
                # genuine cross — no qemu, no "exec format error". Only packages
                # that opt into `engine = "unpin-llvm"` are touched; everything
                # else keeps gcc cross byte-identical.
                useEngine = engine == "unpin-llvm" && pkgs.stdenv.hostPlatform.isLinux;
                engStdenv = if useEngine then engineStdenvFor pkgs else null;
                enginePkgs = pkgs // {
                  pkgsStatic = pkgs.pkgsStatic // {
                    ${pkgsAttr} = pkgs.pkgsStatic.${pkgsAttr}.override { stdenv = engStdenv; };
                  };
                };
              in
              if build != null
              then build (if useEngine then enginePkgs else pkgs)
              else if useEngine
              then (defaultRawBuild pkgs).override { stdenv = engStdenv; }
              else defaultRawBuild pkgs;
            stripped = pkgs:
              let
                # multicall MODULE opt-in: native-linux only. The hook adds a
                # `module` output by post-processing the objects the build
                # already compiled (no recompile), riding the same builder as
                # the shipped binary. No-op when `multicall == null` or off-Linux.
                sanMc = nixpkgs.lib.replaceStrings [ "." "-" "+" ] [ "_" "_" "_" ];
                # Linux (native OR cross). The bitcode module rides the engine's
                # -flto objects; with the engine now cross-capable, each cross
                # arch emits its own module (same triple as the shipped binary)
                # for the per-arch mega to fold.
                wantModule = multicall != null && pkgs.stdenv.hostPlatform.isLinux;
                # engine = "unpin-llvm" builds with -flto → bitcode objects → the
                # objcopy redef map can't apply; use the bitcode-LTO emitter
                # (llvm-link + opt -internalize). engine = "default" (gcc/clang
                # ELF) keeps the objcopy hook.
                useBitcodeModule = wantModule && engine == "unpin-llvm";
                rawHooked =
                  if useBitcodeModule
                  then multicallModuleHookLTO
                    {
                      package = name;
                      inherit (multicall) programs;
                      internalArchives = multicall.internalArchives or [ ];
                      inferLinkInputs = multicall.inferLinkInputs or false;
                      llvm = "${unpinToolchain pkgs.stdenv.buildPlatform.system}/bin/llvm";
                    }
                    (rawBuild pkgs)
                  else if wantModule
                  then multicallModuleHook
                    {
                      package = name;
                      inherit (multicall) programs;
                      internalArchives = multicall.internalArchives or [ ];
                      isTargetDarwin = false;
                    }
                    (rawBuild pkgs)
                  else rawBuild pkgs;
                core = withDarwinIconv pkgs (dropSharedLibs (filterEnableStaticOnDarwin (applyOptSsp rawHooked)));
                # C catalog keeps the fallback linux-only for now; the darwin-C
                # and windows-cosmo paths are a deliberate follow-up (the Rust
                # tools opt into darwin/windows by calling withDnsFallback directly).
                base = if dnsFallback && pkgs.stdenv.hostPlatform.isLinux
                       then withDnsFallback pkgs.pkgsStatic core else core;
                # withMan must run on the underlying drv (it edits the bin
                # output and reads the man output) BEFORE strippedOrJoined
                # collapses multi-output drvs into a symlinkJoin. Skipped when
                # the consumer's own withUnpinEmbed call already included man
                # (passthru.unpinEmbedsMan) — one pack, not two.
                withMaybeMan0 =
                  if embedMan && !(base.unpinEmbedsMan or false)
                  then withMan pkgs { primary = binName; } base
                  else base;
                # When a `module` output rides along, force the SAME final strip
                # selection (`[bin out]`) that strippedOrJoined / packageWithMan
                # apply downstream. That makes their internal strip override a
                # no-op (identical .drv), so the `module` output we reference for
                # the manifest is the very build the shipped binary comes from —
                # no second build — and survives even the symlinkJoin branch
                # (multi-output packages like grep, which has an `info` output).
                # Shipped bytes are unchanged: [bin out] is exactly what those
                # helpers already set.
                withMaybeMan =
                  if wantModule
                  then withMaybeMan0.overrideAttrs (_: { stripAllList = [ "bin" "out" ]; })
                  else withMaybeMan0;
                result = withLicense (withDescription (strippedOrJoined pkgs name withMaybeMan));
                # The manifest the mega-builder consumes. `moduleArchive`/the
                # gnulib `depArchives` reference the `module` output of the same
                # built drv (built once, same builder); the external `depArchives`
                # are verbatim store paths (passthru reference, NOT linked into
                # the shipped binary).
                multicallManifest = {
                  package = name;
                  # Bitcode path: ONE module.bc with the internalArchives folded
                  # IN (llvm-link). ELF/objcopy path: module.a + the renamed
                  # private archives sit alongside as separate depArchives.
                  moduleFormat = if useBitcodeModule then "bitcode" else "elf-archive";
                  moduleArchive =
                    if useBitcodeModule
                    then "${withMaybeMan.module}/lib/module.bc"
                    else "${withMaybeMan.module}/lib/module.a";
                  depArchives =
                    (if useBitcodeModule then [ ]
                     else map (a: "${withMaybeMan.module}/lib/${baseNameOf a}") (multicall.internalArchives or [ ]))
                    ++ (let d = multicall.depArchives or [ ];
                        in if builtins.isFunction d then d pkgs else d);
                  applets = nixpkgs.lib.concatMap
                    (p:
                      let entry = "unpin__${sanMc name}__${sanMc p.name}_main"; in
                      [{ name = p.name; inherit entry; }]
                      ++ map (al: { name = al; inherit entry; }) (p.aliases or [ ]))
                    multicall.programs;
                  requires = { cxx = false; group = true; } // (multicall.requires or { });
                  # Auto-derived external dep DIRS (pure store paths, no IFD); the
                  # mega builder globs <dir>/lib/*.a at build time. Replaces the
                  # need to hand-name `depArchives` (which stays as an additive
                  # override for archives not in the build's input closure).
                  depInputDirs = multicallExternalDepDirs withMaybeMan;
                };
              in
              if wantModule then result // { multicallModule = multicallManifest; } else result;

            # Windows runs on x86_64-linux runners. `allowUnsupportedSystem` because
            # most nixpkgs `meta.platforms` exclude mingw / cosmo → cross-built drv
            # would be filtered out. Dispatch order:
            #   windowsBuild   → consumer-supplied closure. For mingw, returns
            #                    `(mingwStaticCross pkgs).${name}.overrideAttrs …`;
            #                    for cosmocc, returns `(cosmoStaticCross pkgs).${name}
            #                    .overrideAttrs …`. Per-binary cosmo recipes live
            #                    in `<consumer>/cosmo.nix` sidecars, mingw recipes
            #                    inline in the consumer's `windowsBuild`.
            #   windowsCosmo   → `(cosmoStaticCross pkgs).${pkgsAttr}`. The
            #                    cosmo cross stdenv carries an apelink setup
            #                    hook that auto-converts ELF → PE32+ in
            #                    fixupPhase, so no helper wrapping is needed.
            #                    Use for cosmo builds where vanilla nixpkgs
            #                    cross builds cleanly and no further consumer
            #                    customization is needed. Most catalog cosmo
            #                    packages have extra quirks (drop symlinks,
            #                    withAliases, configureFlags) and use
            #                    `windowsBuild = import ./cosmo.nix` instead.
            #   windows        → plain `(mingwStaticCross pkgs).${pkgsAttr}`,
            #                    no consumer customization.
            windowsEnabled = windows || windowsBuild != null || windowsCosmo;
            # windowsPkgs is the single root from which BOTH cross targets live:
            #   pkgsCross.mingwW64  →  vanilla nixpkgs cross
            #   pkgsCross.cosmo     →  cosmocc-as-cross-stdenv (via
            #                          replaceCrossStdenv + cosmoOverlay)
            # The applyPatches step registers `cosmo` as a kernel + example
            # crossSystem in nixpkgs (see ./cosmo-lib-systems.patch). The
            # overlay self-guards on `isCosmo` so it's a no-op for
            # pkgsCross.mingwW64; `replaceCrossStdenv` likewise guards
            # before swapping in cosmocc. Net effect: vanilla mingw drvs
            # are unchanged, cosmo drvs are routed through cosmocc.
            windowsPkgs =
              let
                basePkgs = nixpkgs.legacyPackages.${"x86_64-linux"};
                nixpkgsPatched = basePkgs.applyPatches {
                  name = "nixpkgs-cosmo";
                  src = nixpkgs.outPath;
                  patches = [ ./cosmo-lib-systems.patch ];
                };
                # Pass fixLib so cosmo overlay fragments can call
                # `lib.withAliases` (defined in nix-lib's lib).
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
            windowsRawBuild =
              if windowsBuild != null then windowsBuild
              else if windowsCosmo then (pkgs: (cosmoStaticCross pkgs).${pkgsAttr})
              else (pkgs: (mingwStaticCross pkgs).${pkgsAttr});
            # Cosmo multicall MODULE opt-in (symmetric to the linux `multicall`
            # path in `stripped`). When `multicallCosmo` is set, post-process the
            # cosmo cross build with multicallModuleHookCosmo to add a `module`
            # output (renamed ELF objs — cosmo objects are ELF before apelink),
            # then emit `passthru.cosmoMulticallModule` from the same build the
            # `windows-x86_64` artifact ships (no second build). mingw is never a
            # cosmo module source; the hook is only applied on the cosmo path.
            sanMcW = nixpkgs.lib.replaceStrings [ "." "-" "+" ] [ "_" "_" "_" ];
            wantCosmoModule = multicallCosmo != null && (windowsCosmo || windowsBuild != null);
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
              else windowsRawBuild pkgs;
            # Man source for the windows/cosmo binary. The mingw/cosmo cross
            # build ships no man, so embed the (OS-independent, version-locked)
            # pages from the regular x86_64-linux build of the same attr. Pick
            # its `man` output when split, else `out` (man-in-out). null when
            # the attr doesn't exist or has no man → withMan skips gracefully.
            winManNixpkgs = nixpkgs.legacyPackages.${"x86_64-linux"};
            # `winManRoot` (package opt-in) wins: embed exactly the curated set
            # the package supplies. Otherwise fall back to the nixpkgs graft.
            # Windows man source. An explicit consumer `winManRoot` wins
            # outright (curated tree, unchanged behavior). Otherwise the
            # windows build harvests its OWN share/man — symmetric with every
            # cross-linux target, which already does this — and borrows the
            # version-locked nixpkgs graft ONLY when the cross build ships no
            # man of its own (the rare help2man-driven package). `winManGraft`
            # is null for custom-named multicall packages (no matching nixpkgs
            # attr); those harvest-own-or-nothing, same as today.
            winManGraft =
              let p = winManNixpkgs.${pkgsAttr} or null;
              in if p == null then null else (p.man or p.out or p);
            windowsBase = dropSharedLibs (applyOptSsp (windowsRawHooked windowsPkgs));
            windowsWithMan =
              # Skip when the consumer's windowsBuild already embedded man via
              # its own withUnpinEmbed call (passthru.unpinEmbedsMan).
              if !embedMan || windowsBase.unpinEmbedsMan or false then windowsBase
              else if winManRoot != null
              then withMan windowsPkgs { primary = binName; manRoot = "${winManRoot}"; } windowsBase
              else withMan windowsPkgs {
                primary = binName;
                manFallback = if winManGraft == null then null else "${winManGraft}";
              } windowsBase;
            # Trim cosmo's unused `.symtab.amd64` (no-op on mingw). Runs after
            # withMan so the man block is already embedded.
            windowsTrimmed0 = withCosmoStrip windowsPkgs { primary = binName; } windowsWithMan;
            # When a `module` output rides along, force the SAME final strip
            # selection (`[bin out]`) strippedOrJoined applies on the strip
            # branch (cosmo ships single-output `out`, so it takes that branch
            # and keeps `module` untouched — see strippedOrJoined's shipOutputs).
            # This makes that internal strip override a no-op identical .drv, so
            # `windowsTrimmed.module` is the very build the shipped binary comes
            # from — no second cosmo build. Same trick as the linux path.
            windowsTrimmed =
              if wantCosmoModule
              then windowsTrimmed0.overrideAttrs (_: { stripAllList = [ "bin" "out" ]; })
              else windowsTrimmed0;
            windowsPkg0 = withLicense (strippedOrJoined windowsPkgs name windowsTrimmed);
            # The manifest the mega-builder's cosmoMode consumes. The module
            # buckets reference the `module` output of the same built drv; the
            # external `depArchives` are verbatim store paths (passthru reference,
            # NOT linked into the shipped `windows-x86_64` binary).
            cosmoMulticallManifest =
              let entry = "unpin__${sanMcW name}__${sanMcW multicallCosmo.program}_main";
              in {
                moduleFormat = "cosmo-elf";
                moduleObjs = "${windowsTrimmed.module}/objs";
                appletDir = "${windowsTrimmed.module}/applet";
                gnulibDir = "${windowsTrimmed.module}/gnulib";
                depArchives =
                  let d = multicallCosmo.depArchives or [ ];
                  in if builtins.isFunction d then d windowsPkgs else d;
                # Auto-derived from the cosmo cross build's input closure
                # (e.g. bash → cosmo readline/ncurses); globbed at build time.
                depInputDirs = multicallExternalDepDirs windowsTrimmed;
                applets =
                  [{ name = multicallCosmo.program; inherit entry; }]
                  ++ map (al: { name = al; inherit entry; }) (multicallCosmo.aliases or [ ]);
                requires = { cxx = false; } // (multicallCosmo.requires or { });
              };
            windowsPkg =
              if wantCosmoModule
              then windowsPkg0 // { cosmoMulticallModule = cosmoMulticallManifest; }
              else windowsPkg0;

            # `linuxOnly` drops every Darwin attr from `packages.<sys>` so
            # action-build's auto-discovered matrix doesn't include darwin
            # runners. Used for packages whose nixpkgs `meta.platforms`
            # excludes darwin entirely (kmod, util-linux, shadow,
            # procps-ng, iproute2 — anything that talks to Linux-only
            # kernel APIs).
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
                # withLLDLink: the gc overlay (lld + --gc-sections/--icf) is
                # Linux-native only, so the cross scopes get the unpins-standard
                # lld link via NIX_CFLAGS_LINK here instead — keeps the linker
                # uniform across every non-mac target (single-binary included).
                "linux-i686" = stripped (withLLDLink pkgsAttr pkgs.pkgsCross.musl32);
                # musl-power = powerpc64le-unknown-linux-musl. Debian calls it
                # "ppc64el" but uname returns "ppc64le" and the Rust ecosystem
                # (rustup, binstall) labels it the same way — we follow uname.
                "linux-ppc64le" = stripped (withLLDLink pkgsAttr pkgs.pkgsCross.musl-power);
                # riscv64 has no pre-cooked musl variant in nixpkgs.pkgsCross
                # (only glibc). Spell the crossSystem out by triple.
                "linux-riscv64" = stripped (withLLDLink pkgsAttr (import nixpkgs {
                  inherit system;
                  crossSystem = { config = "riscv64-unknown-linux-musl"; };
                }));
              }
              // nixpkgs.lib.optionalAttrs (nativeBuild && system == "aarch64-linux") {
                # armv7l-unknown-linux-musleabihf: nixpkgs.pkgsCross has no
                # musl example for armv7l (muslpi is armv6), so spell the
                # crossSystem out — exactly like riscv64 above. Until 2026-06
                # this used the glibc `armv7l-hf-multiplatform` example and
                # relied on pkgsStatic's automatic glibc→musl swap; the inner
                # static drvs are IDENTICAL either way (verified by drv hash),
                # but the glibc top scope leaked into consumer `build`
                # closures that read `pkgs` directly (the Rust path), so make
                # the scope say what we ship. Only the light wrapper drvs
                # (withMan repack/strip) changed hash.
                #
                # The triple means: hardware float (VFPv3) + hardware 64-bit
                # atomics
                # (LDREXD/STREXD). Covers Pi 2/3/4 in 32-bit mode,
                # BeagleBoneBlack, Odroid, and the dominant ARM 32-bit
                # hardware that runs Linux today. Matches the Rust
                # ecosystem convention (ripgrep/fd/bat use armv7l in
                # this slot) and the CI runner (ubuntu-24.04-arm).
                #
                # Trade-off: drops armv6 baseline (Pi 1 / Zero / Zero W).
                # Worth it because anything pulling in 64-bit atomics
                # (libssh2, glib ≥ 2.68, any modern threading wrapper)
                # fails to link on armv6 with __atomic_*_8 undefined,
                # since musl doesn't ship libatomic in pkgsStatic.
                "linux-armv7l" = stripped (withLLDLink pkgsAttr (import nixpkgs {
                  inherit system;
                  crossSystem = { config = "armv7l-unknown-linux-musleabihf"; };
                }));
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

            # UNOFFICIAL extra targets — curated "tier-3" arches that we do
            # NOT want in the CI matrix. `action-build` auto-discovers the
            # build matrix from `.#packages` only (see build.yml), so anything
            # exposed here is invisible to CI and never built for the whole
            # catalog — yet it's available from a plain clone with a short
            # path: `nix build .#cross.powerpc` (no script, no --override-input).
            #
            # `cross` is a FLAT (non-system-keyed) attrset, so `.#cross.<arch>`
            # resolves literally with NO currentSystem insertion — which is why
            # the build host is hardcoded `x86_64-linux` (cross is inherently
            # build-host-specific, and flake purity forbids builtins.currentSystem).
            # A cloner on a non-x86_64-linux host needs an x86_64-linux builder.
            #
            # Each entry maps a friendly uname-style name to its musl triple,
            # built exactly like the official linux crosses (withLLDLink + strip
            # + man overlay). Add one line per arch AFTER validating it builds +
            # smoke-runs under qemu. Start small: powerpc (32-bit big-endian),
            # proven on bash (ELF32 MSB PowerPC, runs under qemu-ppc).
            cross = let
              mk = triple: stripped (withLLDLink pkgsAttr (import nixpkgs {
                system = "x86_64-linux";
                crossSystem = { config = triple; };
                # These are unofficial, opt-in tier-3 crosses. A niche arch can
                # be absent from a package's `meta.platforms` whitelist — not
                # because it can't build, but because no nixpkgs maintainer
                # blessed it. `.#cross` is the explicit "best-effort, may not
                # link" path, so we bypass that gate (same as the windows block
                # above). No-op for arches already whitelisted (all current
                # entries are), but keeps `.#cross` robust for future additions.
                config.allowUnsupportedSystem = true;
              }));
              # x86-64 micro-architecture feature levels (psABI 2020): SAME
              # triple as the default x86_64, just a higher `-march` baseline via
              # gcc.arch. Unlike i586/armv6 (which go DOWN for old hardware /
              # compat), these go UP (newer CPUs / perf) — a vN binary SIGILLs on
              # any CPU below that level. So they're a perf OPT-IN, not a
              # portability target: the default x86_64 deliberately stays v1, the
              # "runs anywhere" floor. Handy for compute-heavy packages (e.g.
              # libvpx encode); ~zero gain for text-y CLI tools. v2≈Nehalem'08
              # (SSE4.2/POPCNT), v3≈Haswell'13 (AVX2/BMI/FMA), v4 (AVX-512).
              mkV = arch: stripped (withLLDLink pkgsAttr (import nixpkgs {
                system = "x86_64-linux";
                crossSystem = { config = "x86_64-unknown-linux-musl"; gcc.arch = arch; };
                config.allowUnsupportedSystem = true;
              }));
            in nixpkgs.lib.optionalAttrs nativeBuild (builtins.mapAttrs (_: mk) {
              # ── Official CI targets, mirrored here so `.#cross.<arch>` is a
              # UNIFORM interface for every arch — the user makes the same call
              # whether the target is official or tier-3. These spell out the
              # exact triples the official `.#packages` cross targets use
              # (i686→pkgsCross.musl32, ppc64le→pkgsCross.musl-power, the rest
              # already spelled out), so the derivations are IDENTICAL — cache
              # hits, byte-for-byte the same binary CI ships. (`allowUnsupported‑
              # System` in `mk` is an eval gate, not a build input, so it doesn't
              # perturb the hash.) x86_64 is the native `.#default`, not mirrored.
              i686 = "i686-unknown-linux-musl";
              ppc64le = "powerpc64le-unknown-linux-musl";
              riscv64 = "riscv64-unknown-linux-musl";
              aarch64 = "aarch64-unknown-linux-musl";
              armv7l = "armv7l-unknown-linux-musleabihf";

              # ── Unofficial tier-3 arches (curated, NOT in the CI matrix) ──
              # i586 (Pentium baseline) — the "armv6 of x86". Distinct from the
              # official `i686` above: i586 has CMPXCHG8B (lock-free 64-bit
              # atomics) but NO CMOV, so an i686 binary SIGILLs on these. Real
              # niche: AMD Geode LX/GX (PC Engines ALIX firewalls/routers, OLPC
              # XO-1), Vortex86, K6. Mainstream distros dropped it (Debian
              # "i386"/Alpine x86 are i686 since ~2016), so this is the only way
              # to target that hardware. isX86_32 → lld handles it (no isLLDTarget
              # change). NOT i386/i486: i386 is dead in modern toolchains; i486
              # lacks CMPXCHG8B (atomics fall to libatomic) for near-zero gain.
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
              # MIPS64 (n64 ABI) — the 64-bit pair of mips/mipsel. musl's mips64
              # port is n64 ONLY (its n32 is a separate `mipsn32` port), so we
              # MUST spell out `muslabi64`: the bare `...-musl` triple parses as
              # gcc's default ABI (n32) and would mismatch musl. el = little-
              # endian (Loongson 3); BE = Cavium Octeon + lots of BE network
              # gear. isMips → ld.bfd, same as the 32-bit mips above.
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
              # NOTE: x32 (x86_64 ILP32) is deliberately kept OUT here — but,
              # unlike sparc64, NOT because it's impossible. musl has an x32 port
              # and it builds + smoke-runs fine (proven on bash; see the
              # playground/x32-spike flake). The catch is COST: nixpkgs's
              # lib.systems has no `muslx32` ABI, so enabling it needs PATCHING
              # the nixpkgs SOURCE in 3 spots (parse.nix `abis`, inspect.nix
              # `isMusl`, parse.nix `mkMuslSystem`) — lib.systems is evaluated
              # before pkgs, so an overlay can't reach it. Every other entry in
              # this map is just a curated triple over the pinned nixpkgs (free);
              # x32 alone would force an applyPatches on the catalog-wide nixpkgs
              # input. Not worth it for the niche — left as a spike. (Smoke also
              # needs qemu-system + `syscall.x32=y`; qemu-user has no x32.)
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
              # `smoke` is null when the caller didn't opt in; otherwise
              # a list of CLI args. JSON-encoded into the matrix to let
              # build.yml run `<bin> <args>` after each build.
              smoke = if smoke == null then null else smoke;
              # Optional grep-E pattern that must match the smoke command's
              # combined stdout+stderr. Catches "Unknown option" false-pass.
              smoke_pattern = if smokePattern == null then null else smokePattern;
              # Per-package darwin portability exception: list of Apple
              # PrivateFramework names the verify step accepts for this package.
              # Empty for all packages that don't opt in (strict contract).
              darwin_allow_private_frameworks = darwinAllowPrivateFrameworks;
            };
          };

        # Rust-crate flake template. A thin wrapper over mkStandaloneFlake
        # that supplies Rust-aware build closures. Two source modes (nixpkgs
        # attr vs own-source, see the `src` arg) × two dep-closure shapes
        # (pure Rust vs vendored C, see `vendoredC`). Crates with real
        # external C/TLS deps (ring, openssl-sys) are out of scope — see
        # unpins/unpin for that hand-rolled shape.
        #
        #   native linux/darwin → pkgs.pkgsStatic.<pkgsAttr>: the nixpkgs
        #     recipe as-is (src, cargoHash, meta all reused).
        #   cross-musl (i686, armv7l, ppc64le, riscv64, local aarch64 check)
        #     → pure Rust: NO C cross toolchain at all — rustup's rust-std
        #     for *-musl (via the consumer's rust-overlay input) bundles
        #     musl's libc.a + crt objects (self-contained linking) and the
        #     build host's ld.lld links any ELF arch. rustc, cargo and the
        #     crate build scripts all run as native binaries; only --target
        #     + the linker differ. First proven on unpins/cfonts, all nine
        #     targets. With vendoredC, the same scopes the C catalog caches
        #     supply the C compiler/linker instead (unpins/unpin-man).
        #   cross darwin (CI aarch64→x86_64; local Intel→arm64 gate)
        #     → nixpkgs cross rustPlatform + the pkgsStatic.libiconv pin
        #     (rustc injects -liconv; a libiconv.2.dylib load command flunks
        #     the portability check) + a build-arch -L for the proc-macro
        #     dylib links (the unpin-readme recipe).
        #   windows → pkgs.pkgsCross.mingwW64.<pkgsAttr> (pure Rust needs
        #     none of the mingw-overlay C fixes).
        #
        # dnsFallback is forced off: withDnsFallback's unsalted NIX_LDFLAGS
        # leaks the arch-specific libunpindns.a into the BUILD-host link of
        # crate build scripts under the rustup-toolchain crosses. A Rust
        # crate that resolves hostnames needs bespoke wiring (unpins/unpin);
        # asking for dnsFallback here is an eval-time error on purpose.
        #
        # The consumer passes its own `rust-overlay` input (pin it with
        # `inputs.nixpkgs.follows = "unpins-lib/nixpkgs"`); nix-lib itself
        # takes no new input, so the C catalog's lock files are untouched.
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

            # Chain-free cross-musl build (pure Rust only): rust-std bundles
            # musl's libc.a + crt objects, the native ld.lld links any ELF
            # arch — rustc, cargo and the crate build scripts all run as
            # native binaries.
            muslCrossPure = pkgs:
              let
                # Eval-only peek at the scope mkStandaloneFlake hands us:
                # pkgsStatic elaborates the static-musl host (and converts a
                # glibc top scope, as armv7l's was on older nix-lib). No
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
                # link-self-contained uses rust-std's bundled musl crt/libc;
                # -C strip replaces the fixup strip (native strip can't edit
                # a foreign-arch ELF, hence dontStrip).
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

            # Cross-musl with vendored C: the handed scope's makeRustPlatform
            # bakes --target plus CC_<T>/CARGO_TARGET_<T>_LINKER to that
            # scope's C cross toolchain (catalog-cached); rust-overlay
            # supplies rustc/cargo as native binaries. crt-static because
            # rust-overlay's musl specs default it off; auditable=false as on
            # every rustup-toolchain cross (the unpin precedent).
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
              # Within-darwin cross (CI builds x86_64-darwin from the arm64
              # runner): build the crate against the host's default
              # rustPlatform. rustc injects `-liconv` on darwin targets and the
              # proc-macro/build-script host links want it too; both are now
              # handled centrally by mkStandaloneFlake's `withDarwinIconv` (it
              # pins the static target archive so no libiconv.2.dylib load
              # command survives the portability check, and hands the
              # build→build cc-wrapper a `-L` for the BUILD-arch libiconv,
              # cross-only) — so no per-path iconv wiring is needed here.
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

        # Native cosmoStdenv. Used by playground/{bash,coreutils,dash,links} for
        # in-tree builds against the `$COSMOS` shared prefix. The full result is
        # `stdenv // { cosmocc, cosmoCCUnwrapped, cosmoBintoolsUnwrapped,
        # platformBits, mkCrossWiring, version }` — consumers commonly want
        # `cosmoStdenv.mkDerivation` and `cosmoStdenv.platformBits`.
        cosmoStdenv = pkgs: import ./cosmocc.nix { inherit pkgs; };

        # `cosmoStaticCross pkgs` — fully symmetric with `pkgs.pkgsCross.mingwW64`
        # and `pkgs.pkgsStatic`: takes a build-host pkgs set (where cosmo wiring
        # was registered, e.g. mkStandaloneFlake's `windowsPkgs`) and returns
        # the cosmo cross pkgs set. Per-binary quirks live in the consumer's
        # `windowsBuild = import ./cosmo.nix { inherit unpins-lib; }`.
        #
        # Cosmo is now a first-class nixpkgs cross target: `cosmo-lib-systems.patch`
        # registers the kernel + an `examples.cosmo` crossSystem, and
        # `windowsPkgs` is built with the cosmoOverlay + `replaceCrossStdenv`
        # guarded on `isCosmo`. The cross-arch story (aarch64-cosmo from
        # x86_64-linux) still needs a buildPackages.pkgsCross stanza — not
        # exposed yet because no catalog package needs it.
        cosmoStaticCross = pkgs: pkgs.pkgsCross.cosmo;

      };

      # Per-target fixes, auto-loaded from sibling directories.
      # See lib.mkStandaloneFlake and lib.mingwStaticCross for how they're consumed.
      # Fix files use nixpkgs.lib for stdlib (hasSuffix, filterAttrs, …) AND our
      # helpers (withDepsSharedPruned, mingwStaticCross, …) — fuse both into one
      # `lib` for them so they can write `lib.X` uniformly.
      #
      # `nativeFixes` is re-exposed inside the lib seen by fix files (and by
      # consumer `build` closures via `unpins-lib.lib.nativeFixes.<dep>`) so a
      # downstream consumer can reuse a library override (e.g. tmux's `build`
      # closure calls `lib.nativeFixes.libevent`). Safe under nix laziness
      # because cross-fix references only resolve when the consumer calls
      # the function with `pkgs`, not at top-level evaluation.
      fixLibBase = nixpkgs.lib // lib;
      nativeFixes = import ./native-overlay { lib = fixLibBase // { inherit nativeFixes; }; };
      mingwOverlayFixes = import ./mingw-overlay { lib = fixLibBase; };
    in
    {
      lib = lib // { inherit nativeFixes; };
    };
}
