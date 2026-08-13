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
        # triggers the on-demand build of libc/CRTs (and libc++ when `cxx`). The
        # bake must cover every variant the consumer's links will ask for, because
        # a miss is silent: the driver rebuilds musl inside the sandbox and throws
        # it away with the derivation.
        #
        # Two axes, both HASH axes of `Variant` in unpin_musl.cpp:
        #  * pic — many build systems force -fPIC even for a static target (zlib's
        #    configure does), and without the PIC variant baked the link fails
        #    writing the RO store cache and configure silently mis-detects.
        #  * lto — `lto` bakes the second PAIR, for consumers whose shims append
        #    -flto (both routes do by default). The non-LTO pair stays either way:
        #    autoconf conftests drop -flto on purpose, so a build hits BOTH. Under
        #    -flto the libc objects are bitcode, so this doubles the sysroot
        #    (11M -> 26M/target) and pays for itself at the first link: a C++
        #    -flto link is 38s against an empty cache and 11s against the bake
        #    (same binary), pkgsStatic.hello through engineStdenv 52s -> 41s.
        #    `-flto=thin` needs no third bake — parseVariant folds every -flto=
        #    spelling into the one lto=1 variant.
        # Still uncoverable: a package that passes its own -march=/-mcpu= or a
        # different opt class moves cpuFlags/fast and misses the bake again.
        # `native` gates the sanity run (cross can't exec on the builder); `cxx`
        # the C++ half.
        unpinSysroot = { pkgs, toolchain ? unpinToolchain pkgs.stdenv.buildPlatform.system, triple, optClass ? "-O2", native ? false, cxx ? false, lto ? false }:
          let ltoAxis = if lto then ''"" "-flto"'' else ''""''; in
          pkgs.runCommand "unpin-sysroot-${triple}" { } ''
            export HOME=$TMPDIR
            export XDG_CACHE_HOME=$out/cache
            printf 'int main(void){return 0;}\n' > hello.c
            for l in ${ltoAxis}; do
              for pic in "" "-fPIC"; do
                ${toolchain}/bin/llvm clang -target ${triple} ${optClass} $pic $l hello.c -o hc
                ${nixpkgs.lib.optionalString native "./hc"}
              done
            done
            ${nixpkgs.lib.optionalString cxx ''
              printf '#include <iostream>\nint main(){std::cout<<"";return 0;}\n' > hello.cpp
              for l in ${ltoAxis}; do
                for pic in "" "-fPIC"; do
                  ${toolchain}/bin/llvm clang++ -target ${triple} ${optClass} $pic $l hello.cpp -o hcpp
                  ${nixpkgs.lib.optionalString native "./hcpp"}
                done
              done
            ''}
            echo "baked variants for ${triple}:"; find $out/cache/unpin-llvm -name .complete \
              | sed "s|$out/cache/unpin-llvm/||"
          '';

        # The ONE way to hand a build the baked sysroot, shared by both stdenv
        # routes. Nothing may point XDG_CACHE_HOME at `${sysroot}/cache` directly:
        # the bake is a store path (read-only) but the driver builds missing
        # variants ON DEMAND at link time, keyed by a per-flag variant hash, so a
        # flag combo the bake didn't cover tries to write into the store. That
        # write fails WITHOUT failing the build — the link falls back to a broken
        # dynamic musl and a configure probe reads it as "flag unsupported", green.
        sysrootSeedHook = { pkgs, sysroot }: pkgs.makeSetupHook
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

        # Windows import stubs force-linked on the FOLD link — and only there.
        #
        # These are symbols the fold cannot reach on its own: the mega link knows
        # the captured objects plus depArchives, never the `-l<dll>` a package
        # named on its own link line. They used to ride on the toolchain's
        # cc-ldflags, which put them on EVERY windows link — including autoconf's
        # probes. That poisons any link-only `AC_CHECK_FUNC` for a socket symbol:
        # `select` (vorbis-tools) and `inet_ntop` (opus-tools) both resolved out
        # of ws2_32 and got HAVE_* defined, while the code guarded by that macro
        # includes <sys/select.h>/<arpa/inet.h> — headers mingw has not got. The
        # search PATH (`winImportLibs`) stays global; only the force-link moved.
        winForceLibs = [
          "bcrypt" "ws2_32" "userenv" "secur32" "crypt32" "shlwapi"
          # advapi32/user32: static OpenSSL's Windows entropy + UI paths
          # (rtmpdump links it). winmm/ksuser: libao's WMM driver — waveOut* and
          # the KSDATAFORMAT_SUBTYPE_* GUIDs ksmedia.h declares extern
          # (vorbis-tools' ogg123). iphlpapi: librist's netcalls
          # (GetAdaptersInfo). Each is named on its package's OWN link, but the
          # capture shim only records a `-l<name>` it can resolve to a
          # `lib<name>.a` under an explicit `-L`, and these are sysroot import
          # stubs — so the fold link never inherits them.
          "advapi32" "user32" "winmm" "ksuser" "iphlpapi"
          # cfgmgr32: pciutils' win32-cfgmgr32 backend (CM_Get_Device_ID_List_*,
          # CM_Free_Log_Conf_Handle), named by its lib/configure. ole32: libwebp's
          # WIC image I/O calls CoInitialize/CoCreateInstance (imageio/wicdec.c,
          # imageio/image_enc.c). Deliberately NOT windowscodecs/uuid alongside
          # ole32 — wicdec.c #defines INITGUID, so CLSID_WICImagingFactory and the
          # GUID_WICPixelFormat* are DEFINED in libwebp's own objects, not
          # imported (GUID_WICPixelFormatUndefined is in no import lib at all).
          "cfgmgr32" "ole32"
          # gdi32/avicap32: ffmpeg's windows-only indevs, each named by ffmpeg's
          # own configure and so invisible to the capture shim. gdigrab needs the
          # GDI screen grab (CreateDIBSection/BitBlt/GetDeviceCaps) and the
          # drawtext filter the font enumeration (EnumFontFamiliesExW,
          # CreateFontIndirectW, GetTextFaceW); vfwcap needs avicap32's
          # capCreateCaptureWindowA/capGetDriverDescriptionA. dshow's
          # OleCreatePropertyFrame comes from oleaut32, which ole32 above does NOT
          # cover — it is a separate DLL and a separate import lib.
          "gdi32" "oleaut32" "avicap32"
          # msimg32: cairo's win32 backend (AlphaBlend in the GDI compositor,
          # GradientFill in the printing surface). cairo is one of the deps still
          # built by mingw gcc, so it runs no capture shim and writes no sidecar —
          # the recovery below can never see it, however its own link line reads.
          "msimg32"
        ];

        # mingw-w64's POSIX fills, force-linked on EVERY windows link — the one
        # archive that has to stay global. The engine's mingw libc DECLARES
        # `strtok_r` and defines nothing; giflib and cmocka (under librist) call
        # it, and nothing names mingwex, so the search path alone resolves
        # nothing. Unlike the DLL import stubs above this is a real static
        # archive with real mingw headers behind it, so an autoconf probe that
        # links a symbol out of it is answering honestly — no HAVE_* is set for
        # a header mingw hasn't got. A linker searches an archive only for
        # symbols still undefined, so it fills gaps and displaces nothing.
        winGapLibs = [ "mingwex" ];

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
            sysroot = unpinSysroot {
              inherit pkgs toolchain; triple = target; inherit optClass native cxx;
              lto = ltoFlag != "";
            };
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
              EOF
              # Propagate the seed rather than exporting XDG_CACHE_HOME here, so
              # it reaches any build using this cc, not only `mkDerivation` below.
              # Written by hand: a runCommand runs the build phase alone, so no
              # fixup turns a `propagatedBuildInputs` attr into this file.
              echo ${sysrootSeedHook { inherit pkgs sysroot; }} \
                > $out/nix-support/propagated-build-inputs
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
        #  2. The shims append ${optClass} after "$@" (route-A parity) so the opt
        #     class is one value across a build, not whatever each recipe passes.
        #  3. `sysrootSeedHook` — a generic recipe can still use flag combos the
        #     bake didn't cover (its own -march=, a different opt class), so the
        #     cache has to be writable. `lto` is forwarded to `unpinSysroot` so
        #     the combo this stdenv itself forces is NOT one of them: the shims
        #     append -flto, `-flto` is a variant HASH axis in unpin_musl.cpp, and
        #     an unbaked LTO libc costs ~11 s per C derivation (~38 s with
        #     libc++) rebuilt inside the sandbox and discarded.
        #
        # lto: the cc/c++ shims append `-flto` so every object is LLVM BITCODE,
        # the prerequisite for the module emitter (multicallModuleHookLTO). Off by
        # default — a package opts in. The cpp (-E) shim omits it (clang warns
        # "argument unused" under -E, which a -Werror probe reads as unsupported).
        # The libc is bitcode too: the on-demand build follows the link's own
        # -flto, so musl folds INTO the whole-program LTO. That is what makes the
        # darwin static-name-capture class a darwin one — there libSystem stays
        # outside the module. Verify with `llvm-ar x` on a cached libc.a.
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
            sysroot = unpinSysroot { inherit pkgs toolchain; triple = target; inherit optClass native cxx lto; };
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
            # wchar_t IS ISO 10646 — why the engine says so at all is the mk()
            # comment below, whose "every unpin target is Linux/musl" was written
            # before windows and darwin came through this same wrapper (it is
            # frozen: that text is INSIDE the builder, so rewording it re-hashes
            # the engine cc on every target and with it the whole catalog).
            #
            # Everywhere EXCEPT windows: mingw's wchar_t is 16-bit UTF-16, so the
            # macro's contract — a wchar_t value IS a code point — cannot hold,
            # and neither gcc nor clang defines it on any Windows target. Saying
            # it anyway is a lie the next mingw package inherits; gnulib happens
            # to be immune (it gates on BITSIZEOF_WCHAR_T as well), which is why
            # nothing broke while this was unconditional. Kept on darwin: wchar_t
            # is 32-bit there so the macro is not false, and libedit — the reason
            # the flag exists — exempts __APPLE__ from its own check anyway.
            isoWcharFlag =
              nixpkgs.lib.optionalString (!isWinTarget) " -D__STDC_ISO_10646__=201706L";
            # Windows: force fortify off. The engine's mingw CRT has none of the
            # `__*_chk` shims, so any known-size memcpy/strcpy fails to link. `-U`
            # doesn't work (gnulib's config.h `#if !defined _FORTIFY_SOURCE`
            # re-enables it); `-D_FORTIFY_SOURCE=0`, appended after "$@" so it wins
            # over anything the source set, leaves it DEFINED so gnulib's guard
            # stays false. The cc-wrapper is not the source here — `fortify` is in
            # the hardeningDisable list below on every target. Empty on Linux.
            winFortifyOff = nixpkgs.lib.optionalString isWinTarget " -D_FORTIFY_SOURCE=0";
            # darwin: give every internal-linkage symbol a module-unique name.
            #
            # Under full LTO all bitcode merges into one module, and LLVM's IR
            # linker renames only INTERNAL symbols on a clash — an external
            # definition always keeps the name. On linux the engine compiles musl
            # to bitcode, so libc's own external `close`/`open`/… are in the merged
            # module, win their names, and every file-static homonym is renamed
            # away. On darwin libc is libSystem, outside the LTO: the module holds
            # a bare `declare i32 @close(i32)` and NO external definition, so a
            # file-static `close()` keeps the name and the declaration binds to it.
            # ffmpeg's `file_close()` then passed a file descriptor to a codec's
            # destructor — `movq (%rdi), %rbx` on rdi=3, SIGSEGV — while still
            # writing correct output, so the symptom was exit 139 only on commands
            # that open a file.
            #
            # This is a CLASS, not an instance: ffmpeg's apv_parser.c and libvmaf's
            # six feature extractors each define a static `close`. Only one keeps
            # the bare name at a time, so renaming the culprit just hands the name
            # to the next definition — verified, twice. `-funique-internal-linkage-
            # names` appends a module-unique suffix to every internal symbol
            # (`_close` → `__ZL5closePv.__uniq.<hash>`), so no internal can collide
            # with — or capture — an external declaration, whatever the package.
            #
            # Compile steps only: on a pure link clang reports it as
            # `-Wunused-command-line-argument`, which deps that build with -Werror
            # turn fatal (same trap `-static-libgcc` sprang on cjson/mbedtls).
            # Presence of a source-file argument is the discriminator. darwin-gated,
            # so every non-darwin target emits a byte-identical wrapper script.
            uniqNamesProbe = nixpkgs.lib.optionalString isDarwinTarget ''
              __uniq=""
              for __a in "\$@"; do case "\$__a" in
                *.c|*.cc|*.cpp|*.cxx|*.C|*.m|*.mm) __uniq=" -funique-internal-linkage-names";;
              esac; done
            '';
            uniqNamesArg = nixpkgs.lib.optionalString isDarwinTarget "\\$__uniq";
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
            # Object suffixes the capture shim recognises. CMake targeting Windows
            # names its objects `.obj`; autotools/meson emit `.o` everywhere. The
            # shim bails when it counts zero objects, so on a cmake mingw package
            # it wrote no sidecar at all and the fold died with "no link sidecar"
            # (srt — and aom/jxl/avif/heif/openjpeg would have followed). Appended
            # only for windows, so the shell text of every other target's wrapper
            # — and its drv — stays put.
            objSuffixes = "*.o|*.lo" + nixpkgs.lib.optionalString isWinTarget "|*.obj";
            # CMake's Windows-GNU platform passes objects AND libraries through
            # @response files, so the argv the shim sees carries no object at all:
            # it wrote no sidecar and the fold died with "no link sidecar" after a
            # full srt build. Splice the files back into the argument list. Only
            # for windows — every other target's wrapper text, and drv, stays put.
            # CMake on Windows-GNU `ar`s a target's own objects into `objects.a` and
            # links it under --whole-archive. Record those separately: the fold has
            # to take them WHOLE (as the program's objects), while an ordinary `.a`
            # keeps archive semantics and yields only referenced members. Recorded
            # in ADDITION to the normal classification — a second mention of an
            # archive whose members are already defined pulls nothing — so the
            # existing lines stay byte-identical and no other target's drv moves.
            waInit = nixpkgs.lib.optionalString isWinTarget ''; __wa=0; whole=""'';
            waFlags = nixpkgs.lib.optionalString isWinTarget ''
                  -Wl,--whole-archive|--whole-archive) __wa=1 ;;
                  -Wl,--no-whole-archive|--no-whole-archive) __wa=0 ;;
                  # Any other -Wl option is a LINKER FLAG, never an input, and one
                  # of them ends in `.a`: CMake's `-Wl,--out-implib,libfoo.dll.a`
                  # matched the archive arm below and the fold then tried to open
                  # the flag as a file. Harmless while no sidecar was written.
                  -Wl,*) ;;'';
            waRecord = nixpkgs.lib.optionalString isWinTarget ''[ "$__wa" = 1 ] && whole="$whole$p
              "
                    '';
            waEmit = nixpkgs.lib.optionalString isWinTarget ''

                printf '%s' "$whole"  | while IFS= read -r x; do [ -n "$x" ] && echo "WHOLEA $x"; done'';
            # CMake on Windows-GNU `ar`s the objects into `objects.a` and links THAT
            # with --whole-archive, so a genuine program link can carry zero objects
            # on the command line — srt built completely and then died at the fold
            # with "no link sidecar". A build-tree archive is an equally good signal
            # there; a store-path one is not, that is an ordinary dependency link.
            localArchiveCounts =
              nixpkgs.lib.optionalString isWinTarget ''[ -n "''${locala}" ] || '';
            rspExpand = nixpkgs.lib.optionalString isWinTarget ''

              set -f
              set -- $(for a in "$@"; do
                case "$a" in
                  @?*)     f=''${a#@};     [ -f "$f" ] && tr -d '"' < "$f" || printf '%s\n' "$a" ;;
                  -Wl,@?*) f=''${a#-Wl,@}; [ -f "$f" ] && tr -d '"' < "$f" || printf '%s\n' "$a" ;;
                  *) printf '%s\n' "$a" ;;
                esac
              done)
              set +f
            '';
            captureScript = ''
              #!/bin/sh
              [ -n "''${UNPIN_LINK_DIR:-}" ] || exit 0
              mkdir -p "$UNPIN_LINK_DIR" 2>/dev/null || exit 0${rspExpand}
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
              case "$out" in ${objSuffixes}|*.so|*.so.*|*.os) exit 0 ;; esac
              nobj=0; objs=""; locala=""; storea=""; ldirs=""; lnames=""; prev=""${waInit}
              for a in "$@"; do
                # separated forms: -L <dir>, -l <name>
                case "$prev" in
                  -L) ldirs="$ldirs $a" ;;
                  -l) lnames="$lnames $a" ;;
                esac
                case "$a" in
                  -L?*) ldirs="$ldirs ''${a#-L}" ;;
                  -l?*) lnames="$lnames ''${a#-l}" ;;${waFlags}
                  ${objSuffixes})
                    case "$a" in /*) p="$a" ;; *) p="$(pwd)/$a" ;; esac
                    nobj=$((nobj+1)); objs="$objs$p
              " ;;
                  *.a)
                    case "$a" in /*) p="$a" ;; *) p="$(pwd)/$a" ;; esac
                    ${waRecord}case "$p" in
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
              ${localArchiveCounts}[ "$nobj" -ge 1 ] || exit 0
              # Sidecar is keyed by program name (grep, sed, …); a windows link
              # outputs `<prog>.exe`, so strip `.exe` to keep the name the hook's
              # inferLinkInputs lookup expects (`<prog>.link`, not `<prog>.exe.link`).
              b="$(basename "$out")"; b="''${b%.exe}"
              {
                echo "CWD $(pwd)"
                printf '%s' "$objs"   | while IFS= read -r x; do [ -n "$x" ] && echo "OBJ $x"; done
                printf '%s' "$locala" | while IFS= read -r x; do [ -n "$x" ] && echo "LOCALA $x"; done
                printf '%s' "$storea" | while IFS= read -r x; do [ -n "$x" ] && echo "STOREA $x"; done${waEmit}
              } > "$UNPIN_LINK_DIR/$b.link"
              exit 0
            '';
            captureCall = nixpkgs.lib.optionalString captureLinks
              "[ -n \"\\$UNPIN_CAPTURE_LINKS\" ] && \"$out/libexec/unpin-capture\" \"\\$@\"";
            # `version` is what nixpkgs' version-gated cc branches read
            # (`versionAtLeast stdenv.cc.version …`), so it must be the LLVM the
            # wrapper actually execs — take it from the toolchain instead of
            # repeating the literal, which drifts silently at the next bump.
            ccUnwrapped = pkgs.runCommand "unpin-cc-unwrapped-${target}"
              { passthru = { isGNU = true; inherit (toolchain) version; };
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
              # clang — so the all-deps path now miscompiles it. Defined to gcc's
              # value on the targets where the macro's contract HOLDS (linux-musl and
              # darwin, 32-bit UCS-4 wchar_t), keeping the engine a drop-in for
              # gcc-built sources. \`isoWcharFlag\` withholds it on mingw, whose
              # wchar_t is 16-bit UTF-16.
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
              ${uniqNamesProbe}${darwinEnvSetup}exec ${toolchain}/bin/llvm $2 -target ${target}${isoWcharFlag}${darwinStubFlag} "\$@" ${optClass}${winFortifyOff}\$__lto${uniqNamesArg}
              EOF
                chmod +x "$out/bin/$1"
              }
              mk clang clang ; mk cc clang ; mk gcc clang
              mk clang++ clang++ ; mk c++ clang++ ; mk g++ clang++
              cat > $out/bin/cpp <<EOF
              #!/bin/sh
              ${darwinEnvSetup}exec ${toolchain}/bin/llvm clang -E -target ${target}${isoWcharFlag}${darwinStubFlag} "\$@"
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
              # ld is NOT a plain `mkt` shim. This is the linker a build reaches
              # DIRECTLY (kbuild's `$(LD) -r`, the bespoke `ld -r` folds): the
              # wrapper in front of it appends NIX_LDFLAGS unconditionally, so the
              # partial link sees flags meant for the final one. `-B`-based lld
              # wrapping never covers this path — the wrapper execs us by path.
              cp ${rSafeLd pkgs "${toolchain}/bin/llvm ld.lld"} "$out/bin/${target}-ld"
              cp ${rSafeLd pkgs "${toolchain}/bin/llvm ld.lld"} "$out/bin/${target}-ld.lld"
              chmod +x "$out/bin/${target}-ld" "$out/bin/${target}-ld.lld"
              # windres: the Windows resource compiler (.rc → .res COFF). mingw
              # autotools packages (libiconv, …) compile a version-info resource via
              # libtool's `--tag=RC`, which needs `${target}-windres`. llvm-windres
              # is a GNU-windres drop-in already in the multicall driver. Inert for
              # non-windows targets (never invoked), so added unconditionally.
              mkt windres llvm-windres
              ${nixpkgs.lib.optionalString isWinTarget ''
                # dlltool: builds a PE import library from a .def. mcfgthread's
                # meson build generates libntdll.a that way, through nixpkgs'
                # one-line `dlltool` shim, which execs `${target}-dlltool` off
                # PATH — "command not found" (exit 127) without this. Windows-
                # gated, unlike windres: llvm-dlltool only makes sense for PE, and
                # gating keeps the linux/darwin bintools byte-identical.
                mkt dlltool llvm-dlltool
                # strings: x264's configure runs its endianness test by grepping
                # `${target}-strings -a conftest.o` for a marker ("endian test
                # failed", exit 1, without it). The multicall driver has NO strings
                # subcommand, so this cannot be an `mkt` shim — and printing the
                # printable runs of a file is all any configure probe wants, which
                # is one grep. Every other option real strings takes (offsets,
                # radix, encodings, --bytes) is refused loudly: a stand-in that
                # quietly answers a question it did not understand is worse than a
                # missing tool. Gated with dlltool — nothing off windows has asked
                # for it, and adding it there re-hashes native and darwin for a
                # problem they do not have. Before the engine took over the mingw
                # dep set these packages got the real strings from gcc's bintools.
                cat > "$out/bin/${target}-strings" <<EOF
#! ${staticBuild.runtimeShell}
__f=
for __a in "\$@"; do
  case "\$__a" in
    -a|--all) ;;
    -*) echo "${target}-strings: unsupported option \$__a" >&2; exit 2 ;;
    *) __f="\$__f \$__a" ;;
  esac
done
LC_ALL=C exec ${staticBuild.gnugrep}/bin/grep -hoaE '[[:print:]]{4,}' \$__f
EOF
                chmod +x "$out/bin/${target}-strings"
              ''}
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
                # …and re-point `ld` at the Mach-O lld. `ld.lld` is the ELF driver;
                # on a darwin target it rejects every Mach-O flag the driver emits
                # ("unknown argument '-arch'", "-syslibroot: Is a directory"). The
                # engine's own cc reaches ld64.lld through the toolchain, so this
                # only bites when something else resolves the linker BY NAME —
                # clang searches PATH for `<triple>-ld` before plain `ld`, so a
                # compiler paired with cctools/ld64 (the darwin CC_FOR_BUILD) still
                # picks this shim up and links with the wrong flavour. meson then
                # reports it as "Compiler for language c for the build machine not
                # found" (fribidi's gen.tab needs one). Darwin-gated; ELF/PE
                # targets keep ld.lld byte-identical.
                # Remove before writing: the `-r` guard above installs `ld` with
                # `cp` from the store, so the file arrives read-only and a
                # redirect onto it dies with "Permission denied". Only darwin
                # re-points ld, so only darwin ever hit it.
                rm -f "$out/bin/${target}-ld" "$out/bin/${target}-ld.lld"
                # Same guard as the ELF `ld`, around the Mach-O driver — a plain
                # shim here would drop it, and `-force_load` (two tokens, darwin
                # only) is the one rule in rSafeStrip that no other target can
                # exercise.
                for n in ld ld.lld ld64.lld; do
                  cp ${rSafeLd pkgs "${toolchain}/bin/llvm ld64.lld"} "$out/bin/${target}-$n"
                  chmod +x "$out/bin/${target}-$n"
                done
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
            # windows (PE) target: the mingw and windows-gnu triple spellings.
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
            # Windows: the engine resolves default CRT import libs from its VFS,
            # but EXTRA `-l<dll>` libs (bcrypt, ws2_32) are synthesized in-memory
            # from VFS .def files and that synthesis FAILS in the build sandbox
            # ("unable to find library"). nixpkgs' mingw-w64 ships them as real
            # ABI-neutral import stubs, so they come off disk instead.
            #
            # THREE roles, deliberately different sets. This search PATH carries
            # every stub: a dep names whatever Win32 API it uses on its own link
            # line, and an omission there is a build failure the package cannot
            # fix (openssl's apps/openssl.exe wants -lgdi32). `winGapLibs` is
            # force-linked here, on every link. `winForceLibs` is force-linked by
            # the FOLD link alone — see its definition for why it must not be
            # global.
            #
            # Off the path: the CRT/startup archives the engine supplies itself
            # (msvcr*/ucrt*/mingw32/mingwthrd/moldname/kernel32), which would
            # shadow its startup objects. They were not reachable before this dir
            # went broad either.
            #
            # libm.a STAYS: mingw's is a 602-byte archive with one dummy member and
            # no defined symbols — the math lives in the CRT — and it exists exactly
            # so `-lm` resolves. Withholding it only broke every package that says
            # -lm (lua, quickjs). An EMPTY libm is also what the native engine wants
            # on the CMake side, so nothing here can escape to a foreign libm.
            #
            # libmingwex.a STAYS on the path — and is force-linked (winGapLibs).
            winImportLibs = pkgs.runCommand "unpin-win-implibs-${target}" { } ''
              mkdir -p $out/lib
              for f in ${pkgs.windows.mingw_w64}/lib/lib*.a; do
                case "$(basename "$f")" in
                  libkernel32.a|libmingw32.a|libmingwthrd.a|libmoldname.a|libmsvcr*|libucrt*) continue ;;
                esac
                ln -s "$f" $out/lib/
              done
              # Every force-linked name must be ON that path: one that isn't turns
              # into `unable to find library` on EVERY windows link, so fail here
              # rather than in each package's build.
              for L in ${nixpkgs.lib.concatStringsSep " " (winForceLibs ++ winGapLibs)}; do
                [ -e "$out/lib/lib$L.a" ] || { echo "force-linked lib$L.a is not on the link path"; exit 1; }
              done
            '';
            ccExtraBuildCommands = unprefixAliases
              + nixpkgs.lib.optionalString isWinTarget ''
                # `gcc`/`g++` aliases (bare + target-PREFIXED). Some deps build
                # through a bespoke, non-autotools Makefile that hardcodes the
                # gnu compiler by name — e.g. zlib's `win32/Makefile.gcc` invokes
                # `''${PREFIX}gcc` (= `x86_64-w64-mingw32-gcc`) literally, never
                # `$CC`. The cc-wrapper only exposes `cc`/`clang`: its builder
                # tests `$ccPath/clang` BEFORE `$ccPath/gcc`, and ccUnwrapped
                # ships both, so the clang branch wins and no `gcc` is wrapped
                # (isGNU has no say here); `unprefixAliases` then adds the bare
                # names next to the wrapper's prefixed ones. The prefixed BINTOOLS
                # (`${target}-ar`/`-ranlib`) already exist (bintoolsUnwrapped);
                # add the matching `gcc`/`g++` CC aliases (point at the `clang`/
                # `clang++` wrapper scripts, which resolve) so such Makefiles find
                # the engine compiler. Windows-only — linux/cosmo are untouched.
                # Scripts, not symlinks: clang implements no Ada or Fortran front
                # end and delegates those sources to `${target}-gcc` — which, as a
                # symlink back to clang, delegates again. binutils' configure probes
                # Ada (ACX_PROG_GNAT) and that loop reached 4597 processes / 24 GB.
                # Refusing is also the honest answer, and configure reads a nonzero
                # exit as the "no" it was asking for.
                for pair in gcc:clang g++:clang++ ${target}-gcc:clang ${target}-g++:clang++; do
                  name=''${pair%%:*}; real=''${pair##*:}
                  cat > "$out/bin/$name" <<EOF
#! ${staticBuild.runtimeShell}
for a in "\$@"; do
  case "\$a" in
    *.adb|*.ads|*.f|*.F|*.for|*.FOR|*.f77|*.f90|*.F90|*.f95|*.F95|*.f03|*.F03|*.f08|*.F08)
      echo "$name: the unpin engine has no Ada or Fortran compiler" >&2; exit 1 ;;
  esac
done
exec "$out/bin/$real" "\$@"
EOF
                  chmod +x "$out/bin/$name"
                done
                echo "-L${winImportLibs}/lib" >> $out/nix-support/cc-ldflags
                echo "${nixpkgs.lib.concatMapStringsSep " " (l: "-l${l}") winGapLibs}" >> $out/nix-support/cc-ldflags
              '';
            bintools = staticBuild.wrapBintoolsWith ({
              bintools = bintoolsUnwrapped; libc = null; extraBuildCommands = unprefixAliases;
            } // appleSdkOverride);
            cc = staticBuild.wrapCCWith ({
              inherit bintools; cc = ccUnwrapped; libc = null; extraPackages = [ ];
              extraBuildCommands = ccExtraBuildCommands;
            } // appleSdkOverride);
            seedHook = sysrootSeedHook { inherit pkgs sysroot; };
            captureHook = pkgs.makeSetupHook { name = "unpin-capture-links"; }
              (pkgs.writeText "unpin-capture-links.sh" ''
                export UNPIN_CAPTURE_LINKS=1
                export UNPIN_LINK_DIR="''${NIX_BUILD_TOP:-$TMPDIR}/.unpin-links"
              '');
            # nixpkgs' makeStaticDarwin adapter appends `-static-libgcc` to
            # NIX_CFLAGS_LINK whenever `stdenv.cc.isGNU` — and the engine cc claims
            # GNU on purpose (see (1) in the header). The adapter re-reads
            # `stdenv.cc` AFTER the overrideCC below, so darwin pkgsStatic hands
            # every engine derivation a flag ld64 never had; clang answers
            # `argument unused during compilation` on every link. Invisible until a
            # package makes that warning fatal — and three do. cjson and mbedtls
            # build their demos/tests with -Werror. Worse, svt-av1's `check_flag`
            # probes ADD `-Werror=unused-command-line-argument`, so EVERY probe
            # reported "No" (even `-Wall`): `-mavx2` never reached the ASM_AVX2
            # sources and the intrinsics refused to inline. Drop the flag instead of
            # patching each package: it means nothing on Mach-O, so this changes no
            # link — only what clang has to complain about.
            dropStaticLibgccHook = pkgs.makeSetupHook
              { name = "unpin-drop-static-libgcc"; }
              (pkgs.writeText "unpin-drop-static-libgcc.sh" ''
                unpinDropStaticLibgcc() {
                  if [ -n "''${NIX_CFLAGS_LINK:-}" ]; then
                    export NIX_CFLAGS_LINK="''${NIX_CFLAGS_LINK//-static-libgcc/}"
                  fi
                }
                preConfigureHooks+=(unpinDropStaticLibgcc)
                preBuildHooks+=(unpinDropStaticLibgcc)
                # Also now: a package's own preConfigure ATTR runs before the
                # preConfigureHooks array and can already probe flags (svt-av1's
                # cmake does), same ordering trap seedHook documents above.
                unpinDropStaticLibgcc
              '');
          in
          # dontPatchELF: static-musl has no interp/RPATH to touch.
          # Hardening: every default flag off EXCEPT stackprotector. `fortify` is
          # what put this at `all` (musl implements only part of the `__*_chk`
          # surface and the engine's mingw CRT none of it), but `all` also drops
          # `-fstack-protector-strong`, so an engine binary carried no canary
          # where the pre-engine static-musl gcc build did (measured on the same
          # nixpkgs zlib: 32 `%fs:0x28` loads before, no `sspstrong` attribute in
          # the engine bitcode after), and `optimize.ssp` could not give it back
          # — it only ever subtracts. musl and libSystem both export
          # `__stack_chk_fail`/`__stack_chk_guard`, so the flag costs one link
          # symbol and ~1.4% of text (sed: 0 -> 90 canary loads, +4960 B).
          # Two targets are a deliberate no-op, and nixpkgs decides it, not us:
          # its cc-wrapper strips `stackprotector` as unsupported on mingw and on
          # musl-x86_32, so `windows-x86_64` and `linux-i686` rebuild BYTE-
          # IDENTICAL. darwin already had clang's on-by-default `-fstack-
          # protector` and moves to `strong`.
          # Subtracted from the wrapper's OWN default list, so a nixpkgs bump that
          # adds a hardening default inherits today's posture (off) instead of
          # silently enabling it. Re-enabling any of the other ten is a separate
          # per-flag decision, not a cleanup: `format` is -Werror, `pic` flips the
          # on-demand libc's variant hash, `libcxxhardeningfast` would define a
          # hardening mode the driver's own libc++ was not built with.
          # No dontStrip — unlike cosmocc's APE, static-musl ELF strips fine, so
          # strippedOrJoined's final strip applies.
          pkgs.stdenvAdapters.addAttrsToDerivation
            ({ dontPatchELF = true;
               hardeningDisable =
                 nixpkgs.lib.remove "stackprotector" cc.defaultHardeningFlags; }
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
                ++ nixpkgs.lib.optional captureLinks captureHook
                ++ nixpkgs.lib.optional isDarwinTarget dropStaticLibgccHook;
              # The darwin stdenv bakes `apple-sdk` into `extraBuildInputs`, so
              # every mkDerivation pulls the SDK's setup hooks (re-export SDKROOT,
              # -isysroot/-syslibroot, Csu crt) that fight the engine's crt-less
              # Mach-O link. We supply the SDK via SDKROOT instead, so drop it from
              # the default inputs on darwin. Untouched elsewhere.
              extraBuildInputs =
                if isDarwinTarget then [ ] else (old.extraBuildInputs or [ ]);
            }));

        # Is this package set built by the engine cc? Every per-target fix that
        # works around a clang-vs-gcc difference gates on it, so it has ONE
        # definition: the cc is named by `unpinCC`/`ccUnwrapped` above, and a
        # rename there must not silently turn a dozen fixes into no-ops.
        isUnpinEngine = pkgs:
          nixpkgs.lib.hasInfix "unpin-cc" (pkgs.stdenv.cc.name or "");

        # Append `flags` (string or list) to one of the cc-wrapper's flag
        # variables. A structuredAttrs drv presets the variable inside `env`, and
        # writing it at top level as well collides ("attribute set cannot contain
        # any attributes passed to derivation") — so append wherever the existing
        # value already lives, never both. `oa ? env && oa.env ? <var>` is the
        # only usable test: `__structuredAttrs` is invisible in overrideAttrs'
        # argument. A top-level scalar exports fine when the variable is absent.
        appendDrvFlags = var: drv: flags:
          let
            flagStr = builtins.concatStringsSep " "
              (if builtins.isList flags then flags else [ flags ]);
          in
          # Appending nothing is identity — a caller whose flag list is empty
          # under some option (lto.nix's SSP keep-syms with `ssp = false`) must
          # not end up declaring the variable, let alone with a stray space.
          if flagStr == "" then drv else
          drv.overrideAttrs (oa:
            if oa ? env && oa.env ? ${var} then {
              env = oa.env // { ${var} = oa.env.${var} + " " + flagStr; };
            } else if oa ? ${var} then {
              ${var} = oa.${var} + " " + flagStr;
            } else {
              ${var} = flagStr;
            });

        appendCFlags = appendDrvFlags "NIX_CFLAGS_COMPILE";

        # cc-wrapper LINK-time flags. Unlike NIX_LDFLAGS these reach ONLY
        # $CC-driven links, never a direct `ld -r`, so --gc-sections/--icf are
        # safe here.
        appendLinkFlags = appendDrvFlags "NIX_CFLAGS_LINK";

        # Raw `ld` flags. Unlike NIX_CFLAGS_LINK these survive a build that wipes
        # NIX_CFLAGS_LINK in postConfigure (nixpkgs' whois drops the bootstrap
        # `-static` that way), and it's the mechanism fastfetch already uses for
        # its `--wrap=dlopen`. Entries are passed straight to ld, so use
        # `--wrap=…` (not `-Wl,…`).
        appendLdFlags = appendDrvFlags "NIX_LDFLAGS";

        # Bash build-correctness override (`bash`/`bashInteractive`/
        # `bashNonInteractive`). Two faults: configure bakes a bare `CC=gcc` that
        # can't do the static link, and the codegen tools (mkbuiltins/mksignames)
        # hit C23 where bash-5.3's `typedef unsigned char bool` is rejected — force
        # them onto gnu17. Drv-level so it reaches whichever variant a consumer
        # pulls; idempotent via the `unpinNativeFixed` marker.
        unpinBashBuildFix = pkgs: drv:
          let
            host = drv.stdenv.hostPlatform;
            buildp = drv.stdenv.buildPlatform;
            cc = drv.stdenv.cc;
            buildCC = pkgs.buildPackages.stdenv.cc;
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
          else drv.overrideAttrs (oa: {
            passthru = (oa.passthru or { }) // { unpinNativeFixed = true; };
            preConfigure = (oa.preConfigure or "") + ''
              export CC=${cc}/bin/cc
              export CXX=${cc}/bin/c++
            '';
            makeFlags = (oa.makeFlags or [ ]) ++ [ "CC=${cc}/bin/cc" ];
            # CC_FOR_BUILD has a space → can't ride in word-split `makeFlags`; the
            # `makeFlagsArray` bash array keeps it intact.
            preBuild = (oa.preBuild or "") + ''
              makeFlagsArray+=( "CC_FOR_BUILD=${ccForBuild} -std=gnu17${ldPathFlag}" )
            '';
          });

        # Which targets use lld, the unpins-standard linker, and so get
        # `lldStdOpts`. Every exclusion carries its reason at its own clause;
        # excluded targets get NO substitute --gc-sections — the size win is a
        # Linux-native-lld property, and these are all size-neutral crosses.
        isLLDTarget = pkgs:
          let h = pkgs.stdenv.hostPlatform;
          # clang + Apple ld64; allowlist/codesign is link-sensitive.
          in !(h.isDarwin)
          # cosmo (isWindows && !isMinGW) brings cosmocc, its own toolchain.
          && !(h.isWindows && !(h.isMinGW or false))
          # riscv64: lld emits "relocation refers to a symbol in a discarded
          # section" (RISC-V relaxation × section-discard) even without
          # --gc-sections/--icf; GNU ld doesn't.
          && !(h.isRiscV or false)
          # ppc64le: lld doesn't synthesize the PowerPC out-of-line FP
          # save/restore routines (libgcc crtsavres) GNU ld generates on demand,
          # so any FP-heavy static link fails with undefined _restfpr_N.
          && !(h.isPower or false)
          # m68k: ld.lld has no m68k backend ("unknown emulation: m68kelf").
          && !(h.isM68k or false)
          # mips/s390x (tier-3 `.#cross`): lld support absent or incomplete.
          && !(h.isMips or false)
          && !(h.isS390 or false);

        # Flags that only make sense on a FULL link, dropped from a relocatable
        # (`-r`/`-i`) one. Two classes:
        #   - ILLEGAL there: `--icf` ("-r and --icf may not be used together"),
        #     which lldStdOpts puts on every $CC link including the `$CC -r`
        #     partial-links some builds emit;
        #   - WRONG there: `--wrap` must rewrite each reference exactly once, at
        #     the final link; and the dns-fallback block rides NIX_LDFLAGS, which
        #     the ld wrapper appends to EVERY invocation (its own `relocatable`
        #     flag gates only the build-id) — so a partial link pulls
        #     libunpindns.a and whatever libc members the re-stated `-lc` resolves
        #     into the object. `ld -r` really does extract archive members, GNU ld
        #     and ld.lld alike. Cost: duplicated libc text per applet, and a hard
        #     i686 failure once a later objcopy localizes their COMDAT pc-thunks —
        #     moreutils 568662f worked around exactly this with the raw ld.
        # The libc re-statement (`-lc`; mingw's `-lws2_32 -lkernel32 -lmsvcrt`)
        # exists ONLY to follow our archive, so it is dropped only alongside it: a
        # build that states its own libs on an `-r` keeps them.
        # POSIX sh, no arrays — both shims below embed it verbatim.
        rSafeStrip = ''
          __reloc=0; __dns=0
          for __a in "$@"; do
            case "$__a" in
              -r|--relocatable|-i) __reloc=1 ;;
              -lunpindns|*libunpindns.a) __dns=1 ;;
            esac
          done
          if [ "$__reloc" = 1 ]; then
            __n=$#; __skip=0
            while [ "$__n" -gt 0 ]; do
              __a=$1; shift; __n=$((__n-1))
              if [ "$__skip" = 1 ]; then __skip=0; continue; fi
              case "$__a" in
                --icf|--icf=*) continue ;;
                --wrap=*) continue ;;
                --wrap) __skip=1; continue ;;
              esac
              if [ "$__dns" = 1 ]; then
                case "$__a" in
                  -lunpindns|-l:libunpindns.a) continue ;;
                  -lc|-lws2_32|-lkernel32|-lmsvcrt) continue ;;
                  -L*unpin-dns-fallback*) continue ;;
                  -force_load)
                    # darwin: two-token, and only ours — a build's own
                    # -force_load of something else survives.
                    if [ "$__n" -gt 0 ]; then
                      case "$1" in
                        *libunpindns.a) shift; __n=$((__n-1)); continue ;;
                      esac
                    fi
                    ;;
                esac
              fi
              set -- "$@" "$__a"
            done
          fi
        '';

        # An `ld` that applies rSafeStrip and then execs the real one. `real` is a
        # command prefix, so it can be a plain path or the toolchain's multicall
        # (`llvm ld.lld`).
        rSafeLd = wpkgs: real: wpkgs.writeScript "unpin-ld-rsafe" ''
          #!/bin/sh
          ${rSafeStrip}
          exec ${real} "$@"
        '';

        # Drop-in `-B<dir>`/PATH replacement for lld/bin: same tools, an -r-safe
        # `ld.lld`. This covers the driver-found linker (`-fuse-ld=lld` + `-B`);
        # the `ld` a build invokes DIRECTLY is covered in bintoolsUnwrapped.
        # gc.nix also puts this in a gc'd package's nativeBuildInputs, but NOT in
        # the unpin-llvm toolchain's own closure (measured: zero references), so
        # editing it does not force a toolchain rebuild. `buildPkgs` must be the
        # recursion-safe build-platform scope (see withLLDLink).
        lldRSafe = buildPkgs:
          buildPkgs.runCommand "lld-rsafe-${buildPkgs.lld.version}" { } ''
            mkdir -p $out/bin
            for f in ${buildPkgs.lld}/bin/*; do
              ln -s "$f" "$out/bin/$(basename "$f")"
            done
            rm -f $out/bin/ld.lld
            cp ${rSafeLd buildPkgs "${buildPkgs.lld}/bin/ld.lld"} $out/bin/ld.lld
            chmod +x $out/bin/ld.lld
          '';

        # The unpins-standard lld options, and the ONE place they are spelled:
        # every channel that adds them (gcSectionsFlag's post-link, gc.nix's two
        # in-build channels, withLLDLink) reads this string. `--icf=all` is NOT
        # used — it breaks function/data-pointer identity and risks codec-table
        # miscompiles. Valid only on a FULL link, never `ld -r`, where both
        # --gc-sections and --icf error out; lldRSafe covers the `$CC -r` case.
        lldStdOpts = "-fuse-ld=lld -Wl,--gc-sections -Wl,--icf=safe";
        # `-B<lld>/bin` makes the driver find `ld.lld` for `-fuse-ld=lld` without
        # lld on PATH, so appending `${lib.gcSectionsFlag pkgs}` to a post-link is
        # self-sufficient (no per-package nativeBuildInputs edit). lld/bin ships no
        # `ld`/`as`/`ar`, so -B can't shadow the build's binutils.
        gcSectionsFlag = pkgs:
          if isLLDTarget pkgs then
            "-B${lldRSafe pkgs.buildPackages}/bin ${lldStdOpts}"
          else "";

        # `lld` build tool for the scope. Only needed where a link uses
        # `-fuse-ld=lld` WITHOUT going through gcSectionsFlag's `-B` (e.g. the
        # gc-overlay single-binary makeFlagsArray). Empty off the lld targets.
        lldFinalLink = pkgs:
          if isLLDTarget pkgs then [ (lldRSafe pkgs.buildPackages) ]
          else [ ];

        # Loader shared by the three per-target fix directories: `<pkg>.nix` is
        # the fix for `<pkg>`, so there is no index to drift from the files.
        importFixDir = { dir, lib }:
          nixpkgs.lib.mapAttrs'
            (file: _: nixpkgs.lib.nameValuePair
              (nixpkgs.lib.removeSuffix ".nix" file)
              (import (dir + "/${file}") { inherit lib; }))
            (nixpkgs.lib.filterAttrs
              (file: type: type == "regular"
                && file != "default.nix"
                && nixpkgs.lib.hasSuffix ".nix" file)
              (builtins.readDir dir));

        # meson refuses `add_languages('objc')` in cross mode unless the cross
        # file names objc/objcpp, and nixpkgs' darwin cross file omits both — so
        # a linux→darwin cross-eval aborts for any package that calls it (glib,
        # pango). Emitted at build time so `$CC`/`$CXX` expand there. meson
        # REPLACES (not merges) a [host_machine] a later --cross-file redefines,
        # hence the full section rather than just `subsystem` — which is the
        # second half of the fix, since it cannot autodetect in cross mode
        # ("Subsystem not defined or could not be autodetected").
        #
        # ATTACH PER-PACKAGE, never by overriding the global `meson`. gnutar's
        # checkPhase closure transitively pulls `meson`, so ANY change to the
        # `meson` derivation re-hashes the whole darwin stdenv closure — gnutar
        # included — forcing a from-source rebuild on the GHA macos-14 runner
        # where gnutar test 155 (time01 "tricky time stamps") fails, cascading to
        # EVERY darwin build.
        withDarwinMesonObjc = pkgs: drv:
          let hp = pkgs.stdenv.hostPlatform; in
          drv.overrideAttrs (oa: {
            preConfigure = (oa.preConfigure or "") + ''
              cat > "$NIX_BUILD_TOP/objc-cross.conf" <<EOF
              [binaries]
              objc = '$CC'
              objcpp = '$CXX'

              [host_machine]
              system = 'darwin'
              cpu_family = '${if hp.isAarch64 then "aarch64" else "x86_64"}'
              cpu = '${hp.parsed.cpu.name}'
              endian = 'little'
              subsystem = 'macos'
              EOF
              mesonFlagsArray+=("--cross-file=$NIX_BUILD_TOP/objc-cross.conf")
            '';
          });

        # Shell that prepends `flags` to the `Cflags:` of every `.pc` in `pcGlob`
        # (an unquoted shell word list — globs and `$dev`/`$out` both fine; a path
        # that doesn't exist is skipped, which is how a `$dev`-or-`$out` pair is
        # expressed).
        #
        # The recurring need is `-D<X>_STATIC`: a library whose headers default to
        # `__declspec(dllimport)` is built static with the macro defined, but the
        # `.pc` upstream ships never propagates it, so a static CONSUMER compiles
        # dllimport declarations and emits `__imp_*` that the plain `.a` cannot
        # satisfy. See [[mingw-dllimport-static-pattern]].
        #
        # `^Cflags:` without the trailing space is deliberate: it also fixes a
        # `.pc` whose Cflags line is empty, and for a non-empty line it yields the
        # exact same text as matching `^Cflags: `. The grep makes it idempotent —
        # a package rewritten in both postInstall and postFixup, or a `.pc` that
        # already carries the macro upstream, must not get it twice.
        withPcCflags = flags: pcGlob: ''
          for pc in ${pcGlob}; do
            [ -f "$pc" ] || continue
            grep -qF -- '${flags}' "$pc" || sed -i 's|^Cflags:|Cflags: ${flags}|' "$pc"
          done
        '';

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
        # drv (re-hashes the world, see withDarwinMesonObjc above). Gated to
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
          drv.overrideAttrs (oa: {
            nativeBuildInputs = (oa.nativeBuildInputs or [ ]) ++ [ hook ];
          });

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
                  lldStdOpts).overrideAttrs (oa: {
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
                  nativeBuildInputs = (oa.nativeBuildInputs or [ ])
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
          else drv.overrideAttrs (oa: {
            postFixup = (oa.postFixup or "") + ''
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
        #
        # nixpkgs compiles OPENSSLDIR/ENGINESDIR/MODULESDIR into libcrypto as
        # paths; left alone they point at the /nix/store output — a store ref in
        # a self-contained binary, and a path absent on the user's host. Retarget
        # them to the conventional system location (`sslDir` = /etc/ssl natively,
        # C:/ssl on Windows) so the binary stays 0-ref and reads the host's
        # openssl.cnf + trust store like a distro openssl. engines-3/ossl-modules
        # are openssl's own fixed layout under it, not a choice — hence one
        # parameter, not three.
        #
        # Dropping `no-ct` is the same change, not a second one: nixpkgs adds it
        # for static builds solely because CT bakes a /nix/store CTLOG_FILE, which
        # now follows OPENSSLDIR to sslDir/ct_log_list.cnf. So CT ships.
        #
        # c_rehash (legacy perl-equivalent of `openssl rehash`) is deleted in two
        # halves, because it arrives twice: `make install_sw` installs upstream's
        # perl script, then nixpkgs' postInstall overwrites it with a makeWrapper
        # shim. The `rm` handles the script; the stub handles the shim — which
        # must never be *built*, since makeBinaryWrapper compiles it with
        # `cc -x c -` and under the engine the cc-wrapper appends crt1.o while
        # -x c is still active, so clang parses the ELF crt as C
        # (-Werror,-Wnull-character). Non-engine builds compiled it fine and
        # deleted it anyway, so the stub costs them nothing.
        retargetOpenssl = sslDir: oa: {
          configureFlags = builtins.filter (f: f != "no-ct") (oa.configureFlags or [ ]);
          buildFlags = (oa.buildFlags or [ ]) ++ [
            "OPENSSLDIR=${sslDir}"
            "ENGINESDIR=${sslDir}/engines-3"
            "MODULESDIR=${sslDir}/ossl-modules"
          ];
          postInstall = ''
            makeWrapper() { :; }
          '' + (oa.postInstall or "") + ''
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
            isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
            isLinux = pkgs.stdenv.hostPlatform.isLinux;
            static = pkgs.pkgsStatic;
            noOpenssl = nixpkgs.lib.filter (d: !(nixpkgs.lib.hasInfix "openssl" (d.name or "")));
          in
          (static.libarchive.override { xarSupport = false; }).overrideAttrs (oa: {
            doCheck = false;
            buildInputs = noOpenssl (oa.buildInputs or [ ])
              ++ nixpkgs.lib.optional isDarwin static.libiconvReal;
            # mbedtls is PROPAGATED (not a plain buildInput) so every consumer's
            # link environment carries its -L: e2fsprogs' configure copies
            # libarchive's `-lmbedcrypto` into its own Makefiles (it doesn't read
            # the .la via libtool at link), so the search path must reach it that
            # way. Propagation also lands mbedcrypto.a in each consumer's manifest
            # depInputDirs, so the mega has it available — tar's applet references
            # it (pulled), e2fsprogs' format_tar-only applet does not (left out).
            propagatedBuildInputs = noOpenssl (oa.propagatedBuildInputs or [ ])
              ++ nixpkgs.lib.optional isLinux static.mbedtls;
            configureFlags = (oa.configureFlags or [ ]) ++ [ "--without-openssl" ]
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
            '' + nixpkgs.lib.optionalString isLinux ''
              sed -i $lib/lib/libarchive.la \
                -e 's|-lmbedcrypto|-L${nixpkgs.lib.getLib static.mbedtls}/lib -lmbedcrypto|'
            '';
          } // nixpkgs.lib.optionalAttrs isDarwin {
            preConfigure = (oa.preConfigure or "") + ''
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
          then drv.overrideAttrs (oa: {
            configureFlags = builtins.filter
              (f: f != "--enable-static" && f != "--disable-shared")
              (oa.configureFlags or [ ]);
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
          else appendLdFlags
            (drv.overrideAttrs (oa: {
              buildInputs = [ pkgs.pkgsStatic.libiconv ] ++ (oa.buildInputs or [ ]);
              preBuild = (oa.preBuild or "")
                + nixpkgs.lib.optionalString cross ''
                  export NIX_LDFLAGS_${buildSalt}="''${NIX_LDFLAGS_${buildSalt}:-} -L${nixpkgs.lib.getLib pkgs.buildPackages.libiconv}/lib"
                '';
            }))
            "-liconv";

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
            # A link that did not resolve would vanish without a trace: the pack
            # tool walks FTW_PHYS and returns 0 on anything that is not a file or
            # a dir, and the completeness check below lists `-type f`, so neither
            # end sees it. That is the exact silent-loss shape the check exists to
            # stop, so refuse instead — a `.so` redirect to a page outside the
            # harvested tree means the man set is incomplete, not that the link is
            # optional.
            __ues_dangling="$(find "$__ues_acc" -type l | sed "s|^$__ues_acc/||" | tr '\n' ' ')"
            if [ -n "$__ues_dangling" ]; then
              echo "unpin embed: unresolved links in $__ues_bin's stage: $__ues_dangling" >&2
              exit 1
            fi

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

            # Read the container back out of the binary we just wrote and require
            # every staged file to be in it. Twice an embed silently never reached
            # the shipped binary — stdenv strip rebuilt the copy from its sections
            # and dropped the EOF ZIP; a second appended ZIP shadowed the first on
            # windows — and nothing ever looked at the result, so both shipped.
            # Listing only (`-Z1`), which reads a zstd-method archive fine and
            # needs no execution: this holds on cross and windows targets too.
            # `|| true`: the case this guard exists to catch is "no container at
            # all", and unzip exits 9 on that — under pipefail it would abort with
            # an opaque error instead of the diagnostic below.
            { unzip -Z1 "$__ues_bin" 2>/dev/null || true; } | LC_ALL=C sort > "$__ues_acc.have"
            (cd "$__ues_acc" && find . -mindepth 1 -type f | sed 's|^\./||') \
              | LC_ALL=C sort > "$__ues_acc.want"
            __ues_gone="$(LC_ALL=C comm -23 "$__ues_acc.want" "$__ues_acc.have" | tr '\n' ' ')"
            if [ -n "$__ues_gone" ]; then
              echo "unpin embed: staged entries absent from $__ues_bin: $__ues_gone" >&2
              exit 1
            fi

            # An embedded alias is a LOGICAL name — `unpin` re-adds the platform
            # suffix at install, so a harvested `play.exe` materializes as
            # `play.exe.exe`. Any suffix that survived a harvest is that bug.
            if [ -f "$__ues_acc/unpin/aliases" ]; then
              __ues_suffixed="$( { grep -E '\.(exe|ape)$' "$__ues_acc/unpin/aliases" || true; } | tr '\n' ' ')"
              if [ -n "$__ues_suffixed" ]; then
                echo "unpin embed: aliases carry a platform suffix: $__ues_suffixed" >&2
                exit 1
              fi
            fi
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

              # Lets mkStandaloneFlake see what this build already packed: `man` so
              # it skips its own withMan (one pack, not two), `aliases` so
              # unpinEmbedWrap knows there is a list to read back out of the
              # binary — without the marker it would have to probe every base.
              passthru = (old.passthru or { })
                // nixpkgs.lib.optionalAttrs manEnabled { unpinEmbedsMan = true; }
                // nixpkgs.lib.optionalAttrs aliasesActive { unpinEmbedsAliases = true; };

              postInstall = (old.postInstall or "")
                + nixpkgs.lib.optionalString hasAuto ''
                # Harvest every multi-call symlink (skipping the primary, which
                # is the real binary). No name filtering here: alias policy —
                # charset/length rules, Windows-reserved names, blocklist, the
                # catalog-owner gate, the MAX_ALIASES cap — lives solely in
                # unpin and runs at install time (`validate_alias` in
                # unpin/src/aliases.rs). The build just records which applets
                # the package ships; the installer decides which are safe to
                # link.
                #
                # An alias is a LOGICAL name; `.exe` is the platform's spelling
                # of it. `unpin` appends the suffix itself when it creates the
                # link (platform::link_filename), so a harvested `play.exe`
                # installs as `play.exe.exe` — verified on Windows: `play.exe`
                # runs sox in play mode, `play.exe.exe` falls back to plain sox,
                # silently. Strip it here, the same way the dispatcher strips it
                # off argv[0] on the way in.
                __unpin_aliases=""
                for f in "''${${binOutputName}}/${aliasesFromSymlinksIn}"/*; do
                  [ -L "$f" ] || continue
                  n="$(basename "$f")"; n="''${n%.exe}"
                  [ "$n" = "${nixpkgs.lib.removeSuffix ".exe" primary}" ] && continue
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
          , compatLinks ? [ ]       # extra bin/ names symlinked to the primary in
                                    # the SHIPPED tree. The wrap copies only the
                                    # primary variants, so a compat symlink the
                                    # base installed reaches the ZIP as an alias
                                    # but leaves no file — and action-build looks
                                    # up `result/bin/<package>` by path. Needed
                                    # only when binName ≠ name; [] leaves the drv
                                    # byte-identical.
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
            # The wrap's own alias discovery — sibling symlinks of the primary,
            # like the multicall `.a` glob. Shared by both non-explicit branches
            # below (it is also the fallback when the base packed an empty list).
            # `.exe` stripped for the same reason withUnpinEmbed's harvest strips
            # it: the embedded name is LOGICAL, and `unpin` re-adds the suffix.
            harvestAliasesSh = ''
              if [ -d "${binOut}/bin" ]; then
                for f in "${binOut}/bin"/*; do
                  [ -L "$f" ] || continue
                  __unpin_n="$(basename "$f")"; __unpin_n="''${__unpin_n%.exe}"
                  [ "$__unpin_n" = "${nixpkgs.lib.removeSuffix ".exe" primary}" ] && continue
                  __unpin_al="''${__unpin_al:+$__unpin_al,}$__unpin_n"
                done
              fi'';   # no trailing newline: the callers supply their own
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
              # version/pname) so the mega manifest and withMetaPins still resolve
              # against the shipped drv.
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
              fi${nixpkgs.lib.optionalString (compatLinks != [ ]) ''

              # Compat names, one symlink per variant that exists. The `-e` guard
              # is for darwin: on a case-insensitive store `Xvnc` and `xvnc` are
              # the same file, so the link is both impossible and unnecessary.
              # Glued to the `fi` above for the reason spelled out at the
              # removeReferences block: an interpolation on its own line leaves a
              # blank one behind when it expands to "", which is build-script text
              # and moves EVERY drv that goes through this wrap.
              for __unpin_c in ${nixpkgs.lib.concatMapStringsSep " " nixpkgs.lib.escapeShellArg compatLinks}; do
                for __unpin_s in "" ".exe" ".ape"; do
                  [ -f "$out/bin/${primary}$__unpin_s" ] || continue
                  [ -e "$out/bin/$__unpin_c$__unpin_s" ] \
                    || ln -s "${primary}$__unpin_s" "$out/bin/$__unpin_c$__unpin_s"
                done
              done''}
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
              '' else if base.unpinEmbedsAliases or false then ''
              # This base packed its own list during the build (lib.withAliases),
              # and that list cannot survive the wrap: strip rebuilds the copy
              # from its sections and drops the EOF ZIP, and where strip is a
              # no-op (stripCmd = ":") the stage below appends a SECOND ZIP whose
              # EOCD shadows the first. The harvest can't stand in for it either —
              # aliasesFromSymlinksIn deletes the very symlinks it read. Only the
              # PRISTINE base still has the names, so read them back.
              #
              # A bespoke windowsBuild fold is what needs this: its applet set is
              # its own (usbutils folds lsusb alone on mingw — no sigaction) and
              # nothing outside that build knows it.
              __unpin_al=""
              for __unpin_v in "${primary}" "${primary}.exe" "${primary}.ape"; do
                [ -f "${binOut}/bin/$__unpin_v" ] || continue
                # `|| true`: unzip exits 9 when the variant carries no container
                # at all, and the stdenv shell runs with pipefail.
                __unpin_al="$( { unzip -p "${binOut}/bin/$__unpin_v" unpin/aliases 2>/dev/null || true; } \
                  | tr '\n' ',' | sed 's/,*$//')"
                [ -n "$__unpin_al" ] && break
              done
              if [ -z "$__unpin_al" ]; then
              ${harvestAliasesSh}
              fi
              '' else ''
              __unpin_al=""
              ${harvestAliasesSh}
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

        # A package or program name as a C identifier component — every emitter
        # below builds symbols (`unpin__<pkg>__<prog>_main`) and per-program file
        # names out of it, so they must all spell it the same way.
        sanCSym = nixpkgs.lib.replaceStrings [ "." "-" "+" ] [ "_" "_" "_" ];
        spaceSep = nixpkgs.lib.concatStringsSep " ";

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
        #
        # `windows` adds the mingw command-line rewrite below. It is a parameter
        # rather than an unconditional `#ifdef _WIN32` block so the emitted C stays
        # byte-identical on every other target — the source text is part of the
        # derivation, so an unconditional block would rehash every multicall
        # package (and every mega) on every platform for a Windows-only fix. Cosmo
        # doesn't want it either: it never defines `_WIN32`, so the upstream argv
        # rebuilds this compensates for are not compiled into an APE.
        multicallTableDispatcherC = { name, defaultApplet ? null, windows ? false }:
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

            # Emitted only for mingw — see the `windows` note above.
            winCmdlineFixDecl = nixpkgs.lib.optionalString windows ''
        cat <<'CBODY'
#include <wchar.h>
#include <windows.h>
/* Applets that rebuild their own argv from the real Windows command line
   (CommandLineToArgvW, msvcrt's __wgetmainargs) throw away the argv the
   dispatcher handed them: they would see the selector we just consumed and
   report argv[0] as the .exe path. So rewrite the command line in place to what
   the applet should have been launched with — `<applet> <args...>`. That buffer
   IS what those rebuilds read: GetCommandLineW hands back the PEB's own copy.
   Its UNICODE_STRING.Length is left stale on purpose; every consumer here goes
   by the NUL, and updating it would mean reaching into ntdll's structs.

   Only a plain unquoted `--unpin-program=NAME` second token is rewritten. A
   quoted one is left alone: dispatch still works, the applet just sees the raw
   line as it does today. */
static void unpin_fix_cmdline(const char *sel) {
    wchar_t *cl = GetCommandLineW(), *p, *tok, *rest;
    size_t n, i;
    if (cl == NULL) return;
    /* argv[0] parses by its own rule: quoted through the closing quote, else up
       to the first blank — no escape processing either way. */
    p = cl;
    if (*p == L'"') {
        for (p++; *p != 0 && *p != L'"'; p++) { }
        if (*p != 0) p++;
    } else {
        for (; *p != 0 && *p != L' ' && *p != L'\t'; p++) { }
    }
    while (*p == L' ' || *p == L'\t') p++;
    tok = p;
    if (wcsncmp(tok, L"--unpin-program=", 16) != 0) return;
    for (rest = tok; *rest != 0 && *rest != L' ' && *rest != L'\t'; rest++) { }
    n = strlen(sel);
    /* The applet name displaces the whole .exe path, so it fits many times over;
       bail out rather than clobber the token we are about to read. */
    if (cl + n > tok) return;
    for (i = 0; i < n; i++) cl[i] = (wchar_t)(unsigned char)sel[i];
    memmove(cl + n, rest, (wcslen(rest) + 1) * sizeof(wchar_t));
}
CBODY
'';
            winCmdlineFixCall = nixpkgs.lib.optionalString windows
              "                unpin_fix_cmdline(sel);\n";
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
${winCmdlineFixDecl}        cat <<CBODY
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
${winCmdlineFixCall}                return a->fn(argc - 1, argv + 1, environ);
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
        # Add a `module` output carrying a self-describing multicall module: the
        # package's code with `main`→`unpin__<pkg>__<prog>_main` and every other
        # defined global namespaced, so N packages can be linked into one binary
        # without symbol collisions.
        #
        # The manifest (applets/depArchives/requires) is assembled by the caller
        # (mkStandaloneFlake's `multicall` arg, attached as
        # passthru.multicallModule); mkMegaMulticall links N modules into one
        # binary. A PRIVATE bundled lib (gnulib: `internalArchives`, callbacks
        # namespaced but own defs untouched so they stay dedupable) is
        # distinguished from a CLEAN external dep (`depArchives`, never touched,
        # deduped at mega-link). See docs/multicall.md.
        #
        # The adapter compiled every object as LLVM BITCODE, so a symbol rename
        # over the finished objects can't apply (llvm-objcopy refuses bitcode).
        # Per program:
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
          , coffObjs ? false        # windows: the sidecar's OBJ list can name a
                                    # real COFF object — a compiled resource
                                    # (pciutils' lspci-rsrc.o), which the ELF
                                    # `-r` fold rejects outright ("unknown file
                                    # type") where a mislabelled archive member
                                    # only warned. Feed the fold a bitcode-only
                                    # view of OBJ; the COFF ones still reach
                                    # module_native.a, since _unpin_collect keeps
                                    # getting the full list. Off elsewhere leaves
                                    # every other target's script identical.
          , wholeArchiveObjs ? false # windows: accept a program whose objects
                                    # arrive as a build-tree archive linked under
                                    # --whole-archive (how CMake links on
                                    # Windows-GNU), taking it whole. Off elsewhere
                                    # keeps every other target's script identical.
          , foldSharedArchives ? false # multi-program packages whose programs
                                    # share the same private static archives
                                    # (ffmpeg/ffprobe → libav*): fold the shared
                                    # archives ONCE instead of per-program. Opt-in;
                                    # off keeps the per-program path byte-identical.
          , machoAsm ? false        # darwin: feed the `-r` fold a BITCODE-ONLY copy
                                    # of the shared archives, taken whole.
                                    #
                                    # That fold runs the ELF `ld.lld`, which
                                    # cannot read the target's Mach-O objects and
                                    # skips them silently ("archive member 'x.o'
                                    # is neither ET_REL nor LLVM bitcode"). They
                                    # are rescued into the native sidecar, but
                                    # every reference they made is missing from
                                    # the link — so a BITCODE member that only the
                                    # asm needs is never demanded and lands in
                                    # neither output. ffmpeg's
                                    # `libavcodec/x86/constants.c` is exactly
                                    # that, and every `ff_pw_*`/`ff_pb_*` went
                                    # undefined at the mega link.
                                    #
                                    # Two things that do NOT work, both tried:
                                    # naming the missing symbols with `-u` (the
                                    # ELF driver and Mach-O disagree on the
                                    # leading underscore, so no one spelling
                                    # matches both sides), and whole-archiving the
                                    # archives as they are (that finally makes
                                    # lld LOAD the Mach-O members instead of
                                    # skipping them: `not an ELF file`, fatal).
                                    # Hence bitcode-only: no name has to match,
                                    # and no Mach-O ever reaches the ELF driver.
                                    # The extra members cost nothing in the end —
                                    # internalize + DCE drop whatever the entry
                                    # points do not reach.
                                    #
                                    # It also switches the two nm scrapes below to
                                    # Mach-O spelling, which differs twice over.
                                    # `llvm-nm` prints the leading underscore the
                                    # object file carries (`_ff_pw_1`) while LLVM
                                    # IR — and `-internalize-public-api-list` —
                                    # names it bare, so both scrapes are demangled.
                                    # And for an undefined Mach-O symbol nm emits
                                    # the NAME ALONE, with no `U` type column, so
                                    # the ELF `$1=="U"` filter silently yields an
                                    # empty list: the keeplist stayed at the bare
                                    # entry points and internalize made every
                                    # asm-referenced global local (`s` in nm) —
                                    # same undefined symbols as before the fix,
                                    # from a different cause. Read the archive with
                                    # `nm --undefined-only` before trusting either
                                    # spelling: the `multicall(shared): keeping …`
                                    # line below is the cheap proof it matched.
                                    #
                                    # NB: keep every addition to the emitted
                                    # script inside `optionalString machoAsm`,
                                    # SHELL COMMENTS INCLUDED — the script text is
                                    # what the drv hashes, so an explanatory line
                                    # in the `''` block rebuilds every ELF target.
                                    # Hence this note lives out here.
          }: drv:
          let
            entryOf = p: "unpin__${sanCSym package}__${sanCSym p.name}_main";
            # The two nm scrapes that build the asm-referenced keep-list, in ONE
            # place: the per-program path and the shared-archive path below both
            # need them, and Mach-O spells both sides differently in ways that
            # fail SILENTLY (see the `machoAsm` note in the argument list — no `U`
            # column on an undefined symbol, and a leading underscore the IR side
            # doesn't carry). A scrape fixed in one path and left narrow in the
            # other reintroduces exactly the bug the note describes. Byte-for-byte
            # the previous ELF text, so no non-darwin target moves.
            undefScrape =
              if machoAsm
              then "awk 'NF && $NF !~ /:$/ {print $NF}' | sed 's/^_//'"
              else "awk '$1==\"U\"{print $2}'";
            defScrape = "awk '$NF ~ /:$/ {next} {print $NF}'"
              + nixpkgs.lib.optionalString machoAsm " | sed 's/^_//'";
            # Read one program's capture sidecar into $__objs/$__arch. Both fold
            # paths need it identically; the LOCALA dedup matters because a gnulib
            # archive double-listed for circular refs folds to one — lld -r
            # resolves back-references without the repeat.
            readSidecar = p: ''
              __side="$UNPIN_LINK_DIR/${p.name}.link"
              [ -f "$__side" ] || { echo "multicallModuleHookLTO: no link sidecar for ${p.name} ($__side)" >&2; exit 1; }
              __objs=$(awk '$1=="OBJ"{print $2}' "$__side")
              __arch=$(awk '$1=="LOCALA"{print $2}' "$__side" | awk '!seen[$0]++')${
                nixpkgs.lib.optionalString wholeArchiveObjs ''

              __whole=$(awk '$1=="WHOLEA"{print $2}' "$__side" | awk '!seen[$0]++')
              # Take a --whole-archive input apart instead of handing it to the
              # `-r` link whole. It is the target's own objects, so every BITCODE
              # member has to ride in — but the same archive also carries members
              # the ELF `-r` cannot read at all: NASM's COFF objects (libjpeg) and
              # compiled Windows resources (flac's version.rc.res), which are a
              # hard "not an ELF file" under --whole-archive where a plain archive
              # only warned. The bitcode ones join $__objs here; the native ones
              # reach module_native.a through _unpin_collect, which already gets
              # $__whole. Magic bytes, not suffixes: `.obj` says nothing about
              # whether clang emitted bitcode or the assembler emitted COFF.
              if [ -n "$__whole" ]; then
                __wd="''${NIX_BUILD_TOP:-$TMPDIR}/.unpin-whole/${sanCSym p.name}"
                rm -rf "$__wd"; __wn=0
                for __wa in $__whole; do
                  __wn=$((__wn+1)); mkdir -p "$__wd/$__wn"
                  ( cd "$__wd/$__wn" && ${llvm} llvm-ar x "$__wa" ) || continue
                done
                for __wm in $(find "$__wd" -type f 2>/dev/null); do
                  [ "$(head -c2 "$__wm" 2>/dev/null)" = BC ] && __objs="$__objs
              $__wm"
                done
              fi''}${
                nixpkgs.lib.optionalString coffObjs ''

              # Bitcode-only view of OBJ for the `-r` fold (see coffObjs). The
              # full list still goes to _unpin_collect, so a COFF object is
              # rescued into module_native.a rather than lost.
              __objsBc=
              for __o in $__objs; do
                if [ "$(_unpin_natkind "$__o")" = bc ]; then __objsBc="$__objsBc
              $__o"; fi
              done''}
              [ -n "$__objs" ] ${nixpkgs.lib.optionalString wholeArchiveObjs ''|| [ -n "$__whole" ] ''}|| { echo "multicallModuleHookLTO: sidecar for ${p.name} has no objects" >&2; exit 1; }
            '';
            # What the `-r` fold reads. Same as $__objs everywhere but windows,
            # where the COFF members are filtered out above.
            foldObjs = if coffObjs then "$__objsBc" else "$__objs";
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
                linkBc = "multicall/link_${sanCSym p.name}.bc";
                infer = inferLinkInputs && (p.objs or null) == null;
                inferSetup = readSidecar p;
                linkLine =
                  if infer
                  then ''${llvm} ld.lld -r ${foldObjs} multicall/tramp_${sanCSym p.name}.bc $__arch \
                  --lto-emit-llvm -o ${linkBc}''
                  else ''${llvm} ld.lld -r ${spaceSep (p.objs or [ ])} multicall/tramp_${sanCSym p.name}.bc ${spaceSep internalArchives} \
                  --lto-emit-llvm -o ${linkBc}'';
                # SIMD/asm rescue: native ELF objects (NASM/yasm asm) can't live in
                # a .bc, so --lto-emit-llvm silently drops them and their symbols go
                # undefined at the mega-link. Carry them out-of-band in a per-module
                # `module_native.a` the mega links alongside module.bc, keeping SIMD
                # on without a per-package SIMD-off. _unpin_collect (in postBuild)
                # classifies inputs by magic and archives the native ones.
                natCollect =
                  if infer
                  then ''_unpin_collect "$module/lib/module_native.a" $__objs $__arch${nixpkgs.lib.optionalString wholeArchiveObjs " $__whole"}''
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
                # The trampoline calls `main`. If this program's objects don't
                # DEFINE one, `main` stays undefined in the module and binds at
                # the final fold link to the only `main` in sight — the
                # dispatcher's. The applet then re-enters the dispatcher, which
                # dispatches it again, until the stack dies. It is silent: the
                # binary links, installs, and only that one applet is broken.
                # (mtools on darwin stacked cppRenameMulticall under the module
                # fold, so `main` had already become `mkmanifest_main`; SIGSEGV
                # on both darwin arches, shipped until the applet sweep ran it.)
                # Undefined `main` is the exact static signal — 0 across every
                # healthy module measured, 1 on the broken one.
                mainGuard = ''
                  if ${llvm} nm --undefined-only ${linkBc} 2>/dev/null \
                       | awk '{print $NF}' | grep -qxE '_?main'; then
                    echo "multicallModuleHookLTO: '${p.name}' defines no main of its own." >&2
                    echo "  The entry trampoline would bind to the dispatcher's main and" >&2
                    echo "  recurse until the stack is exhausted. A build whose main was" >&2
                    echo "  already renamed by an earlier fold must not be folded again." >&2
                    exit 1
                  fi
                '';
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
                  '${entryOf p}' > multicall/tramp_${sanCSym p.name}.c
                $CC -flto -O2 -c multicall/tramp_${sanCSym p.name}.c -o multicall/tramp_${sanCSym p.name}.bc
                ${nixpkgs.lib.optionalString infer inferSetup}
                ${linkLine}
                ${mainGuard}
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
                    | ${undefScrape} | sort -u > multicall/nat_${sanCSym p.name}.u
                  # defined externals of the OWN OBJECTS only (skip the "file:"
                  # headers llvm-nm prints when handed several files).
                  ${llvm} llvm-nm --defined-only --extern-only ${progObjs} 2>/dev/null \
                    | ${defScrape} | sort -u > multicall/obj_${sanCSym p.name}.d
                  __extra=$(comm -12 multicall/nat_${sanCSym p.name}.u multicall/obj_${sanCSym p.name}.d)
                  for __s in $__extra; do keeplist="$keeplist,$__s"; done
                  [ -n "$__extra" ] && echo "multicall(${p.name}): keeping asm-referenced bitcode syms external:" $__extra >&2 || true
                fi
                ${stripStep}
                ${llvm} opt -passes=internalize -internalize-public-api-list="$keeplist" \
                  ${internalizeIn} -o multicall/mod_${sanCSym p.name}.bc
              '';

            # ── option A: shared-archive fold (foldSharedArchives, multi-prog) ──
            # ffmpeg/ffprobe share the ENTIRE libav* codebase. The per-program
            # path above folds those private archives into EACH program's module,
            # so a module-level inline-asm def with `.global` (libavcodec mlpdsp's
            # `ff_mlp_firorder_N`) lands in both modules; llvm-link concatenates
            # module-level asm verbatim (InternalizePass can't touch it) and the
            # mega-link's integrated assembler then rejects the redefinition. Fold
            # the shared archives ONCE instead:
            #   1. per program: `ld.lld -r` ONLY its own objs + trampoline (NOT the
            #      shared archives), then `opt -internalize` keeping just the entry
            #      — this localizes `main` and every own-object global so two
            #      programs' same-named statics (both `main`, cmdutils' globals)
            #      can't collide when combined; undefined refs into libav* stay
            #      undefined.
            #   2. `ld.lld -r` all per-program modules + the DEDUPED union of shared
            #      archives once. lld pulls each archive member on demand
            #      (first-def-wins) → libav*'s module-level asm appears exactly once.
            #   3. native SIMD members the bitcode link dropped → module_native.a
            #      (once), asm-referenced bitcode defs kept external, everything
            #      else internalized down to the per-program entries.
            # Safe only when the shared library never calls BACK into a program's
            # own objects by name (libav* doesn't — fftools registers callbacks by
            # pointer); no catalog shared-code package violates this.
            foldShared = foldSharedArchives && builtins.length programs > 1;
            entriesCsv = nixpkgs.lib.concatMapStringsSep "," entryOf programs;
            modsList = spaceSep (map (p: "multicall/mod_${sanCSym p.name}.bc") programs);
            perProgramShared = p:
              let
                entry = entryOf p;
                infer = inferLinkInputs && (p.objs or null) == null;
                partial = "multicall/partial_${sanCSym p.name}.bc";
                readInputs =
                  if infer then readSidecar p else
                    ''
                      __objs="${spaceSep (p.objs or [ ])}"
                      __arch="${spaceSep internalArchives}"
                    ''
                    # hand-listed objs are never COFF, but foldObjs below reads
                    # $__objsBc unconditionally once coffObjs is on.
                    + nixpkgs.lib.optionalString coffObjs ''
                      __objsBc="$__objs"
                    '';
              in
              ''
                printf 'extern int main(int,char**,char**);\nint %s(int c,char**v,char**e){return main(c,v,e);}\n' \
                  '${entry}' > multicall/tramp_${sanCSym p.name}.c
                $CC -flto -O2 -c multicall/tramp_${sanCSym p.name}.c -o multicall/tramp_${sanCSym p.name}.bc
                ${readInputs}
                for __a in $__arch; do echo "$__a" >> multicall/union.arch.raw; done
                ${llvm} ld.lld -r ${foldObjs} multicall/tramp_${sanCSym p.name}.bc \
                  --lto-emit-llvm -o ${partial}
                ${llvm} opt -passes=internalize -internalize-public-api-list='${entry}' \
                  ${partial} -o multicall/mod_${sanCSym p.name}.bc
                # rescue native asm from a program's OWN objects (none for ffmpeg;
                # general-safety for other shared-code packages)
                _unpin_collect "$module/lib/module_native.a" $__objs
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
              # Append every member of archive $2 whose kind is $3 to archive $1,
              # extracting INSTANCE BY INSTANCE (`llvm-ar xN <k>`) into uniquely
              # numbered files named `$4_<k>_<member>`. Needed because `llvm-ar x`
              # flattens members to their BASENAME and OVERWRITES same-basename
              # collisions: ffmpeg's libavcodec.a holds per-codec x86 objects
              # sharing `mc.o`/`deblock.o`/`idct.o`, so a flat extract silently
              # loses hevc's `mc.o` and `ff_hevc_put_bi_epel_*` goes undefined at
              # the mega-link. Both the native rescue and the darwin bitcode-only
              # copy split archives this way; one function so a fix to the member
              # bookkeeping can't land in only one of them.
              _unpin_split_members() { # $1=out.a $2=in.a $3=bc|native $4=prefix
                local __out="$1" __in="$2" __want="$3" __pfx="$4"
                local __td __k=0 __mem __safe __c __f __u
                __td=$(mktemp -d)
                cp "$__in" "$__td/in.a" || { rm -rf "$__td"; return 0; }
                ${llvm} llvm-ar t "$__td/in.a" > "$__td/members" 2>/dev/null \
                  || { rm -rf "$__td"; return 0; }
                mkdir -p "$__td/e" "$__td/seen"
                while IFS= read -r __mem; do
                  [ -n "$__mem" ] || continue
                  __safe=$(printf '%s' "$__mem" | tr -c 'A-Za-z0-9._-' '_')
                  __c=$(cat "$__td/seen/$__safe" 2>/dev/null || echo 0); __c=$((__c + 1))
                  printf '%s' "$__c" > "$__td/seen/$__safe"
                  rm -f "$__td"/e/*
                  ( cd "$__td/e" && ${llvm} llvm-ar xN "$__c" "$__td/in.a" "$__mem" ) 2>/dev/null || true
                  __f=$(ls "$__td/e" 2>/dev/null | head -1)
                  [ -n "$__f" ] || { __k=$((__k + 1)); continue; }
                  if [ "$(_unpin_natkind "$__td/e/$__f")" = "$__want" ]; then
                    __u="$__td/''${__pfx}_$(printf '%06d' $__k)_$__safe"
                    mv "$__td/e/$__f" "$__u"
                    ${llvm} llvm-ar qc "$__out" "$__u"
                  fi
                  __k=$((__k + 1))
                done < "$__td/members"
                rm -rf "$__td"
              }
              _unpin_collect() {
                __nat="$1"; shift
                for __i in "$@"; do
                  [ -e "$__i" ] || continue
                  case "$__i" in
                    *.a)
                      # Split a (possibly mixed) archive: archive only its NATIVE
                      # members; the bitcode members already rode into module.bc via
                      # the ld.lld -r link. Most archives have no repeated member
                      # name, so keep the fast flat extract for them (and
                      # byte-identical to the original path); when a name repeats,
                      # fall back to _unpin_split_members, which is why that
                      # function exists.
                      __td=$(mktemp -d)
                      cp "$__i" "$__td/in.a" || { rm -rf "$__td"; continue; }
                      ${llvm} llvm-ar t "$__td/in.a" > "$__td/members" 2>/dev/null || { rm -rf "$__td"; continue; }
                      if [ "$(wc -l < "$__td/members")" = "$(sort -u "$__td/members" | wc -l)" ]; then
                        mkdir -p "$__td/x"
                        ( cd "$__td/x" && ${llvm} llvm-ar x "$__td/in.a" ) || { rm -rf "$__td"; continue; }
                        for __m in "$__td"/x/*; do
                          [ -f "$__m" ] || continue
                          # NB: if/then (not `[ ] && cmd`) — under set -e a false test
                          # in `[ ] && cmd` aborts the whole postBuild silently.
                          if [ "$(_unpin_natkind "$__m")" = native ]; then
                            ${llvm} llvm-ar qc "$__nat" "$__m"
                          fi
                        done
                        rm -rf "$__td"
                      else
                        rm -rf "$__td"
                        _unpin_split_members "$__nat" "$__i" native n
                      fi
                      ;;
                    *)
                      if [ "$(_unpin_natkind "$__i")" = native ]; then
                        ${llvm} llvm-ar qc "$__nat" "$__i"
                      fi
                      ;;
                  esac
                done
              }
              ${if foldShared then ''
              : > multicall/union.arch.raw
              ${nixpkgs.lib.concatMapStringsSep "\n" perProgramShared programs}
              # fold all per-program modules + the DEDUPED shared archives ONCE, so
              # each shared archive member (and its module-level inline asm) is
              # pulled a single time. lld's on-demand archive semantics resolve the
              # per-program undefined libav* refs against these members.
              __union=$(sort -u multicall/union.arch.raw)${nixpkgs.lib.optionalString machoAsm ''

              __bcu=multicall/union_bc.a
              rm -f "$__bcu"
              for __a in $__union; do
                _unpin_split_members "$__bcu" "$__a" bc b
              done
              if [ -f "$__bcu" ]; then ${llvm} llvm-ar s "$__bcu"; else ${llvm} llvm-ar rc "$__bcu"; fi''}
              # native SIMD from the shared archives (once). BEFORE the bitcode
              # fold, because that fold needs to know what the natives reference.
              _unpin_collect "$module/lib/module_native.a" $__union
              if [ -f "$module/lib/module_native.a" ]; then
                ${llvm} llvm-ar s "$module/lib/module_native.a"
              else
                ${llvm} llvm-ar rc "$module/lib/module_native.a"
              fi
              # `ld.lld -r` pulls archive members ON DEMAND, and the only demand it
              # sees is from bitcode. A bitcode member whose sole consumers are the
              # NATIVE asm members — libavcodec/x86/constants.c defines ff_pd_1,
              # ff_pw_* … and every reference to them lives in the .asm objects,
              # which are rescued to module_native.a and are NOT part of this link —
              # is therefore never pulled. It ends up defined nowhere, so the
              # keep-list below cannot see it either, and the mega link fails with
              # `undefined symbol: ff_pd_1` referenced from module_native.a. Name
              # the natives' undefined symbols with `-u` so the members that define
              # them get pulled in. A name nothing in the union defines just stays
              # undefined, which is what `-r` wants anyway.
              __upull=
              if [ -n "$(${llvm} llvm-ar t "$module/lib/module_native.a" 2>/dev/null)" ]; then
                ${llvm} llvm-nm --undefined-only "$module/lib/module_native.a" 2>/dev/null \
                  | ${undefScrape} | sort -u > multicall/nat_all.u
                # if/then, never `[ ] && cmd`: a false test as the loop body's last
                # command makes the loop exit 1 and `set -e` kills postBuild.
                while IFS= read -r __s; do
                  if [ -n "$__s" ]; then __upull="$__upull -u $__s"; fi
                done < multicall/nat_all.u
              fi
              ${llvm} ld.lld -r ${modsList} ${nixpkgs.lib.optionalString machoAsm "--whole-archive $__bcu --no-whole-archive "}$__union \
                $__upull --lto-emit-llvm -o multicall/link_all.bc
              # keep the per-program entries external; also keep any bitcode symbol
              # a rescued asm object references — the shared archives are folded IN
              # here (not external depArchives), so their asm-referenced defs must
              # survive internalize or they go undefined at the mega native link.
              keeplist='${entriesCsv}'
              if [ -s multicall/nat_all.u ]; then
                ${llvm} llvm-nm --defined-only --extern-only multicall/link_all.bc 2>/dev/null \
                  | ${defScrape} | sort -u > multicall/def_all.d
                __extra=$(comm -12 multicall/nat_all.u multicall/def_all.d)
                for __s in $__extra; do keeplist="$keeplist,$__s"; done
                [ -n "$__extra" ] && echo "multicall(shared): keeping asm-referenced bitcode syms external:" $__extra >&2 || true
              fi
              ${llvm} opt -passes=internalize -internalize-public-api-list="$keeplist" \
                multicall/link_all.bc -o "$module/lib/module.bc"
              '' else ''
              ${nixpkgs.lib.concatMapStringsSep "\n" perProgram programs}
              # always materialize module_native.a (empty archive if no asm) so the
              # manifest path is stable and the mega-link can reference it
              # unconditionally; an empty archive links to nothing.
              if [ -f "$module/lib/module_native.a" ]; then
                ${llvm} llvm-ar s "$module/lib/module_native.a"
              else
                ${llvm} llvm-ar rc "$module/lib/module_native.a"
              fi
              ${llvm} llvm-link ${spaceSep (map (p: "multicall/mod_${sanCSym p.name}.bc") programs)} \
                -o "$module/lib/module.bc"
              ''}
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
            pfx = "unpin__${sanCSym package}__";
            entry = "${pfx}${sanCSym program}_main";
          in
          drv.overrideAttrs (old: {
            outputs = (old.outputs or [ "out" ]) ++ [ "module" ];
            postBuild = (old.postBuild or "") + ''
              set -e
              mkdir -p multicall "$module/objs" "$module/applet" "$module/gnulib"
              progobjs="${spaceSep programObjs}"
              ag="${spaceSep appletArchives}"; gg="${spaceSep gnulibArchives}"
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
              } > multicall/${sanCSym package}.redef
              rename_into() { # $1=destdir ; reads a file list on stdin
                local n=0 a d
                while read -r a; do
                  [ -n "$a" ] || continue
                  d="$1/$(printf '%03d' $n)-$(basename "$a")"
                  cp "$a" "$d"; chmod +w "$d"
                  $OBJCOPY --redefine-syms=multicall/${sanCSym package}.redef "$d"; n=$((n+1))
                done
              }
              n=0
              for o in $progobjs; do
                $OBJCOPY --redefine-syms=multicall/${sanCSym package}.redef "$o" \
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
          , isTargetDarwin ? false  # Mach-O: strip the leading `_` off every nm name
          , isCosmo ? false         # Windows APE: no applet symlinks; explicit alias list
          , isWindows ? false       # mingw PE: bin/<pkg>.exe, embedded aliases (no symlinks)
          }:
          let
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
              (map (p: "${p.name}\t${sanCSym p.name}") programs)
              ++ (map (a: "${a.name}\t${sanCSym a.target}") aliases);

            # Phase A: discover defined globals per program (canonical names,
            # before any recompile) and emit the rename header.
            renameHeader = p: ''
              {
                echo "/* multicall rename header: ${p.name} */"
                echo "#define main ${sanCSym p.name}_main"
                $NM --defined-only -g ${nixpkgs.lib.concatStringsSep " " p.objs} 2>/dev/null \
                  | awk -v t="${sanCSym p.name}" -v strip=${if isTargetDarwin then "1" else "0"} '
                      # Same symbol classes as the bitcode fold and the cosmo hook:
                      # `i` (indirect/ifunc) and `u` (unique global) are defined
                      # globals too, and a class left out here leaks that symbol
                      # across the folded programs under its original name.
                      $2 ~ /^[TBDRWVCSiu]$/ {
                        sym = $3
                        if (strip && sym ~ /^_/) sym = substr(sym, 2)
                        if (sym ~ /^[A-Za-z_][A-Za-z0-9_]*$/ && sym != "main" && !seen[sym]++)
                          print "#define " sym " " t "__" sym
                      }'
              } > multicall/${sanCSym p.name}.rename.h
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
                  NIX_CFLAGS_COMPILE="$_orig_NIX_CFLAGS_COMPILE -include $PWD/multicall/${sanCSym p.name}.rename.h"
                mkdir -p multicall/obj_${sanCSym p.name}
                ${nixpkgs.lib.concatMapStringsSep "\n      "
                    (o: ''cp "${o}" "multicall/obj_${sanCSym p.name}/$(echo '${o}' | tr / _)"'')
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

            # Every dispatch name the binary answers to EXCEPT its own: on native
            # these become the in-store symlinks withAliases harvests, on windows
            # the alias list it embeds directly. The primary is dropped because it
            # IS the binary — announcing it makes `unpin install` resolve the alias
            # to the slot the primary just took and report "`<name>` is provided by
            # more than one binary in this package", which is false. mtools is the
            # one package where that can bite (its canonical name is also an
            # applet); the harvest path and mkMegaMulticall both filter it too.
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
              ${multicallTableDispatcherC { name = primary; defaultApplet = null; windows = isWindows; }}
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
                 then { aliases = binSymlinks; }
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
        #   moduleFormat  "bitcode" (-flto emitter) | "cosmo-elf" (cosmocc)
        #   moduleArchive  store path to module.bc / the renamed ELF objs
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
            anyBitcode = builtins.any (m: m.moduleFormat == "bitcode") modules;
            # Cosmo modules (multicallModuleHookCosmo) link NATIVELY through
            # cosmocc + apelink — no lld, no adapter — so they pick the backend
            # themselves. Every other module set goes through the engine.
            cosmoMode = builtins.any (m: m.moduleFormat == "cosmo-elf") modules;
            anyCxx = builtins.any (m: m.requires.cxx or false) modules;
            anyGroup = builtins.any (m: m.requires.group or false) modules;
            moduleArchives = map (m: m.moduleArchive) modules;
            # Native (asm/SIMD) sidecars rescued by the bitcode hook — one per
            # bitcode module, linked in the back-ref group alongside depArchives so
            # the asm code the bitcode module references resolves. Absent on the
            # cosmo path (it carries native objects directly).
            nativeArchives = nixpkgs.lib.filter (x: x != null)
              (map (m: m.nativeArchive or null) modules);
            depArchives = nixpkgs.lib.unique
              (nixpkgs.lib.concatMap (m: m.depArchives) modules);
            # Auto-derived external dep dirs. The builder globs <dir>/lib/*.a and
            # skips libc-family archives (the engine/cosmo provides libc; a deep
            # closure surfacing musl's libc.a must not clash with it).
            depInputDirs = nixpkgs.lib.unique
              (nixpkgs.lib.concatMap (m: m.depInputDirs or [ ]) modules);
            # Capture-sidecar dirs, one per bitcode module (see winSidecarPrelude).
            # Cosmo manifests carry none.
            linksDirs = nixpkgs.lib.unique
              (nixpkgs.lib.filter (x: x != null) (map (m: m.linksDir or null) modules));
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
            # `libresolv.a` is in the set for the SPLIT-libc case only. darwin has no
            # split — libSystem is monolithic — and its libresolv.a is the standalone
            # BIND resolver (`res_9_ninit`/`res_9_nquery`/`res_9_dn_expand`) that
            # glib's gthreadedresolver.c calls, exactly the libxcrypt-on-musl shape
            # described above. Skipping it there is unconditionally wrong, so drop it
            # from the set on darwin rather than making each darwin fold rescue it by
            # name via keepAutoArchives. Spliced mid-list to keep the non-darwin
            # ordering byte-identical (this list is emitted into the `case` pattern,
            # so reordering it rehashes every linux mega).
            libcSplitArchives = [
              "libc.a" "libm.a" "libpthread.a" "librt.a" "libdl.a"
            ] ++ nixpkgs.lib.optional (!isDarwinHost) "libresolv.a" ++ [
              "libutil.a" "libcrypt.a" "libxnet.a" "libnsl.a"
            ];
            effectiveSkipArchives =
              nixpkgs.lib.subtractLists keptAutoArchives libcSplitArchives
              # A PE import lib matches the `*.a` glob too, and linking one puts a
              # DLL dependency in a binary whose whole point is to be one file:
              # winpthreads ships libwinpthread.dll.a beside libwinpthread.a, and
              # the .exe that picked it up did not start on Windows at all — no
              # output, no message, exit 53. The static twin sits in the same dir
              # and this same glob finds it. nix-lib already deletes *.dll.a from
              # the outputs it builds itself; this one rides in on a nixpkgs input
              # (windows.pthreads), which it does not touch. Windows-only so the
              # shell text — and every other target's drv — stays put.
              ++ nixpkgs.lib.optional (pkgs.stdenv.hostPlatform.isWindows or false) "*.dll.a";
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
            # The import stubs only the fold link can be missing (see winForceLibs).
            # Last on the line, after every object, so static resolution works.
            # Empty off windows — it must not add a token, or every native mega
            # re-hashes.
            winForceFlags = nixpkgs.lib.optionalString isWin
              (" " + nixpkgs.lib.concatMapStringsSep " " (l: "-l${l}") winForceLibs);
            # The rest of the import stubs, recovered from the capture sidecars
            # instead of hand-listed.
            #
            # The shim already writes one STOREA row per store archive a program's
            # link line named — INCLUDING the sysroot import stubs, because the
            # cc-wrapper puts `-L<implibs>/lib` in cc-ldflags, so `-ldwrite`
            # resolves to a real file and gets recorded. The fold then reads OBJ,
            # LOCALA and WHOLEA out of that sidecar and DROPS the STOREA rows —
            # which is why `winForceLibs` exists at all: it is a hand-maintained
            # re-derivation of a list the build already wrote down. Every entry in
            # it was found by linking, reading `undefined symbol: X` and looking up
            # which DLL exports X — cairo's AlphaBlend, gio's DnsQuery_UTF8,
            # pangowin32's DWriteCreateFactory, each one a full rebuild of the
            # windows chain away, because touching winForceLibs re-hashes the
            # cc-wrapper through winImportLibs' guard.
            #
            # So take them off the sidecar. Only rows under the implib dir: a
            # STOREA row for a real dep (zlib, harfbuzz) already rides in through
            # depArchives/autodeps, where the libc-split skip list applies, and
            # nothing here should bypass that. Import stubs have no such hazard —
            # they define nothing but thunks, a linker pulls a member only for a
            # symbol still undefined, and an unreferenced one costs a directory
            # read.
            #
            # `winForceLibs` stays: it is force-linked on the line whether or not
            # any package named it, which is the belt to this suspenders, and
            # pruning it would re-hash the whole windows chain to prove a negative.
            winSidecarPrelude = nixpkgs.lib.optionalString (isWin && linksDirs != [ ]) ''
              winimplibs=()
              # if/then, never `[ ] && cmd`: a false test as the loop body's last
              # command makes the loop exit 1 and `set -e` kills buildPhase.
              while IFS= read -r a; do
                if [ -n "$a" ]; then winimplibs+=("$a"); fi
              done < <(cat ${nixpkgs.lib.concatMapStringsSep " " (d: "${d}/*.link") linksDirs} 2>/dev/null \
                        | awk '$1=="STOREA" && $2 ~ /-unpin-win-implibs-/ {print $2}' \
                        | awk '!seen[$0]++')
              echo "multicall(mega): ''${#winimplibs[@]} import stubs off the capture sidecars"
            '';
            # Same gate as the prelude — the flag must never name an array the
            # prelude did not declare.
            winSidecarFlags = nixpkgs.lib.optionalString (isWin && linksDirs != [ ])
              " \"\${winimplibs[@]}\"";
            # darwin (Mach-O) mega: ld64 rejects the GNU flags the ELF/PE path
            # uses — `--start-group`/`--end-group` (ld64 resolves back-refs
            # multi-pass, no group needed) and `-s` (ld64's spelling is `-x`). So
            # darwin drops the groups and swaps `-Wl,-s`→`-Wl,-x`. No-op off darwin.
            isDarwinHost = pkgs.stdenv.hostPlatform.isDarwin or false;
            stripLinkFlag = if isDarwinHost then "-Wl,-x" else "-Wl,-s";
            # Bitcode libc: musl's `malloc` is a WEAK alias of the strong
            # `__libc_malloc`. NATIVE objects in the link — the asm/SIMD sidecars
            # the bitcode hook rescues — reference `malloc` invisibly to the
            # `-flto` link's LTO, so it internalizes/drops the weak `malloc` from
            # the codegen'd libc → `undefined symbol: malloc` at final resolution.
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
            # The mega's link backend, as DATA. There are two (unpin-llvm below,
            # cosmocc after it) and they differ on a fixed set of axes, so name the
            # axes once instead of writing one builder per backend — a third one is
            # then a record entry, not a new builder. Selected by module format —
            # the producer side already tags every manifest (`moduleFormat`).
            #
            #   stdenv    which stdenv performs the link
            #   prelude   shell emitted before autoDepsPrelude
            #   linkLine  the link itself (comments included, verbatim)
            #   postLink  shell between the link and `runHook postBuild`
            #   install   the installPhase body, before `runHook postInstall`
            #
            # Each fragment is spliced with no added whitespace, so its own
            # trailing newline is load-bearing; keep the `''` blocks' relative
            # indentation as-is.
            engines = {
              "unpin-llvm" = {
                stdenv = unpinAdapterStdenv {
                  inherit pkgs toolchain target;
                  # Cross mega: with a cross pkgs the link runs through the cross
                  # stdenv (lld cross-links per-arch modules); only the sysroot sanity
                  # run is gated off. toolchain stays build-host (clang -target emits
                  # the host arch).
                  native = pkgs.stdenv.buildPlatform.system == pkgs.stdenv.hostPlatform.system;
                  cxx = anyCxx;
                  lto = anyBitcode;
                };
                prelude = winSidecarPrelude;
                # `bitcodeLibcForce` carries a trailing space and pastes straight
                # onto `-o` — keep the concatenation exact.
                linkLine = ''
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
                    ${darwinFrameworkFlags}${winForceFlags}${winSidecarFlags}
                '';
                postLink = "";
                install = ''
                  install -m755 ${binFile} "$out/bin/${binFile}"
                '';
              };
              "cosmocc" = {
                stdenv = cosmo;
                prelude = ''
                  # nullglob-safe per-bucket group: a bucket dir with no archives
                  # (e.g. bash has no applet archives) contributes nothing.
                  grp() { local f had=0 out="-Wl,--start-group"
                          for f in "$1"/*.a; do [ -e "$f" ] || continue; had=1; out="$out $f"; done
                          [ "$had" = 1 ] && printf -- '%s -Wl,--end-group ' "$out"; }
                '';
                linkLine = ''
                  # explicit depArchives + auto-derived (autodeps) in one group
                  alldeps=( ${nixpkgs.lib.concatStringsSep " " depArchives} "''${autodeps[@]}" )
                  depgrp=()
                  [ "''${#alldeps[@]}" -gt 0 ] && depgrp=( -Wl,--start-group "''${alldeps[@]}" -Wl,--end-group )
                  ${face} -O2 -o ${name} multicall/dispatcher.c \
                    ${cosmoModuleLink} \
                    "''${depgrp[@]}"
                '';
                postLink = ''
                  ${cosmoApelink} -o ${name}.ape ${name}
                  ${cosmoApelink} -V ${cosmoVbits} -o ${name}.exe ${name}
                '';
                install = ''
                  install -m755 ${name}.ape "$out/bin/${name}.ape"
                  install -m755 ${name}.exe "$out/bin/${name}.exe"
                '';
              };
            };
            engineRec = engines.${if cosmoMode then "cosmocc" else "unpin-llvm"};

            # Cosmo helpers, referenced by the "cosmocc" engine record above.
            cosmo = cosmoStdenv pkgs;
            cosmoApelink = "${cosmo.cosmocc}/bin/apelink";
            cosmoVbits = toString cosmo.platformBits.windows;
            cosmoModuleLink = nixpkgs.lib.concatMapStringsSep " \\\n          "
              (m: ''"${m.moduleObjs}"/*.o $(grp "${m.appletDir}") $(grp "${m.gnulibDir}")'')
              modules;

            # ONE builder for every backend: the skeleton (dispatcher table,
            # autodeps, install layout) is backend-independent; engineRec supplies
            # the link.
            megaDrv = engineRec.stdenv.mkDerivation {
              inherit name;
              dontUnpack = true;
              dontConfigure = true;
              buildPhase = ''
                runHook preBuild
                mkdir -p multicall
                printf '${nixpkgs.lib.concatStringsSep "\\n" appletLines}\n' > multicall/applets.list
                ${multicallTableDispatcherC { inherit name; defaultApplet = defaultSan; windows = isWin && !cosmoMode; }}
                ${engineRec.prelude}${autoDepsPrelude}
                ${engineRec.linkLine}${engineRec.postLink}runHook postBuild
              '';
              installPhase = ''
                runHook preInstall
                mkdir -p "$out/bin"
                ${engineRec.install}runHook postInstall
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
          } megaDrv;

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

        # THE engine adapter stdenv for a (pkgs, toolchain): every engine build
        # in the catalog comes through here, so a standalone package and the same
        # package folded into the catalog mega get a byte-identical stdenv.
        # lto/captureLinks are unconditional for that reason — a dep must not
        # differ by who is consuming it. `lto = false` is the SAME stdenv
        # otherwise; the deps that must opt out (libjpeg-turbo, x264) take this
        # door rather than a second copy of the arguments.
        engineStdenv = { pkgs, toolchain, lto ? true }: unpinAdapterStdenv {
          inherit pkgs toolchain lto;
          target = pkgs.pkgsStatic.stdenv.hostPlatform.config;
          native = pkgs.stdenv.buildPlatform.system == pkgs.stdenv.hostPlatform.system;
          cxx = true;
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
            engStdenv = engineStdenv { inherit pkgs toolchain; };
            # libjpeg-turbo: the engine's full -flto MISCOMPILES it — CTest #121
            # bmpsizetest hangs (its 65500² whole-image path allocs ~12GB) → OOM
            # (thin-LTO instead segfaults lld; only no-LTO is clean, byte-for-byte
            # the stock gcc behaviour). Build the SHARED libjpeg with lto=false so
            # every codec consumer (aom/avif/heif/jxl/chafa/ffmpeg/jpeg-tools/
            # openjpeg/jbig2/poppler…) gets the correct build. This lives here, not
            # in native-overlay/libjpeg-turbo.nix, because the lto=false engine
            # stdenv needs the BASE pkgs the adapter wraps — an autoWire `apply`
            # only sees the post-swap set. See that overlay file for the rationale.
            engStdenvNoLto = engineStdenv { inherit pkgs toolchain; lto = false; };
            # libjpeg-turbo 3.1.x's `simdcoverage` helper references jsimd_can_*
            # entry points its RVV port lacks (jsimd_can_encode_mcu_AC_refine_
            # prepare), so on riscv64 the build aborts on -Wimplicit-function-
            # declaration. Drop the (unused, lib-untouched) helper. Same fix as
            # native-overlay/libjpeg-turbo.nix, but as a drv→drv transform so it
            # composes with the lto=false `.override` below (a `.override` drops a
            # lower overlay's postPatch, so the drop must ride ON the swapped drv)
            # AND with the pristine librsvg scope, which never sees withLibjpegNoLto.
            dropJpegSimdcov = drv: drv.overrideAttrs (oa: {
              postPatch = (oa.postPatch or "") + ''
                substituteInPlace simd/CMakeLists.txt \
                  --replace-fail "add_executable(simdcoverage simdcoverage.c)" "" \
                  --replace-fail "target_link_libraries(simdcoverage jpeg-static)" ""
              '';
            });
            # Darwin: ONE iconv per closure. macOS ships two, and they do NOT
            # agree on symbol names — Apple's libiconv-113 exports plain
            # `iconv`/`iconv_open`/`iconv_close`, while GNU libiconv renames its
            # own to `libiconv*` in the header (`#define iconv libiconv`) so it
            # can coexist with the system copy. Either is fine; MIXING them is
            # not, and a mix stays invisible until the final link of whoever
            # pulls the dep in.
            #
            # `darwinIconvFixed` swaps Apple → GNU on the TOP-LEVEL drv only, so
            # a package linked GNU's archive while its deps — built earlier,
            # still on Apple's header — had emitted plain `iconv*`: `ld64.lld:
            # undefined symbol: iconv_open, referenced by encoding.c` (libxml2,
            # hit by ffmpeg). Not an ffmpeg bug; ffmpeg is just the first darwin
            # engine package with an iconv-using dep.
            #
            # Swapping the scope's `libiconv` attribute instead is impossible:
            # nixpkgs' darwin bootstrap asserts `libiconv == darwin.libiconv`.
            # So converge the other way — hand the GNU header to the packages
            # that actually call iconv, exactly as `unpinLibarchive` does for
            # libarchive. The list is closed and MEASURED, not guessed: an
            # llvm-nm sweep of all 948 static darwin archives in the store for an
            # undefined plain `iconv*` finds these six and nothing else.
            #
            # Converging the ENGINE world only. The pristine set librsvg builds
            # its private pango/cairo/glib chain from stays on Apple's iconv and
            # is internally consistent there; mixing, not Apple, was the bug.
            #
            # `real` is captured OUTSIDE the extend: GNU libiconv's own closure
            # reaches `libiconv` again (gettext), so reading it off `prev` would
            # close a cycle through an attribute being defined — eval recurses.
            darwinIconvConverge = scope:
              if !(scope.stdenv.hostPlatform.isDarwin or false)
                 || !(scope ? libiconvReal)
              then scope
              else
                let
                  l = nixpkgs.lib;
                  real = scope.libiconvReal;
                  # Both spellings carry pname "libiconv", so drop every one and
                  # add GNU back — same idiom as darwinIconvFixed's `noIconv`.
                  noIconv = l.filter (x: (x.pname or "") != "libiconv");
                  # Propagated, not a plain buildInput: a consumer that links
                  # e.g. libxml2.a resolves `libiconv*` out of ITS own link, so
                  # the -L has to travel with the dep.
                  swap = d: d.overrideAttrs (o: {
                    buildInputs = noIconv (o.buildInputs or [ ]);
                    propagatedBuildInputs =
                      noIconv (o.propagatedBuildInputs or [ ]) ++ [ real ];
                  });
                  # gettext is deliberately NOT here, though the sweep flags its
                  # libintl/libgettextpo/libtextstyle. Two reasons, both hard:
                  # GNU libiconv depends on gettext, so giving gettext libiconv
                  # closes a dependency cycle; and gettext is also a NATIVE build
                  # tool (msgfmt), where the swap hands a bootstrap-clang link
                  # the engine's LLVM-bitcode archive — `ld: ignoring file
                  # libiconv.a … unknown-unsupported file format`, then
                  # `_iconv_ostream_create` undefined. If libintl's plain
                  # `iconv*` ever reaches a real link, it needs a host-splice-only
                  # fix, not this list.
                  users = [ "libxml2" "glib" "libass" "boost" "zvbi" ];
                in
                scope.extend (_final: prev:
                  # ONLY in this scope's OWN fixpoint. An overlay propagates to
                  # `buildPackages`, and libxml2 (xmllint) and gettext (msgfmt)
                  # are libraries AND native build tools — handing a
                  # bootstrap-clang link the engine's LLVM-bitcode libiconv.a
                  # gets it ignored as "unknown-unsupported file format" and
                  # then `configure: error: libiconv not found`. The test is cc
                  # IDENTITY, not "is the engine": `real` is only linkable by
                  # the toolchain it was built with, so the rule is "apply where
                  # the compiler still matches the one `real` came from" — which
                  # is also what makes this correct for the pristine scope.
                  if (prev.stdenv.cc.name or "") != (scope.stdenv.cc.name or "?")
                  then { }
                  else
                    l.genAttrs (l.filter (n: prev ? ${n}) users)
                      (n: swap prev.${n}));
            # Is this scope the engine set? The guard is LOAD-BEARING, not a
            # tidiness check: these overlays also reach `buildPackages`, and an
            # unguarded swap forces the engine onto the BUILD host, which trips
            # `isFromBootstrapFiles`. `isMusl` selects the linux target host;
            # darwin has no musl split, but its pkgsStatic host is `isStatic`
            # (buildPackages/bootstrap are not) — hence both, said once here
            # instead of at each layer below.
            isEngineScope = prev:
              prev.stdenv.hostPlatform.isMusl || prev.stdenv.hostPlatform.isStatic;
            # Every set-wide layer below has the same shape: a gate on the scope,
            # a curated list of attribute names, and a `pkgs: drv -> drv` fix.
            # `prev ? ${n}` skips names a given set lacks, and a false gate leaves
            # the identity overlay — byte-identical where the layer doesn't apply.
            engineLayer = { gate, names, fix }: scope:
              scope.extend (_final: prev:
                if !(gate prev) then { }
                else nixpkgs.lib.genAttrs
                  (nixpkgs.lib.filter (n: prev ? ${n}) names)
                  (n: fix prev prev.${n}));
            # Base (pre-swap) gnu static-musl stdenv — pins pkg-config off the
            # engine (below). Captured from the pristine pkgs so the pin is an
            # absolute value the pkgsStatic splice can't re-resolve to engStdenv.
            baseStaticStdenv = pkgs.pkgsStatic.stdenv;
            engineBashAttrs = [ "bash" "bashInteractive" "bashNonInteractive" ];
            withEngineStdenv = pkgs.pkgsStatic.extend
              (_final: prev:
                if isEngineScope prev
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
                  # x264 is assembly-dominated (its whole reason for being), so LTO
                  # buys it nothing — and its `base.o` forces the LLVM module flag
                  # `override-stack-alignment=64` (AVX needs a 64-byte-aligned
                  # stack), which COLLIDES with a bitcode consumer's LTO module
                  # (`i32 16`) at the final link: `ld.lld: error: linking module
                  # flags 'override-stack-alignment': IDs have conflicting values`
                  # (hit by ffmpeg). Build it with the lto=false engine stdenv →
                  # native ELF, a sidecar carrying no LLVM module flags (same as
                  # libjpeg below). Pin here, BEFORE the autoWired STRINGS
                  # overrideAttrs (native-overlay/x264.nix), so the `.override`
                  # doesn't discard that fix. Gated on `prev ? x264`.
                }
                // nixpkgs.lib.optionalAttrs (prev ? x264)
                  { x264 = prev.x264.override { stdenv = engStdenvNoLto; }; }
                else { });
            withBashFix = engineLayer {
              gate = isEngineScope;
              names = engineBashAttrs;
              fix = unpinBashBuildFix;
            } withEngineStdenv;
            # Each autoWired fix carries its OWN gate — a dep that only breaks
            # under `pkgsStatic` declares `autoWire = "static"`, the rest musl.
            withDepFixes = builtins.foldl'
              (acc: name:
                let entry = autoWiredFixes.${name}; in
                engineLayer {
                  gate = prev:
                    if entry.autoWire == "static"
                    then (prev.stdenv.hostPlatform.isStatic or false)
                    else prev.stdenv.hostPlatform.isMusl;
                  names = [ name ];
                  # The fix rebuilds the attr from the scope, so the current drv
                  # is not an input.
                  fix = prev: _drv: entry.apply prev;
                } acc)
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
              "harfbuzz"
              "libvmaf"
            ];
            withMesonBuildCcFix = engineLayer {
              gate = prev:
                prev.stdenv.hostPlatform.isAarch32
                && prev.stdenv.buildPlatform != prev.stdenv.hostPlatform;
              names = mesonBuildCcPkgs;
              fix = withMesonBuildCC;
            } withDepFixes;
            # Swap libjpeg-turbo to the lto=false engine stdenv set-wide (see
            # engStdenvNoLto above). nixpkgs' `libjpeg` aliases `libjpeg_turbo`;
            # override the concrete attr and re-point the alias so consumers of
            # either name get the no-LTO build. Gated isMusl||isStatic like the
            # other set-wide engine fixes; identity on non-engine hosts.
            withLibjpegNoLto = withMesonBuildCcFix.extend
              (_final: prev:
                if isEngineScope prev && (prev ? libjpeg_turbo || prev ? libjpeg)
                then
                  let lj0 = (prev.libjpeg_turbo or prev.libjpeg).override { stdenv = engStdenvNoLto; };
                      # riscv64: also drop the broken RVV simdcoverage helper (rides
                      # ON the swapped drv so the `.override` above doesn't discard it).
                      lj = if prev.stdenv.hostPlatform.isRiscV or false
                           then dropJpegSimdcov lj0 else lj0;
                  in { libjpeg = lj; }
                     // nixpkgs.lib.optionalAttrs (prev ? libjpeg_turbo) { libjpeg_turbo = lj; }
                else { });
            # librsvg is a RUST package, and rustc can never be an engine derivation:
            # the engine cc-wrapper carries `libc = null` (libc comes from the
            # sysroot, not the wrapper — load-bearing), while rustc's configureFlags
            # interpolate `musl-root=${cc.libc}`, so the set-wide stdenv swap makes
            # every spliced rustc stage coerce null → eval dies. Rather than fight
            # rustc's cross-splice (many stages, each re-resolving rustc-unwrapped
            # through the swapped set), build librsvg from the PRISTINE pkgsStatic —
            # exactly how it built before the engine migration. Its native `.a` (the
            # rust crate's C-ABI staticlib) is folded by the engine link as a native
            # sidecar, like SIMD asm. The C deps it SHARES with the top package
            # (pango/cairo/glib…) still resolve to the engine set at the final link
            # (pkg-config --static dedups each `-l` to one archive), so the pristine
            # copies only serve librsvg's own build. The fixes are baked in here
            # (`nativeFixes.librsvg` against the pristine scope) so the consumer uses
            # the injected attr directly — re-applying them against the engine scope
            # would splice engine libunwind/pango into a pristine build. Gated like
            # the other set-wide engine fixes; identity where librsvg is absent.
            withRustDeps = withLibjpegNoLto.extend
              (_final: prev:
                if isEngineScope prev && prev ? librsvg
                then {
                  # librsvg pulls libjpeg_turbo transitively (gdk-pixbuf/libtiff/
                  # libwebp) from this PRISTINE scope, which never passes through
                  # withLibjpegNoLto — so the riscv64 simdcoverage drop must be
                  # applied here too, or librsvg's own build fails. Assign to both
                  # attrs from the concrete drv (going via the `libjpeg` alias would
                  # cycle through nixpkgs' `libjpeg = libjpeg_turbo`).
                  librsvg =
                    let
                      # …and darwin: librsvg drags its OWN pango/cairo/glib/
                      # gdk-pixbuf chain out of this pristine scope, so every
                      # darwin structural fix the consuming flake applies to the
                      # engine scope has to be applied here too — the pristine
                      # copies never pass through it. Without them the chain dies
                      # one dep at a time: glib/pango "Subsystem not defined" (meson
                      # can't autodetect it in cross mode), cairo's
                      # ipc_rmid_deferred_release darwin lookup, graphite2's
                      # unguarded `nolib_test($<TARGET_SONAME_FILE:graphite2>)` on
                      # a static lib, dav1d's cpu_family='arm64' asm dispatch. Same
                      # set `rsvg-convert` uses to build this chain standalone.
                      # Darwin-gated, so every other host keeps its hash.
                      # NOT iconv-converged, deliberately. This chain is not
                      # private to librsvg's own build the way the note above
                      # suggests: librsvg is a Rust `staticlib`, so librsvg-2.a
                      # BUNDLES the objects of every native library it linked —
                      # `librsvg-2.a(gconvert.c.o)`, `(libxml2_la-encoding.o)` —
                      # and those reference iconv in the CONSUMER's link. It
                      # stays on Apple's spelling, internally consistent, and
                      # `darwinIconvFixed` puts Apple's archive on the darwin
                      # link next to GNU's so both spellings resolve. Converging
                      # this scope instead is not available: `libiconvReal` is
                      # reachable from the very attributes being overridden, so
                      # the extend closes a cycle (infinite recursion at eval).
                      base = (
                        if pkgs.pkgsStatic.stdenv.hostPlatform.isDarwin or false
                        then pkgs.pkgsStatic.extend (_f: p: {
                          glib       = nativeFixes.glib       p;
                          graphite2  = nativeFixes.graphite2  p;
                          fontconfig = nativeFixes.fontconfig p;
                          pango      = nativeFixes.pango      p;
                          cairo      = nativeFixes.cairo      p;
                          dav1d      = nativeFixes.dav1d      p;
                        })
                        # Everywhere else only graphite2 is needed, and for a
                        # different reason than darwin's: CMake's libtool emulation
                        # writes a `libgraphite2.la` naming a `libgraphite2.so` the
                        # static build never produced. Only a LIBTOOL consumer of
                        # this injected chain trips on it — libtool rewrites
                        # `-lgraphite2` into that absolute path and the link dies
                        # (chafa; ffmpeg's own build system never reads a `.la`).
                        else pkgs.pkgsStatic.extend
                          (_f: p: { graphite2 = nativeFixes.graphite2 p; }));
                    in
                    nativeFixes.librsvg (
                      if pkgs.pkgsStatic.stdenv.hostPlatform.isRiscV or false
                      then base.extend (_f: p:
                        let lj = dropJpegSimdcov p.libjpeg_turbo;
                        in { libjpeg = lj; libjpeg_turbo = lj; })
                      else base);
                }
                else { });
            withDarwinIconvDeps = darwinIconvConverge withRustDeps;
          in
          withDarwinIconvDeps;

        # The Windows (mingw + cosmo) root nixpkgs and its engine-swapped variant,
        # lifted to lib-level thunks. They are PACKAGE-INDEPENDENT (no pkgsAttr, no
        # per-recipe input), so a catalog mega that refolds N recipes through ONE
        # lib instance shares this single evaluation across the whole fold — the
        # windows counterpart of the enginePkgsStatic sharing, but free (no
        # injection knob needed; the shared thunk IS the sharing). mkStandaloneFlake
        # just references these instead of rebuilding them inline → byte-identical.
        windowsNixpkgs =
          let
            basePkgs = nixpkgs.legacyPackages.${"x86_64-linux"};
            nixpkgsPatched = basePkgs.applyPatches {
              name = "nixpkgs-cosmo";
              src = nixpkgs.outPath;
              patches = [ ./cosmo-lib-systems.patch ];
            };
            cosmoOverlay = import ./cosmo { lib = nixpkgs.lib // lib; };
          in
          extra: import nixpkgsPatched ({
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
          } // extra);
        windowsPkgsShared = windowsNixpkgs { };
        # The mingw cross set the ENGINE links through. Identical to
        # `windowsPkgsShared.pkgsCross.mingwW64` — same triple, same `libc`
        # declaration — except that rust is told the truth about the C toolchain.
        #
        # rust is the only consumer that hardcodes a link spec per target, and
        # `x86_64-pc-windows-gnu`'s is a gcc/msvcrt one: `-lgcc_s -lmsvcrt -lgcc`.
        # The engine has no libgcc at all (compiler-rt + libunwind), so rustc's own
        # `std` fails to link, which is where the ffmpeg windows chain stopped.
        # `*-pc-windows-gnullvm` is the target rust maintains for exactly this
        # shape (UCRT + clang/lld/compiler-rt/libunwind, tier 2 since 1.79); its
        # late_link_args are `-lmingw32 -lmingwex -lmsvcrt -lkernel32 -luser32`,
        # all of which the engine's sysroot resolves.
        #
        # `libc` stays "msvcrt" on purpose. It is a declaration nixpkgs uses to
        # build ITS mingw-w64, not a description of what the engine links (which
        # is UCRT, and has been all along); changing it here would rebuild the
        # pristine windows set for no gain. Spelled out rather than taken from
        # `lib.systems.examples` so the two attrs that matter are visible.
        windowsGnullvmCross = windowsNixpkgs {
          crossSystem = {
            config = "x86_64-w64-mingw32";
            libc = "msvcrt";
            rust.rustcTarget = "x86_64-pc-windows-gnullvm";
          };
        };
        # Engine adapter for the mingw cross host (bitcode). Built from the ORIGINAL
        # un-swapped cross set so it never sees the overlay below — no recursion.
        windowsEngineStdenvShared = windowsEngineStdenvSharedFor true;
        # Same stdenv with LTO off, for the deps that must opt out. Mirrors the
        # `engineStdenv { lto = false; }` door on the pkgsStatic side — see the
        # x264 pin below for the one case that needs it here.
        windowsEngineStdenvSharedNoLto = windowsEngineStdenvSharedFor false;
        windowsEngineStdenvSharedFor = lto:
          let mc = windowsGnullvmCross;
          in unpinAdapterStdenv {
            pkgs = mc;
            hostPkgs = mc;
            target = mc.stdenv.hostPlatform.config;
            native = false;
            cxx = true;
            inherit lto;
            captureLinks = true;
          };
        # windowsPkgsShared with `pkgsCross.mingwW64` replaced by the gnullvm cross
        # set above, its stdenv swapped to the engine adapter (set-level, guarded on
        # isMinGW so the glibc build host is untouched). Only the ENGINE windows
        # scope moves: the non-engine route goes through `mingwStaticCross pkgs`,
        # i.e. the package's own stock `pkgsCross.mingwW64`, still windows-gnu.
        windowsEnginePkgsShared = windowsPkgsShared.extend (_final: prev: {
          pkgsCross = prev.pkgsCross // {
            mingwW64 = windowsGnullvmCross.extend (_f: p:
              if p.stdenv.hostPlatform.isMinGW or false
              then {
                stdenv = windowsEngineStdenvShared;
                # winpthreads is built by the windows set's own `crossThreadsStdenv`,
                # which the swap above does not reach — so it stays a gcc/msvcrt
                # build. Its libwinpthread.a then calls the msvcrt-era `_setjmp`,
                # while the engine's CRT resolves setjmp to `__intrinsic_setjmpex`:
                # the fold link fails outright, and taking the .dll.a instead only
                # trades that for a DLL the .exe cannot carry. Rebuild it in-scope
                # so both sides agree on one CRT.
                #
                # It has to be overrideScope, not `.override { stdenv = … }` on the
                # attribute: `windows.*` is SPLICED in a cross set, so an override
                # there is consumed and then discarded — same drvPath out, silently.
                windows = p.windows.overrideScope (_wf: _wp: {
                  crossThreadsStdenv = windowsEngineStdenvShared;
                  # mcfgthreads rides on that same crossThreadsStdenv upstream
                  # (`callPackage ./mcfgthreads { stdenv = self.crossThreadsStdenv; }`),
                  # but must NOT follow it into the engine: it is gcc's own thread
                  # runtime (`--enable-threads=mcf`), here only because the mingw gcc
                  # propagates it, and nothing links it under libc++. Hand it the
                  # stdenv it had — the override is then bit-identical to upstream,
                  # so it substitutes instead of building.
                  #
                  # This is no longer load-bearing for the LINK: its DLL is built
                  # `-shared -nostdlib`, which the engine's mingw front used to
                  # override (appending crt2.o + libmingw32.a regardless, so
                  # mainCRTStartup dragged in `main` and the link died on an
                  # undefined WinMain). The front honours -nostdlib now. Kept
                  # because the reason above stands on its own.
                  mcfgthreads = _wp.mcfgthreads.override { stdenv = _wp.crossThreadsStdenv; };
                });
              }
              // nixpkgs.lib.optionalAttrs
                ((p.stdenv.hostPlatform.isMinGW or false) && p ? x264)
                # Same pin the pkgsStatic engine scope already carries, for the
                # same reason and the same symptom: x264's `base.o` forces the
                # LLVM module flag `override-stack-alignment=64`, which collides
                # with a bitcode consumer's `i32 16` at the final LTO link (`ld.lld:
                # error: linking module flags 'override-stack-alignment'`) — hit by
                # ffmpeg on both sides. LTO buys assembly-dominated x264 nothing.
                #
                # Worth noting beyond x264: this scope applies NONE of the other
                # per-package escapes its pkgsStatic sibling does (libjpeg-turbo's
                # lto=false, the pkg-config-unwrapped and bash pins). Each is a
                # latent windows bug, reachable as soon as a windows target links
                # the dep in question.
                #
                # The stdenv handed over must be the STATIC-LIBRARIES one, spelled
                # exactly as `mingwStaticCross` spells it. That overlay is appended
                # AFTER this scope and swaps `stdenv` set-wide — which never reaches
                # an attribute that already pins its own, so a bare
                # `windowsEngineStdenvSharedNoLto` here silently loses static-ness
                # and x264 installs `libx264.dll.a` + `-DX264_API_IMPORTS`
                # ("ERROR: x264 not found using pkg-config").
                {
                  x264 = p.x264.override {
                    stdenv =
                      let b = p.stdenvAdapters.makeStaticLibraries
                                windowsEngineStdenvSharedNoLto;
                      in b // { hostPlatform = b.hostPlatform // { isStatic = true; }; };
                  };
                }
              else { });
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
          , own_software ? false
          # Embed the package's own man pages into the binary via `withMan`
          # (as `unpin/man/*` ZIP entries), so `unpin man <pkg>` works offline with
          # no companion asset. Default-on across the catalog: packages with no
          # man (codec libs, coreutils/busybox) skip gracefully. Set false to
          # opt a package out.
          , embedMan ? true
          # Dead-store-ref scrub patterns for unpinEmbedWrap, native AND windows,
          # for packages that DON'T carry an engine `multicall` attr (single-binary or
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
            # The signature above throws on an unknown option — it has no `...`.
            # One level down there was no such promise: every nested set is read
            # with `x.y or default`, so `keepAutoArchive` is silently `[ ]` and the
            # build comes out green and wrong. Not hypothetical — nixpkgs retired
            # `allowBroken` for `problems.handlers` and the dead knob sat in a
            # recipe until it took the whole darwin matrix with it. Pure eval,
            # forced on the returned outputs, so it holds for every target.
            knownOpts = {
              optimize       = [ "lto" "opt" "ssp" "gc" ];
              multicall      = [ "programs" "darwinPrograms" "defaultProgram"
                                 "depArchives" "internalArchives" "keepAutoArchives"
                                 "inferLinkInputs" "foldSharedArchives"
                                 "removeReferences" "requires" "runtimeDataRoot"
                                 "windows" ];
              multicallCosmo = [ "program" "programObjs" "aliases" "appletArchives"
                                 "gnulibArchives" "depArchives" "requires" ];
              requires       = [ "cxx" "group" "frameworks" ];
              program        = [ "name" "objs" "aliases" "buildDir" "noHelp"
                                 "supportedTarget" ];
              runtimeEmbed   = [ "native" "windows" ];
            };
            unknownOpts =
              let
                chk = what: kn: set:
                  map (k: "  ${what}.${k} — known: ${nixpkgs.lib.concatStringsSep ", " kn}")
                    (nixpkgs.lib.subtractLists kn (builtins.attrNames set));
                progs = what: ps: nixpkgs.lib.concatMap
                  (p: chk "${what}.programs[\"${p.name or "?"}\"]" knownOpts.program p) ps;
              in
              chk "optimize" knownOpts.optimize optimize
              ++ chk "runtimeEmbed" knownOpts.runtimeEmbed
                   (if runtimeEmbed == null then { } else runtimeEmbed)
              ++ nixpkgs.lib.optionals (multicall != null) (
                   chk "multicall" knownOpts.multicall multicall
                ++ chk "multicall.requires" knownOpts.requires (multicall.requires or { })
                ++ progs "multicall" (multicall.programs or [ ]))
              ++ nixpkgs.lib.optionals (multicallCosmo != null) (
                   chk "multicallCosmo" knownOpts.multicallCosmo multicallCosmo
                ++ chk "multicallCosmo.requires" knownOpts.requires
                     (multicallCosmo.requires or { }));
            checkOpts = v:
              if unknownOpts == [ ] then v
              else throw ''
                ${name}: unknown option(s) in a nested option set —
                ${nixpkgs.lib.concatStringsSep "\n" unknownOpts}
              '';
            runtimeEmbedNative = if runtimeEmbed == null then null else runtimeEmbed.native or null;
            runtimeEmbedWindows = if runtimeEmbed == null then null else runtimeEmbed.windows or null;
            optimize_ = { lto = false; opt = null; ssp = true; gc = true; } // optimize;
            inherit (optimize_) lto opt ssp gc;
            ltoOpt = if opt == null then "-O2" else opt;
            # Plain nixpkgs import. Darwin dep fixes are NOT wired here as
            # `overlays` — an overlay on the nixpkgs IMPORT joins the
            # stdenv-bootstrap fixpoint and re-hashes the whole darwin base closure
            # (uncached → full rebuild). A leaf-wrapper fix goes there instead (the
            # ncurses <sys/ttydev.h> fix rides inside embedFallbackTerminfoOnly).
            importNixpkgs = system:
              if sharedPkgs != null then sharedPkgs else import nixpkgs { inherit system; };
            # LTO/GC overlays apply on Linux only; darwin/cross fall back to stock
            # pkgs. LTO subsumes gc (lto wins when both set).
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

            # Pin the caller-supplied meta fields; unset ones keep whatever
            # strippedOrJoined carried from upstream. meta isn't hashed, so this
            # never rebuilds. ONE entry point, applied once per artifact — a
            # per-field wrapper invites an artifact that pins some and not others
            # (the windows binary went a release without `description`).
            withMetaPins = drv:
              let pins = nixpkgs.lib.filterAttrs (_: v: v != null)
                { inherit license description; };
              in if pins == { } then drv
                 else drv // { meta = (drv.meta or { }) // pins; };

            defaultRawBuild = nativeFixes.${pkgsAttr} or (pkgs: pkgs.pkgsStatic.${pkgsAttr});
            # Does this host build on the engine? Linux (native or cross — one
            # LLVM toolchain cross-emits every target via `clang -target`, no
            # qemu) and a NATIVE darwin host; both ride the stdenv swap on
            # `pkgsStatic`. Asked by the build itself and again by the module
            # fold, in sibling scopes — one definition so the two can't drift.
            # Takes the PLATFORM, not a `pkgs`: the CI manifest below answers the
            # same question for targets it never instantiates a nixpkgs for.
            isEngineHost = platform: engine == "unpin-llvm"
              && (platform.isLinux || platform.isDarwin);
            # A `multicall` option may be written as a plain value or as a
            # `pkgs:` function, so a target resolves store paths in its own scope.
            inScope = pkgs: v: if builtins.isFunction v then v pkgs else v;
            # A program may be built on some targets only — binutils' gold/dwp have
            # no RISC-V backend (gold's configure.tgt omits it; gold is frozen,
            # superseded by lld), so binutils' own configure skips them on a riscv64
            # host and no `ld-new`/`dwp` link sidecar exists there. `supportedTarget`
            # (target `hostPlatform` → bool) drops such a program. It filters every
            # consumer of a program list — module hook, manifest applets, dispatcher
            # — so the fold matches exactly what upstream built, with no
            # missing-sidecar hard-error and no dangling dispatcher entry. Purely
            # eval-time (no IFD): the arch is a target-platform property, so
            # evaluating the flake never forces a build.
            supportedOn = platform: nixpkgs.lib.filter
              (p: (p.supportedTarget or (_: true)) platform);
            appletsOf = nixpkgs.lib.concatMap
              (p:
                let entry = "unpin__${sanCSym name}__${sanCSym p.name}_main"; in
                [{ name = p.name; inherit entry; }]
                ++ map (al: { name = al; inherit entry; }) (p.aliases or [ ]));
            # The bitcode manifest a mega folds. The native/darwin fold and the
            # mingw one differ only in which build carries the `module`, which
            # programs it folded, and which scope resolves a `pkgs:` option — so it
            # is written once: two copies let an option declared on `multicall`
            # reach one target and silently skip the other.
            bitcodeManifest = { drv, programs, pkgs }: {
              package = name;
              # ONE module.bc, with internalArchives already folded in.
              moduleFormat = "bitcode";
              moduleArchive = "${drv.module}/lib/module.bc";
              # Native (asm/SIMD) objects the bitcode link dropped, rescued into a
              # sidecar the mega-link adds alongside module.bc. Always present,
              # possibly empty.
              nativeArchive = "${drv.module}/lib/module_native.a";
              # The capture sidecars themselves. The mega reads the STOREA rows to
              # recover the Win32 import stubs each program's own link line named
              # — see winSidecarPrelude.
              linksDir = "${drv.module}/links";
              # Verbatim store paths: a passthru reference, NOT linked into the
              # shipped binary.
              depArchives = inScope pkgs (multicall.depArchives or [ ]);
              # Auto-derived external dep DIRS (pure store paths, no IFD); the mega
              # builder globs <dir>/lib/*.a at build time. `depArchives` stays as an
              # additive override for archives not in the closure.
              depInputDirs = multicallExternalDepDirs drv;
              applets = appletsOf programs;
              requires = { cxx = false; group = true; } // (multicall.requires or { });
              # Basenames to rescue from the auto-derive's libc-split skip list
              # (e.g. "libcrypt.a" for a package that folds libxcrypt). Empty by
              # default — only libxcrypt-consuming folds (shadow) set it.
              keepAutoArchives = multicall.keepAutoArchives or [ ];
              # Man source for the mega to MERGE: the built drv's man-bearing output
              # (split `man`, else out). null when this build ships no man; the
              # merge skips nulls.
              manRoot = if embedMan then "${drv.man or drv}" else null;
              # Runtime-data source for the mega to MERGE (file's magic.mgc). null
              # when the package ships none.
              runtimeDataRoot = inScope pkgs (multicall.runtimeDataRoot or null);
              # Name-substring patterns whose store refs are DEAD baked paths to
              # scrub from the shipped binary. Empty by default → no scrub, drv
              # byte-identical.
              removeReferences = multicall.removeReferences or [ ];
            };
            rawBuild = pkgs:
              let
                useEngine = isEngineHost pkgs.stdenv.hostPlatform;
                # SET-LEVEL stdenv swap so the top package AND its whole link
                # closure compile on the engine (all-deps-bitcode; a shallow `//`
                # would leave deps gcc ELF). Which scopes the swap may touch is
                # `isEngineScope`, next to the layers it gates.
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
                # multicall MODULE opt-in. The hook adds a `module` output by
                # post-processing the objects the build already compiled (no
                # recompile), riding the same builder as the shipped binary.
                # Where it applies is `wantModule` below.
                #
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
                mcPrograms = supportedOn pkgs.stdenv.hostPlatform mcProgramsRaw;
                # The module is BITCODE, so it exists exactly where the engine
                # compiled the objects — `isEngineHost`. There is no per-package
                # darwin opt-out: a darwin build that genuinely ships fewer
                # applets narrows the list with `darwinPrograms` above, which
                # keeps the fold and fixes the cause.
                wantModule = multicall != null && isEngineHost pkgs.stdenv.hostPlatform;
                rawHooked =
                  if wantModule
                  then multicallModuleHookLTO
                    {
                      package = name;
                      programs = mcPrograms;
                      internalArchives = multicall.internalArchives or [ ];
                      inferLinkInputs = multicall.inferLinkInputs or true;
                      foldSharedArchives = multicall.foldSharedArchives or false;
                      machoAsm = pkgs.stdenv.hostPlatform.isDarwin or false;
                      llvm = "${tc pkgs.stdenv.buildPlatform.system}/bin/llvm";
                    }
                    (rawBuild pkgs)
                  else rawBuild pkgs;
                # iconv: Apple libiconv-113's STATIC build fails through the engine
                # (cross: meson/static-modules.gperf; native: atf self-test
                # miscompiles). Drop Apple libiconv, append GNU libiconvReal (clean
                # static .a) built with the engine stdenv. Harmless for non-iconv
                # packages.
                #
                # …plus a tiny compat archive so the OTHER spelling resolves too.
                # Not everything on a darwin link speaks `libiconv*`: librsvg is
                # a Rust `staticlib`, so librsvg-2.a BUNDLES the objects of its
                # own PRISTINE chain — glib's `gconvert.c.o`, libxml2's
                # `encoding.o` — and those were compiled against Apple's header,
                # so they call plain `iconv`/`iconv_open`/`iconv_close` (exactly
                # those three, nothing else) and go undefined here.
                #
                # Three forwarding functions, not a second libiconv. Linking
                # Apple's archive next to GNU's is the obvious move and does not
                # work: both files are named `libiconv.a`, so `-liconv` picks one
                # and only one; naming Apple's by absolute path then collides on
                # `__libiconv_version`, the single symbol GNU did not rename, and
                # it cannot be renamed away because llvm-objcopy refuses Apple's
                # Mach-O members ("not recognized as a valid object file"). It
                # would also mean shipping two charset engines and two sets of
                # conversion tables in one binary. Forwarding keeps ONE
                # implementation; `iconv_t` is an opaque pointer on both sides
                # and every handle is now created AND consumed by GNU, so the
                # spellings can never disagree about what a handle means.
                #
                # An archive, not a bare `.o`: a plain object is always pulled in,
                # which would define plain `iconv*` in every darwin binary. This
                # way the linker takes it only where something asks.
                darwinIconvFixed = drv:
                  if engine == "unpin-llvm" && pkgs.stdenv.hostPlatform.isDarwin
                  then
                    let
                      noIconv = nixpkgs.lib.filter (x: (x.pname or "") != "libiconv");
                    in
                    let
                      # GNU libiconv, carrying Apple's spellings as forwarding
                      # wrappers INSIDE its own archive.
                      #
                      # macOS has two iconv ABIs: Apple's exports `iconv`/
                      # `iconv_open`/`iconv_close`, GNU's renames them to
                      # `libiconv*` via `#define` in its header. Both archives are
                      # named `libiconv.a` and they share exactly one symbol,
                      # `_libiconv_version`. The engine converges darwin on GNU
                      # (see darwinIconvConverge), but objects built against Apple
                      # headers still reach the link — librsvg is a Rust
                      # `staticlib`, so librsvg-2.a BUNDLES its pristine deps'
                      # objects, and those call plain `iconv*`.
                      #
                      # The wrappers must live in the ARCHIVE, not in NIX_LDFLAGS.
                      # A mega-multicall link auto-derives its inputs by globbing
                      # `lib/*.a` across the whole dep closure, which is broader
                      # than any single link line: it picks up Apple's libiconv.a
                      # from packages that never converged (qrencode, …). With the
                      # wrappers merely alongside, `iconv_open` is undefined when
                      # the mega links, ld pulls Apple's member to satisfy it, that
                      # member drags in `_libiconv_version`, and it collides with
                      # GNU's — `duplicate symbol`. Defining the wrappers in the
                      # archive that already answers `libiconv*` means nothing ever
                      # demands Apple's member, so it is never pulled and the two
                      # archives coexist untouched. It also spares every consumer
                      # the flag.
                      iconvCompat =
                        (pkgs.pkgsStatic.libiconvReal.override {
                          stdenv = engineStdenv {
                            inherit pkgs;
                            toolchain = tc pkgs.stdenv.buildPlatform.system;
                          };
                        }).overrideAttrs (o: {
                          postInstall = (o.postInstall or "") + ''
                            cat > compat.c <<'EOF'
                            #include <stddef.h>
                            typedef void *iconv_t;
                            /* Declared by hand: including <iconv.h> would #define
                               these names right back to the ones defined below. */
                            extern iconv_t libiconv_open(const char *, const char *);
                            extern size_t libiconv(iconv_t, char **, size_t *, char **, size_t *);
                            extern int libiconv_close(iconv_t);
                            iconv_t iconv_open(const char *t, const char *f)
                            { return libiconv_open(t, f); }
                            size_t iconv(iconv_t cd, char **in, size_t *inl, char **out, size_t *outl)
                            { return libiconv(cd, in, inl, out, outl); }
                            int iconv_close(iconv_t cd) { return libiconv_close(cd); }
                            EOF
                            $CC -c compat.c -o unpin_iconv_compat.o
                            ${unpinToolchain pkgs.stdenv.buildPlatform.system}/bin/llvm \
                              llvm-ar r $out/lib/libiconv.a unpin_iconv_compat.o
                            ${unpinToolchain pkgs.stdenv.buildPlatform.system}/bin/llvm \
                              llvm-ar s $out/lib/libiconv.a
                          '';
                        });
                    in
                    drv.overrideAttrs (old: {
                      # gnulib tools carry libiconv in propagatedBuildInputs too —
                      # filter BOTH or Apple libiconv survives.
                      buildInputs = (noIconv (old.buildInputs or [ ])) ++ [ iconvCompat ];
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
                # The aliases the shipped binary advertises to `unpin install`.
                # Declared ONCE, in `multicall.programs` (already platform-filtered
                # into mcPrograms above) — declaring them a second time inside
                # `build` does not reach the binary, since this wrap repacks over
                # whatever that produced.
                #
                # No `multicall` means no declared list (busybox ships 396 upstream
                # symlinks and names none of them), and those keep the wrap's own
                # symlink harvest. Where a list exists it is the better source, not
                # merely the tidier one: coreutils installs a `stdbuf` symlink the
                # harvest embeds, but stdbuf works by LD_PRELOADing libstdbuf.so
                # and cannot function in a static single binary — `programs` omits
                # it deliberately.
                declaredAliases = nixpkgs.lib.filter (a: a != binName)
                  (nixpkgs.lib.concatMap (p: [ p.name ] ++ (p.aliases or [ ])) mcPrograms);
                nativeEmbedOpts = { primary = binName; man = embedMan; removeReferences = removeReferences ++ (if multicall == null then [ ] else multicall.removeReferences or [ ]); }
                  // nixpkgs.lib.optionalAttrs (binName != name) { compatLinks = [ name ]; }
                  // nixpkgs.lib.optionalAttrs (declaredAliases != [ ]) { aliases = declaredAliases; }
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
                # `defaultProgram` runs on a bare invocation. Left unset it is
                # binName, which resolves to null — the dispatcher lists — unless
                # the binary is itself one of the programs. That fallback IS the
                # naming rule; declaring the option is the exception.
                selfFold = wantModule && builtins.length mcPrograms > 1;
                selfFoldDefault =
                  let
                    declared = multicall.defaultProgram or null;
                    appletNames = map (a: a.name) multicallManifest.applets;
                    dp = if declared != null then declared else binName;
                  in
                  # A declared name that is no program is a typo; silently listing
                  # would ship the wrong bare behaviour. mkMegaMulticall already
                  # throws on the same mistake — this closes the standalone half.
                  if declared != null && !builtins.elem declared appletNames then
                    throw ''
                      ${name}: multicall.defaultProgram "${declared}" is not one of its programs (${builtins.concatStringsSep ", " appletNames}).
                    ''
                  else if builtins.elem dp appletNames then dp else null;
                selfFolded = mkMegaMulticall {
                  inherit pkgs name;
                  modules = [ multicallManifest ];
                  defaultApplet = selfFoldDefault;
                };
                shipped =
                  if useEmbedWrap then unpinEmbedWrap pkgs nativeEmbedOpts base
                  else if selfFold then strippedOrJoined pkgs name selfFolded
                  else strippedOrJoined pkgs name legacyMaybeMan;
                result = withMetaPins shipped;
                multicallManifest = bitcodeManifest {
                  drv = moduleSource;
                  programs = mcPrograms;
                  inherit pkgs;
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
            # Every catalog package that used to carry a bespoke mingw fold is on
            # this path now; what remains off it are the four cosmo folds (which
            # multicallCosmo already excludes) and usbutils, whose fold rewrites
            # meson.build to emit ONE executable — declaring two programs there
            # would announce an applet that does not exist.
            wantWindowsModule =
              engine == "unpin-llvm" && multicall != null && (multicall.windows or false)
              && multicallCosmo == null && windowsEnabled;
            # Lifted to lib-level thunks (windowsEnginePkgsShared, built on
            # windowsEngineStdenvShared) so a catalog mega's refolds share one
            # evaluation. The per-package gate (wantWindowsModule) stays here; the
            # heavy engine-swapped set is the shared thunk. Byte-identical.
            windowsEnginePkgs =
              if !wantWindowsModule then windowsPkgs else windowsEnginePkgsShared;
            # The programs the mingw fold builds — `multicall.programs` filtered
            # against the PE host, not the native one `mcPrograms` uses.
            windowsPrograms = supportedOn
              windowsPkgs.pkgsCross.mingwW64.stdenv.hostPlatform multicall.programs;
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
                  programs = windowsPrograms;
                  internalArchives = multicall.internalArchives or [ ];
                  inferLinkInputs = multicall.inferLinkInputs or true;
                  foldSharedArchives = multicall.foldSharedArchives or false;
                  llvm = "${unpinToolchain windowsPkgs.stdenv.buildPlatform.system}/bin/llvm";
                  # mingw API is __declspec(dllexport); strip so internalize folds
                  # the module to one external (see hook's stripStep).
                  stripDllexport = true;
                  # CMake links a Windows-GNU target from an `objects.a` of its own
                  # objects under --whole-archive, so the sidecar carries no OBJ at
                  # all (srt). Autotools/meson are unaffected — they still list .o.
                  wholeArchiveObjs = true;
                  # A compiled .rc resource lands in OBJ as a real COFF object
                  # (pciutils' lspci-rsrc.o) — hard error for the ELF `-r` fold.
                  coffObjs = true;
                }
                (windowsRawBuild pkgs)
              else windowsRawBuild pkgs;
            # Man source for the windows/cosmo binary. The cross build ships no
            # man, so the version-locked x86_64-linux nixpkgs graft is borrowed ONLY
            # when the cross build ships none of its own (the rare help2man package);
            # an explicit `winManRoot` wins outright. `winManGraft` is null for
            # custom-named multicall packages (no matching nixpkgs attr).
            winManNixpkgs = nixpkgs.legacyPackages.x86_64-linux;
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
            # Windows counterpart of `declaredAliases`. Where nix-lib itself did
            # the fold it knows the whole applet set: a cosmo build dispatches the
            # table `multicallCosmo` declares (which can differ from the linux one
            # — coreutils drops `hostid`, cosmo has no gethostid), and
            # `wantWindowsModule` folds `windowsPrograms`. Neither is mcPrograms,
            # which is filtered against the NATIVE host.
            #
            # Otherwise the binary comes from the flake's own `windowsBuild`, whose
            # applet set is NOT `multicall.programs` — usbutils folds lsusb alone
            # (usbhid-dump needs sigaction), less folds nothing. Two rules keep the
            # shipped list honest there:
            #
            #   1. only the PRIMARY program's aliases. An alias is a second name
            #      for the same binary, not a second applet, so it holds whatever
            #      that build folded: mawk is mawk, hence `awk`. Announcing another
            #      program's name is what ships a link that falls through to the
            #      default applet; announcing the primary's own aliases cannot.
            #   2. only when that build packed NO list of its own. Where it did,
            #      it is the better source — unzip really folds `funzip`, which no
            #      declaration of the primary's aliases can say. unpinEmbedWrap
            #      recovers that list from the base; saying anything here would
            #      just append a second, poorer copy.
            windowsDeclaredAliases =
              let names =
                if multicallCosmo != null
                then [ multicallCosmo.program ] ++ (multicallCosmo.aliases or [ ])
                else if wantWindowsModule
                then nixpkgs.lib.concatMap (p: [ p.name ] ++ (p.aliases or [ ])) windowsPrograms
                else if multicall != null && !(windowsBase.unpinEmbedsAliases or false)
                then nixpkgs.lib.concatMap (p: p.aliases or [ ])
                  (nixpkgs.lib.filter (p: p.name == binName) multicall.programs)
                else [ ];
              in nixpkgs.lib.filter (a: a != binName) names;
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
              # The windows wrap used to take no scrub list at all, so a dead
              # baked path was cleaned on linux/darwin and kept on windows —
              # measured on xvnc, whose .exe held a live ref to its own pristine
              # base via the xserver's $out/lib/xorg/protocol.txt while every
              # other target was ref-clean. Same list, same opt-in: [] leaves the
              # drv byte-identical.
              removeReferences = removeReferences
                ++ (if multicall == null then [ ] else multicall.removeReferences or [ ]);
            } // nixpkgs.lib.optionalAttrs (binName != name) { compatLinks = [ name ]; }
              // nixpkgs.lib.optionalAttrs (windowsDeclaredAliases != [ ]) { aliases = windowsDeclaredAliases; }
              // (if runtimeEmbedWindows != null then runtimeEmbedWindows windowsPkgs windowsForEmbed else { });
            # `windowsDeclaredAliases` announces every windowsPrograms name when
            # `wantWindowsModule`, which is only honest if nix-lib actually folds
            # them. This cannot fire as written — it restates windowsSelfFold —
            # and is kept only as a tripwire on that COUPLING: narrow the fold
            # condition later and the build stops here instead of silently
            # shipping links that fall through to the default applet. It is NOT
            # the check that catches a missing dispatcher; nothing in eval can
            # see that. That one is a smoke that invokes each announced applet.
            windowsAnnounceOk =
              !wantWindowsModule || builtins.length windowsPrograms < 2 || windowsSelfFold;
            windowsPkg0 = withMetaPins (
              if !windowsAnnounceOk then
                throw ''
                  ${name}: the windows artifact announces ${toString (builtins.length windowsPrograms)} programs but nothing folds them.
                ''
              # Un-migrated flake that still embeds in its own windowsBuild keeps the
              # legacy in-build embed + strippedOrJoined (deleted post-migration).
              else if windowsBase.unpinEmbedsMan or false
              then strippedOrJoined windowsPkgs name
                (withCosmoStrip windowsPkgs { primary = binName; } windowsForEmbed)
              # A multi-program package must ship ONE .exe: fold its single module
              # through the mega path, which embeds man/aliases itself.
              else if windowsSelfFold
              then strippedOrJoined windowsPkgs name windowsSelfFolded
              else unpinEmbedWrap windowsPkgs windowsEmbedOpts windowsForEmbed);
            # The manifest the mega-builder's cosmoMode consumes. The module
            # buckets reference the same built drv's `module` output; external
            # depArchives are verbatim store paths (passthru, NOT linked into the
            # shipped binary).
            cosmoMulticallManifest =
              let entry = "unpin__${sanCSym name}__${sanCSym multicallCosmo.program}_main";
              in {
                moduleFormat = "cosmo-elf";
                moduleObjs = "${windowsForEmbed.module}/objs";
                appletDir = "${windowsForEmbed.module}/applet";
                gnulibDir = "${windowsForEmbed.module}/gnulib";
                depArchives = inScope windowsPkgs (multicallCosmo.depArchives or [ ]);
                # Auto-derived from the cosmo cross build's input closure
                # (e.g. bash → cosmo readline/ncurses); globbed at build time.
                depInputDirs = multicallExternalDepDirs windowsForEmbed;
                applets =
                  [{ name = multicallCosmo.program; inherit entry; }]
                  ++ map (al: { name = al; inherit entry; }) (multicallCosmo.aliases or [ ]);
                requires = { cxx = false; } // (multicallCosmo.requires or { });
              };
            windowsMulticallManifest = bitcodeManifest {
              drv = windowsForEmbed;
              programs = windowsPrograms;
              pkgs = windowsEnginePkgs;
            };
            # SELF-FOLD, windows half — symmetric to `selfFold` on the native
            # side. Without it `multicall.windows = true` only EMITTED a module
            # for the catalog mega and shipped the raw cross build, so a
            # multi-program package announced applets nothing dispatched:
            # measured on bzip2, whose .exe ran bzip2's main under argv[0]
            # `bzip2recover` and leaked `--unpin-program=` to the applet. It went
            # unseen because every package migrated so far (file, grep, sed) has
            # exactly ONE program, where "no dispatcher" and "correct" look alike.
            windowsSelfFold = wantWindowsModule && builtins.length windowsPrograms > 1;
            windowsSelfFoldDefault =
              let
                declared = multicall.defaultProgram or null;
                appletNames = map (a: a.name) windowsMulticallManifest.applets;
                dp = if declared != null then declared else binName;
              in
              # Same rule as the native half, deliberately: a windows-only
              # spelling of "what runs on a bare invocation" would be a second
              # button for one decision, which is what the naming rule closed.
              if declared != null && !builtins.elem declared appletNames then
                throw ''
                  ${name}: multicall.defaultProgram "${declared}" is not one of its windows programs (${builtins.concatStringsSep ", " appletNames}).
                ''
              else if builtins.elem dp appletNames then dp else null;
            # The mega merge takes ONE manRoot per module, but the windows man
            # precedence (explicit `winManRoot` wins; else the cross build's own
            # pages; else the version-locked nixpkgs graft, and only when the
            # chosen root is empty) is resolved by unpinEmbedWrap in SHELL —
            # `[ -d share/man ]` is not knowable in eval without IFD. So stage
            # the identical precedence here instead of guessing a root.
            windowsSelfFoldMan =
              let manSrc = "${windowsForEmbed.man or windowsForEmbed}";
              in
              if !embedMan then null
              else windowsPkgs.buildPackages.runCommand "${name}-windows-man" { } ''
                mkdir -p "$out/share/man"
                __pick=""
                ${if winManRoot != null
                  then ''[ -d "${winManRoot}/share/man" ] && __pick="${winManRoot}"''
                  else ''[ -d "${manSrc}/share/man" ] && __pick="${manSrc}"''}
                ${nixpkgs.lib.optionalString (winManGraft != null) ''
                if [ -d "${winManGraft}/share/man" ] \
                   && { [ -z "$__pick" ] \
                        || [ -z "$(find "$__pick/share/man" \( -type f -o -type l \) -print -quit 2>/dev/null)" ]; }; then
                  __pick="${winManGraft}"
                fi''}
                [ -n "$__pick" ] && cp -rL --no-preserve=mode "$__pick/share/man/." "$out/share/man/" || true
              '';
            windowsSelfFolded = mkMegaMulticall {
              pkgs = windowsPkgs.pkgsCross.mingwW64;
              inherit name;
              modules = [ (windowsMulticallManifest // { manRoot = windowsSelfFoldMan; }) ];
              defaultApplet = windowsSelfFoldDefault;
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
            # A cross artifact. The nixpkgs set is `sharedCrossPkgs.<attr>` when a
            # catalog mega prebuilt it (one fixpoint shared across the fold), else
            # the one spelled out at the call site. withLLDLink: the gc overlay is
            # Linux-native only, so the cross scopes get the standard lld link via
            # NIX_CFLAGS_LINK here — keeps the linker uniform across every non-mac
            # target.
            crossPkg = attr: fallback:
              stripped (withLLDLink pkgsAttr (sharedCrossPkgs.${attr} or fallback));
          in
          checkOpts {
            packages = forAllNative (system:
              let pkgs = nixpkgsFor.${system}; in
              nixpkgs.lib.optionalAttrs (wantsNative system) { default = stripped pkgs; }
              // nixpkgs.lib.optionalAttrs (wantsNative system && system == "aarch64-darwin") {
                "darwin-x86_64" = stripped pkgs.pkgsCross.x86_64-darwin;
              }
              // nixpkgs.lib.optionalAttrs (nativeBuild && system == "x86_64-linux") {
                "linux-i686" = crossPkg "linux-i686" pkgs.pkgsCross.musl32;
                # musl-power = powerpc64le-unknown-linux-musl. Debian calls it
                # "ppc64el" but uname returns "ppc64le" and the Rust ecosystem
                # (rustup, binstall) labels it the same way — we follow uname.
                "linux-ppc64le" = crossPkg "linux-ppc64le" pkgs.pkgsCross.musl-power;
                # riscv64 has no pre-cooked musl variant in nixpkgs.pkgsCross
                # (only glibc). Spell the crossSystem out by triple.
                "linux-riscv64" = crossPkg "linux-riscv64" (import nixpkgs {
                  inherit system;
                  crossSystem = { config = "riscv64-unknown-linux-musl"; };
                });
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
                "linux-armv7l" = crossPkg "linux-armv7l" (import nixpkgs {
                  inherit system;
                  crossSystem = { config = "armv7l-unknown-linux-musleabihf"; };
                });
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
              mk = crossSystem: stripped (withLLDLink pkgsAttr (import nixpkgs {
                system = "x86_64-linux";
                inherit crossSystem;
                # `.#cross` is best-effort: a niche arch may be absent from a
                # package's `meta.platforms` whitelist only because no maintainer
                # blessed it, so bypass the gate (like the windows block). No-op for
                # already-whitelisted arches.
                config.allowUnsupportedSystem = true;
              }));
              byTriple = builtins.mapAttrs (_: config: mk { inherit config; });
              # x86-64 micro-architecture feature levels (psABI 2020): same triple
              # as default x86_64, higher `-march` baseline via gcc.arch. A vN binary
              # SIGILLs below its level, so this is a perf OPT-IN, not portability
              # (default x86_64 stays v1, the "runs anywhere" floor). v2≈Nehalem
              # (SSE4.2), v3≈Haswell (AVX2/FMA), v4 (AVX-512).
              byArch = builtins.mapAttrs
                (_: arch: mk { config = "x86_64-unknown-linux-musl"; gcc.arch = arch; });
            in nixpkgs.lib.optionalAttrs nativeBuild (byTriple {
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
            // byArch {
              # x86-64 perf feature levels (see byArch above). v1 == default x86_64.
              "x86_64-v2" = "x86-64-v2";
              "x86_64-v3" = "x86-64-v3";
              "x86_64-v4" = "x86-64-v4";
            });

            # Read by unpins/action-build to drive CI config.
            manifest = {
              inherit name package_data own_software nativeBuild;
              # null unless the caller opted in; otherwise a list of CLI args,
              # JSON-encoded so build.yml runs `<bin> <args>` after each build.
              inherit smoke;
              # Optional grep-E pattern matching the smoke command's stdout+stderr.
              smoke_pattern = smokePattern;
              # Per-package darwin portability exception (PrivateFramework names).
              darwin_allow_private_frameworks = darwinAllowPrivateFrameworks;
              # Applets that legitimately never answer `--help`: servers that start
              # listening the moment they run (rtmpdump's rtmpsrv/rtmpsuck print a
              # banner and then serve — 338 MB of output in 20 s). The CI sweep
              # still demands they be IN the dispatch table and reachable by
              # argv[0]; it just doesn't execute them. Declared per program with
              # `noHelp = true;` so the exception names itself in the flake instead
              # of hiding in CI.
              applets_no_help =
                if multicall == null then [ ]
                else map (p: p.name)
                  (nixpkgs.lib.filter (p: p.noHelp or false) multicall.programs);
              # What each smoke target DECLARES, so the CI applet sweep can check
              # the shipped binary against the declaration instead of against
              # itself. `manifest` is a flake output, not part of any derivation —
              # nothing added here moves a drvPath. Pure eval too (elaborated
              # platforms, no nixpkgs instantiated), so preflight stays a
              # one-second eval.
              #
              #   dispatcher — nix-lib folds a table dispatcher into this target.
              #     The sweep turns it into a NEGATIVE control: an impossible
              #     `--unpin-program=` name must come back as the dispatcher's own
              #     "no program" error. Nothing at eval or build time can see a
              #     dispatcher that isn't there — the announced list comes from the
              #     DECLARATION, so the announced==embedded guards stay green on a
              #     binary that dispatches nothing. Measured on bzip2's .exe: four
              #     announced applets, all of them running bzip2's main.
              #   programs — the real programs. Two of them need a dispatcher; one
              #     with aliases does not, because those are the program's own
              #     argv[0] self-dispatch (bunzip2/bzcat are bzip2).
              #   announced — exactly what nix-lib packs as `unpin/aliases`, or
              #     null where the wrap harvests the build's own symlinks instead
              #     and nix-lib does not know the set.
              #
              # Keyed `<os>-<arch>` to match build.yml's matrix. A target absent
              # here (every cross but windows) is simply not swept.
              applets_by_target =
                let
                  progsFor = platform:
                    if multicall == null then [ ]
                    else supportedOn platform
                      # Windows keeps `multicall.programs` — see windowsPrograms.
                      (if platform.isDarwin && multicall ? darwinPrograms
                       then multicall.darwinPrograms
                       else multicall.programs);
                  entry = triple:
                    let
                      platform = nixpkgs.lib.systems.elaborate triple;
                      programs = progsFor platform;
                      folds =
                        if platform.isWindows
                        then wantWindowsModule && builtins.length programs > 1
                        else multicall != null && isEngineHost platform
                          && builtins.length programs > 1;
                      # Mirrors declaredAliases / windowsDeclaredAliases. The
                      # windows branch that reads the flake's own build
                      # (`unpinEmbedsAliases`) is deliberately left null: forcing a
                      # derivation attr here would make preflight instantiate the
                      # cross set.
                      announced =
                        if platform.isWindows then
                          (if multicallCosmo != null
                           then [ multicallCosmo.program ] ++ (multicallCosmo.aliases or [ ])
                           else if wantWindowsModule
                           then nixpkgs.lib.concatMap (p: [ p.name ] ++ (p.aliases or [ ])) programs
                           else null)
                        else if multicall == null then null
                        else nixpkgs.lib.concatMap (p: [ p.name ] ++ (p.aliases or [ ])) programs;
                    in
                    {
                      dispatcher = folds;
                      programs = map (p: p.name) programs;
                      announced =
                        if announced == null then null
                        else nixpkgs.lib.filter (a: a != binName) announced;
                    };
                in
                {
                  "linux-x86_64" = entry "x86_64-linux";
                  "linux-aarch64" = entry "aarch64-linux";
                  "darwin-aarch64" = entry "aarch64-darwin";
                  "darwin-x86_64" = entry "x86_64-darwin";
                  "windows-x86_64" = entry "x86_64-w64-mingw32";
                };
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
        mkPkgsLTO = import ./lto.nix { inherit nixpkgs appendCFlags appendLdFlags; };

        # mkPkgsGC: pkgsStatic with a chain-wide function/data-sections overlay
        # (cheap dead-code stripping; see gc.nix). Enabled via
        # `optimize.gc = true`. Linux-native only.
        mkPkgsGC = import ./gc.nix {
          inherit nixpkgs appendCFlags appendLinkFlags lldRSafe lldStdOpts
            gcSectionsFlag;
        };

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
      # The toolchain builds themselves, by build host. Consumers reach the
      # toolchain through `lib.unpinToolchain`, which is lazy and has no attr of
      # its own — so without these there is no way to build or cache it directly,
      # only to trip over it inside some package's closure.
      packages.x86_64-darwin.unpin-toolchain = lib.unpinToolchain "x86_64-darwin";
      packages.x86_64-linux.unpin-toolchain = lib.unpinToolchain "x86_64-linux";
    };
}
