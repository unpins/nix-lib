# The catalog FFmpeg: ffmpeg + ffprobe built with our own configure over
# nix-lib's codec fixes. Shared by the `ffmpeg` package (the programs) and
# `fpcalc` (the libraries chromaprint links). `native` takes the package
# set a mkStandaloneFlake `build` gets, `windows` the one `windowsBuild` gets.
{ lib }:
let
  ulib = lib;
  # Man pages we actually ship: the two CLI tools (ffmpeg/ffprobe) plus
  # the component reference manuals. Deliberately EXCLUDES ffplay.1 /
  # ffplay-all.1 (we --disable-ffplay) and libav*.3 (library API docs that
  # need doxygen; we ship the CLI binaries, not the libraries). EVERY build
  # — native, cross-linux, AND the mingw windows .exe — generates this set
  # in-place in its installPhase (texi2pod.pl + pod2man run on the build
  # host, no target execution) and installs it to $out/share/man, so each
  # binary harvests its OWN man via withMan. man is reproducible roff, so
  # all platforms stay byte-identical. No graft, no separate man derivation.
  usefulMan = [
    "ffmpeg" "ffmpeg-all" "ffprobe" "ffprobe-all"
    "ffmpeg-utils" "ffmpeg-scaler" "ffmpeg-resampler"
    "ffmpeg-codecs" "ffmpeg-bitstream-filters" "ffmpeg-formats"
    "ffmpeg-protocols" "ffmpeg-devices" "ffmpeg-filters"
  ];

  # nixpkgs's pkgsStatic.ffmpeg-headless pulls openapv/ocl-icd/
  # libtiff/libsndfile etc — codec deps that break under pkgsStatic.
  # We ship only the codecs we want and run configure ourselves.
  mkFfmpeg = pkgs:
    { extraConfigureFlags ? [ ]
    , extraInputs ? [ ]
      # Also install the static libraries, headers and .pc files, for a
      # consumer that links libav* itself (fpcalc). Without the chromaprint
      # muxer: that consumer IS chromaprint, and would get two copies of it.
    , installLibs ? false
      # darwin engine: the iconv to link instead of Apple's (null = pkgs.libiconv).
    , iconv ? null
    }:
    let
      stdenv = pkgs.stdenv;
      noChromaprint = l: if installLibs
        then builtins.filter (x: x != "--enable-chromaprint" && (x.pname or "") != "chromaprint") l
        else l;
      isMinGW = stdenv.hostPlatform.isMinGW or false;
      isDarwin = stdenv.hostPlatform.isDarwin;
      # unpin-llvm engine active on this scope — linux, darwin AND the mingw
      # cross, whose whole set multicall.windows = true swaps onto the
      # adapter. Keyed on the cc name so a set-wide swap is seen.
      isEngine = pkgs.lib.hasInfix "unpin-cc" (stdenv.cc.name or "");
      targetOs =
        if isMinGW then "mingw64"
        else if isDarwin then "darwin"
        else "linux";
      exe = if isMinGW then ".exe" else "";
      flags = [
        "--prefix=$out"
        "--cross-prefix=${stdenv.hostPlatform.config}-"
        # ffmpeg's cc_default="gcc" / cxx_default="g++" — appended
        # after cross-prefix this gives `arm64-apple-darwin-gcc` /
        # `…-g++`, neither of which exists on darwin (clang backend).
        # nixos-26.05's clang-21 cc-wrapper for the prefixed darwin
        # toolchain dropped the `-g++` alias too, so the final
        # LDXX link of ffmpeg_g/ffprobe_g died with
        # `x86_64-apple-darwin-g++: command not found`. Force the
        # `-cc`/`-c++` wrapper symlinks, which exist across both the
        # clang and gcc nixpkgs cc-wrappers on every target.
        "--cc=${stdenv.hostPlatform.config}-cc"
        "--cxx=${stdenv.hostPlatform.config}-c++"
        "--host-cc=${pkgs.buildPackages.stdenv.cc}/bin/cc"
        # Hard-reference the cross pkg-config wrapper. Splicing in
        # nativeBuildInputs picks the BUILD-platform wrapper (named
        # after build triple), and ffmpeg's auto-derive (cross_prefix
        # + "pkg-config") expects a HOST-triple binary — match never
        # happens, pkg_config silently becomes "false", every probe
        # returns "not found". `pkgsBuildHost.pkg-config` (default,
        # pre-splicing) IS the host-triple wrapper; reference it by
        # explicit /bin path to bypass the splicing rewrite.
        "--pkg-config=${pkgs.pkgsBuildHost.pkg-config}/bin/${stdenv.hostPlatform.config}-pkg-config"
        "--enable-cross-compile"
        "--target-os=${targetOs}"
        "--arch=${stdenv.hostPlatform.uname.processor}"
        # ffmpeg's configure auto-derives pkg-config as
        # `${cross_prefix}pkg-config` — the binary the wrapper
        # actually ships. Don't pass `--pkg-config=pkg-config`
        # or it looks for a bare `pkg-config` that isn't in PATH.
        "--pkg-config-flags=--static"
        # Every target, windows included, builds the curated man set in
        # place (pod2man on the build host; reproducible roff). No html/txt/pod.
        "--disable-htmlpages" "--disable-txtpages" "--disable-podpages"
        "--disable-debug" "--disable-stripping"
        "--enable-gpl" "--enable-version3"
        "--enable-runtime-cpudetect" "--enable-network"
        "--disable-ffplay" "--enable-ffmpeg" "--enable-ffprobe"
        "--enable-zlib" "--enable-bzlib" "--enable-lzma" "--enable-iconv"
        "--enable-libx264" "--enable-libdav1d" "--enable-libopus"
        "--enable-libvorbis" "--enable-libmp3lame" "--enable-libzimg"
      ]
      # darwin can't take any "-static" linker flag (Apple ships
      # only libSystem.dylib — no libSystem.a, so the compiler probe
      # `cc -static main.c` aborts configure). On darwin we rely on
      # ld picking the dep .a's by preference and let libSystem stay
      # implicit-dynamic per docs/dynamic-link-policy.md. ffmpeg
      # reinterprets `--enable-static --disable-shared` as
      # LDFLAGS=-static internally (same trap that hit htop / tmux),
      # so omit those too on darwin.
      #
      # `-Wl,-search_paths_first` so ld64 prefers a dep's `.a` over any
      # same-named dylib beside it, instead of its default
      # `-search_dylibs_first`. (libSystem stays implicit-dynamic.)
      # See docs/dynamic-link-policy.md.
      ++ (if isDarwin then ([
            "--extra-ldflags=-Wl,-search_paths_first"
          ]
          # Same token, same two roles, as the linux branch below; it is
          # meaningful only with the postPatch rename, so it rides the same gate.
          ++ pkgs.lib.optional isEngine "--extra-libs=-lc++")
          else if isMinGW then [
            # One .exe, no DLLs: `-static` picks `.a` over `.dll.a`.
            # `--allow-multiple-definition`: librsvg-2.a (Rust) bundles
            # compiler_builtins symbols (`___chkstk_ms`, `__udivti3`, …) that
            # the runtime archives define again.
            "--enable-static" "--disable-shared"
            "--extra-ldflags=-static"
            "--extra-ldflags=-Wl,--allow-multiple-definition"
          ]
          ++ (if isEngine then [
            # Engine mingw: `-static-libgcc`/`-static-libstdc++` name gcc
            # runtimes that do not exist here, so the C++ deps had nothing
            # holding their runtime. It shows up as configure rejecting the
            # FIRST C++ dep it probes through `require_pkg_config`
            # ("chromaprint not found"): its `.pc` is `-lchromaprint` alone,
            # the probe links with the C driver, and every `std::`/`__cxa_*`
            # is undefined. See the `-lc++` note on the linux branch.
            "--extra-libs=-lc++"
          ] else [
            # off-engine (gcc) mingw: fold libgcc/libstdc++ in.
            "--extra-ldflags=-static-libgcc"
            "--extra-ldflags=-static-libstdc++"
          ])
          else [ "--extra-ldflags=-static" "--enable-static" "--disable-shared" ]
            # `-lc++` is the one C++ token every engine target passes, and it
            # does two jobs at once.
            #
            # It marks the link as C++. ffmpeg drives its own links with the C
            # compiler, so nothing would otherwise pull a C++ runtime for the
            # C++ codec deps — some ffmpeg detects with a hardcoded runtime
            # name (libgme…), others (srt) come via `require_pkg_config` with a
            # `.pc` that omits the runtime entirely, and either way every
            # `std::__1::…` ends up undefined. The engine driver reads `-lc++`
            # as "this link is C++" (`wantsCxx`, unpin_musl.cpp) and answers
            # with `-L<sysroot>/cxx/lib` plus libc++, libc++abi and libunwind
            # from the ENGINE, inside one `--start-group` with libc and the
            # builtins. So the three archives arrive on their own: naming them
            # here would stage duplicates OUTSIDE that group, and a staged
            # `-lunwind` in the build tree is exactly what the capture shim
            # records as LOCALA, swallowing the unwinder into `module.bc` and
            # colliding with the mega link's own copy.
            #
            # It is also ffbuild/common.mak's sentinel for "link this with
            # $(CXX)" — the token is filtered back out before the linker sees
            # it, and postPatch renames that sentinel from `-lstdc++` to match.
            ++ pkgs.lib.optionals isEngine [
              "--extra-libs=-lc++"
              # The 8 MB thread stack nix-lib gives the folded binary (musl's
              # default is 128 KB; libaom and ffv1 overflowed it), so the
              # binary the installCheck below runs behaves like the shipped one.
              "--extra-ldflags=-Wl,-z,stack-size=8388608"
            ]
            # armv7l only: the sysroot's `libunwind.a` is NATIVE while every
            # dep and musl itself are bitcode. On ARM, LTO codegen emits the
            # EHABI `_Unwind_Resume` calls that any cleanup needs, so nothing
            # references libunwind until AFTER the LTO step — and a member
            # pulled that late brings undefined `fprintf`/`snprintf`/`stderr`/
            # `abort`/`__assert_fail` that the bitcode libc can no longer
            # satisfy, LTO having already chosen its members. (`-lc` appended
            # afterwards does not help, for the same reason.) It surfaces as a
            # bogus `fontconfig not found using pkg-config` — fontconfig is
            # simply the first configure probe with enough bitcode behind it to
            # emit a cleanup. Forcing the symbol undefined from the start pulls
            # libunwind in the pre-LTO archive pass instead, so its libc needs
            # are visible while LTO still has the whole bitcode libc to draw
            # from. Same class as the i686 `-Wl,-u,malloc` in the musl-bitcode
            # work; one symbol is enough because the rest ride in with it.
            ++ pkgs.lib.optional
              (isEngine && pkgs.stdenv.hostPlatform.isAarch32)
              "--extra-ldflags=-Wl,-u,_Unwind_Resume")
      ++ noChromaprint extraConfigureFlags;
    in
    stdenv.mkDerivation ({
      pname = "ffmpeg";
      inherit (pkgs.ffmpeg-headless) version src;
      # ALSA's `pipewire`/`pulse` PCM plugin lives in its own object inside
      # the static libasound (audio.nix); the patch references it so the link
      # keeps it.
      patches = pkgs.lib.optional stdenv.hostPlatform.isLinux ./ffmpeg-alsa-pipewire.patch
        # engine: inline-asm probes that really assemble, and -lc++ where
        # ffmpeg says -lstdc++. Each patch header carries the why.
        ++ pkgs.lib.optional isEngine ./ffmpeg-engine-configure.patch
        ++ pkgs.lib.optional (stdenv.hostPlatform.isRiscV or false) ./ffmpeg-riscv-hwprobe.patch
        ++ pkgs.lib.optional (isEngine && isMinGW) ./ffmpeg-mingw-nonlocal-labels.patch;

      # pkgsBuildHost is the canonical "build tools that target host"
      # scope:
      #   linux x86_64-linux native → x86_64-unknown-linux-musl-pkg-config
      #   mingw cross            → x86_64-w64-mingw32-pkg-config
      #   darwin x86_64-darwin cross from arm64-darwin
      #                          → x86_64-apple-darwin-pkg-config
      # ffmpeg's --cross-prefix=<triple>- derives a `<triple>-pkg-config`
      # binary that has to be on PATH; pkgsBuildHost.pkg-config is named
      # to match. `pkgs.buildPackages` picks the BUILD platform's wrapper
      # (wrong triple), and `pkgs.X` with no scope is static + unprefixed.
      # Also: pkgsBuildHost.perl is non-static (build-time tool) — `pkgs`
      # in cross-darwin-pkgsStatic gives perl-static which fails to build.
      nativeBuildInputs = with pkgs.pkgsBuildHost; [ pkg-config nasm yasm perl ];
      # libopus + dav1d carry darwin-aarch64 meson `cpu_family =
      # 'arm64'` fixes; on darwin they come patched from the
      # pkgsStatic overlay below (so transitive consumers — e.g.
      # libsndfile → libopus — see the same patched build), vanilla
      # elsewhere.
      # Apple's libiconv cannot stay on darwin: the engine's libxml2 is built
      # against GNU's (darwinIconvConverge), so configure's link test of
      # libbluray → libxml2 fails on `libiconv_open`. mkStandaloneFlake swaps
      # it on the binary it builds (darwinIconvFixed), which misses this
      # derivation when it is a library dep (fpcalc).
      buildInputs = (with pkgs; [
        zlib bzip2 xz
        (if isDarwin && isEngine && iconv != null then iconv else libiconv)
        x264 libvorbis libogg lame zimg
        libopus dav1d
      ]) ++ noChromaprint extraInputs;

      strictDeps = true;
      enableParallelBuilding = true;
      stripAllList = [ "bin" ];

      # ffmpeg links each program as `<prog>_g` (its debug binary) then
      # copies it to `<prog>`. The engine's link-capture sidecar is keyed by
      # the LINKED output name, so it lands as `<prog>_g.link`, but the
      # multicall module hook (appended to this postBuild) reads `<prog>.link`
      # → `no link sidecar for ffmpeg`. Alias the sidecars to the program
      # names. Engine-only (`$UNPIN_LINK_DIR` is unset off-engine).
      postBuild = pkgs.lib.optionalString isEngine ''
        for p in ffmpeg ffprobe; do
          [ -f "$UNPIN_LINK_DIR/''${p}_g.link" ] \
            && cp "$UNPIN_LINK_DIR/''${p}_g.link" "$UNPIN_LINK_DIR/$p.link" || true
        done
      '';

      configurePhase = ''
        runHook preConfigure
        ./configure ${builtins.concatStringsSep " " flags}
        ${pkgs.lib.optionalString (stdenv.hostPlatform.isPower64 or false) ''
          # `maclhw`/`mullhw` (libavcodec/ppc/mathops.h `#if HAVE_PPC4XX`) are
          # 32-bit PPC-4xx/BookE MAC instructions absent on any 64-bit PowerPC.
          # configure's `check_inline_asm ppc4xx` compiles a `maclhw` snippet
          # to set HAVE_PPC4XX, but under the engine's `-flto` clang defers
          # inline-asm assembly to link time → the probe is a false positive and
          # `enable`s ppc4xx even over `--disable-ppc4xx`. Force HAVE_PPC4XX off
          # in the generated config.h (what mathops.h reads), else the invalid
          # instruction only detonates at the LTO fold-link.
          sed -i 's/#define HAVE_PPC4XX 1/#define HAVE_PPC4XX 0/' config.h
        ''}
        runHook postConfigure
      '';

      installPhase = ''
        runHook preInstall
        mkdir -p $out/bin $out/share/man/man1
        cp ffmpeg${exe} ffprobe${exe} $out/bin/
        # `-tls_verify 1` depends on the retargeted OpenSSL (system CA
        # lookup + embedded roots); a scope that missed retargetOpenssl
        # still builds and only fails on a user's machine.
        grep -aq "unpins embedded CA roots: Mozilla NSS" ffmpeg${exe} \
          || { echo "ffmpeg: linked an OpenSSL without the embedded CA roots" >&2; exit 1; }
        # Curated man set, generated by THIS build (see the configure note):
        # build the 13 pages and install exactly them; every target harvests
        # its own $out/share/man. man is reproducible, so the sets are
        # byte-identical.
        make ${builtins.concatStringsSep " " (map (m: "doc/${m}.1") usefulMan)}
        cp ${builtins.concatStringsSep " " (map (m: "doc/${m}.1") usefulMan)} \
          $out/share/man/man1/
      '' + pkgs.lib.optionalString installLibs ''
        make install-libs install-headers
      '' + ''
        runHook postInstall
      '';

      # Encode for real with the encoders that have broken here while
      # `-version` and the lavfi smoke stayed green: libaom-av1 and ffv1
      # overflowed musl's 128 KB thread stack on every linux target,
      # libmp3lame crashed on every i686 encode, and libtheora's inlined asm
      # crashed on windows. One run per encoder, so a failure names it. This
      # is the only place i686 runs at all — CI smokes the native runners.
      doInstallCheck = stdenv.buildPlatform.canExecute stdenv.hostPlatform;
      installCheckPhase = ''
        runHook preInstallCheck
        src="-f lavfi -i testsrc2=s=64x64:r=25:d=0.4 -f lavfi -i sine=d=0.4"
        for enc in ffv1 libaom-av1 libsvtav1 libvpx-vp9 libx264 libx265 libtheora \
                   libmp3lame libopus libvorbis; do
          case $enc in
            libmp3lame|libopus|libvorbis) map="-map 1:a -c:a $enc" ;;
            libaom-av1) map="-map 0:v -c:v $enc -cpu-used 8" ;;
            libsvtav1) map="-map 0:v -c:v $enc -preset 12" ;;
            *) map="-map 0:v -c:v $enc" ;;
          esac
          "$out/bin/ffmpeg${exe}" -hide_banner -nostdin -v error $src $map -f null - \
            || { echo "installCheck: -c $enc failed (exit $?)"; exit 1; }
        done
        echo "installCheck: every encoder above encoded"
        runHook postInstallCheck
      '';

      passthru = { pname = "ffmpeg"; inherit (pkgs.ffmpeg-headless) version; };
    }
    # Gated so the targets that cannot run it keep the derivation they
    # already had: an inert `checkPhase` string still changes a drv hash,
    # and rebuilding windows/armv7l/ppc64le/riscv64 to ship a test none of
    # them executes is churn with nothing on the other side. (The install
    # check above is ungated for historical reasons; folding it in here
    # would move those same four derivations for no behaviour change.)
    // pkgs.lib.optionalAttrs (stdenv.buildPlatform.canExecute stdenv.hostPlatform) {
      # FATE's one slice that needs no sample data: checkasm runs each
      # hand-written SIMD kernel against the C reference in the same
      # process and compares the results. That is the class of defect that
      # has broken here under the engine and stayed green all the way to a
      # release — libhwy's f16 ABI, x265's strtod on i686, a false-positive
      # `HAVE_PPC4XX` probe — because `-version` and the encode check above
      # prove the code *runs*, never that it computes what the C path
      # computes. `--enable-runtime-cpudetect` is already on, so one run
      # exercises every SIMD level the host CPU offers.
      #
      # The rest of FATE stays out on purpose: 98 of its 114 test files
      # need the 1.35 GB rsync sample suite, which upstream publishes as a
      # mutable directory with no tarball, no version and no checksum —
      # nothing to pin a fixed-output derivation to.
      doCheck = true;
      checkPhase = ''
        runHook preCheck
        make -j"''${NIX_BUILD_CORES:-4}" tests/checkasm/checkasm

        # One invocation runs every registered test; `make fate-checkasm`
        # spends 91 process starts to cover the same functions.
        #
        # The trailing `1` is checkasm's seed argument. Upstream lets it
        # default to a random one, which is right for a fuzzer and wrong
        # for a build: a kernel that fails on one seed in twenty would
        # turn every rebuild into a coin flip and never reproduce. Fixed
        # seed makes a red build mean something and a green build a fact.
        ./tests/checkasm/checkasm 1 2>&1 | tee checkasm.log

        # checkasm exits 0 when it registers nothing at all — it prints
        # "checkasm: all 0 tests passed" and returns success, which is
        # precisely the vacuous green a guard like this exists to avoid.
        # Pin it to something that cannot be configured away: libavutil's
        # six kernels (aes, av_tx, crc, fixed_dsp, float_dsp, lls) are in
        # tests/checkasm/Makefile ungated, so a live harness always
        # checks at least one of them.
        ./tests/checkasm/checkasm --test=float_dsp 1 2>&1 | tee checkasm-floor.log

        # `tee` hides the exit status, and the pass line is printed only
        # on success, so read the verdict out of the logs instead.
        for log in checkasm.log checkasm-floor.log; do
          grep -q '^checkasm: all [0-9]* tests passed$' "$log" \
            || { echo "checkasm: no pass line in $log" >&2; exit 1; }
        done
        floor=$(sed -n 's/^checkasm: all \([0-9]*\) tests passed$/\1/p' checkasm-floor.log)
        [ "''${floor:-0}" -ge 1 ] \
          || { echo "checkasm: float_dsp registered no check — harness is vacuous" >&2; exit 1; }
        runHook postCheck
      '';
    });
  # `mkExtras` returns the cross-platform set of feature flags and
  # build inputs that ride on `sharedExtras`. Parameterised on a
  # `pkgsStatic`-like scope so the same registry of fixes applies
  # uniformly to linux, darwin, and mingw — each `nativeFixes.X` is
  # platform-aware (no-op on platforms where the upstream is already
  # fine).
  mkExtras = pkgsStaticScope:
    let
      isEngineScope = pkgsStaticScope.lib.hasInfix "unpin-cc"
        (pkgsStaticScope.stdenv.cc.name or "");
      # Direct (no-feature-disable) fixes pulled in from nix-lib's
      # native-overlay. See `nix-lib/native-overlay/<pkg>.nix` for
      # the per-package rationale.
      svtAv1NoLto    = ulib.nativeFixes.svt-av1        pkgsStaticScope;
      x265Static     = ulib.nativeFixes.x265           pkgsStaticScope;
      xvidStatic     = ulib.nativeFixes.xvidcore       pkgsStaticScope;
      gmeStatic      = ulib.nativeFixes.game-music-emu pkgsStaticScope;
      # On the native engine scopes nix-lib injects an already-fixed librsvg
      # into `pkgsStatic.librsvg` (built in the engine set on Linux, from a
      # pristine pkgsStatic on darwin — see rustDepsOverlay); use it directly.
      # The mingw set does NOT get that injection (windowsPkgsShared is a raw
      # nixpkgs import — the withRustDeps layer only wraps the pkgsStatic
      # chain), so keep applying the fix there. It also carries the
      # mingw-only `-lshell32` rustflag.
      librsvgStatic  = if pkgsStaticScope.stdenv.hostPlatform.isMinGW or false
                       then ulib.nativeFixes.librsvg pkgsStaticScope
                       else pkgsStaticScope.librsvg;
      libvpxPkg      = ulib.nativeFixes.libvpx         pkgsStaticScope;
      quircStatic    = ulib.nativeFixes.quirc          pkgsStaticScope;
      # Feature-disable fixes that the user signed off on (the
      # rationale lives in each fix file). srt and libssh run on the
      # OpenSSL ffmpeg links for TLS; rubberband drops
      # side-target plugins; librist skips broken tests; qrencode's
      # darwin fixup drops a stray dylib;
      # libopenmpt + mpg123 drop CLI audio backends; soxr drops
      # openmp; libbluray renames `dec_init` + (darwin) drops
      # fontconfig.
      soxrNoOmp       = ulib.nativeFixes.soxr       pkgsStaticScope;
      srtOpenssl      = (ulib.nativeFixes.srt       pkgsStaticScope).withOpenssl;
      libsshOpenssl   = ulib.nativeFixes.libssh     pkgsStaticScope;
      libristNoTest   = ulib.nativeFixes.librist    pkgsStaticScope;
      qrencodeStatic  = ulib.nativeFixes.qrencode   pkgsStaticScope;
      rubberbandLean  = ulib.nativeFixes.rubberband pkgsStaticScope;
      libbluraySafe   = ulib.nativeFixes.libbluray  pkgsStaticScope;
      libopenmptLean  = ulib.nativeFixes.libopenmpt pkgsStaticScope;
      chromaprintLean = ulib.nativeFixes.chromaprint pkgsStaticScope;
      # fftw (pulled transitively by rubberband/speex/speexdsp) is fixed
      # via the pkgsStatic overlay in `build` below, not as a direct
      # input — ffmpeg has no fftw feature of its own.
      vidStabPkg      = ulib.nativeFixes.vid-stab   pkgsStaticScope;
      speexdspPkg     = ulib.nativeFixes.speexdsp   pkgsStaticScope;
      speexPkg        = ulib.nativeFixes.speex      pkgsStaticScope;
    in {
      flags = [
        # TLS (https, rtmps, DTLS for WHIP) and the RTMPE handshake. OpenSSL
        # rather than mbedtls because `-tls_verify 1` has to find CA roots:
        # ffmpeg's OpenSSL backend loads the default verify paths, which
        # nix-lib's retargetOpenssl points at the host's bundle (Mozilla's
        # roots embedded as the fallback, and always on Windows); the
        # mbedtls backend reads only an explicit `-ca_file`, so verification
        # rejected every server.
        "--enable-openssl"
        "--enable-libsvtav1"
        "--enable-libx265"
        "--enable-libwebp"
        "--enable-libvpx"
        "--enable-libsoxr"
        "--enable-libtheora"
        "--enable-libsrt"
        "--enable-libaom"
        "--enable-libopenjpeg"
        "--enable-libxml2"
        "--enable-libxvid"
        "--enable-libopenmpt"
        "--enable-libtwolame"
        "--enable-libspeex"
        "--enable-libssh"
        "--enable-libbluray"
        # No --enable-librtmp on purpose: it conflicts-out ffmpeg's native
        # rtmp/rtmpe/rtmps protocols (configure: rtmp_protocol_conflict /
        # ffrtmpcrypt_protocol_conflict = librtmp_protocol). The native impl
        # does rtmpe:// / rtmps:// / rtmpts:// via the OpenSSL we already
        # enable (rtmpdh.c CONFIG_OPENSSL), so librtmp would only ADD a dep
        # and SUBTRACT working crypto. rtmpdump-the-CLI ships separately.
        # librist has no OpenSSL backend (mbedtls, nettle or a built-in AES
        # without SRP authentication), so it keeps mbedcrypto.
        "--enable-librist"
        "--enable-libqrencode"
        "--enable-libopencore-amrnb"
        "--enable-libopencore-amrwb"
        "--enable-libvidstab"
        "--enable-librubberband"
        "--enable-chromaprint"
        "--enable-libzvbi"
        "--enable-libgme"
        "--enable-libquirc"
        "--enable-libbs2b"
        "--enable-libmysofa"
        "--enable-libfreetype"
        "--enable-libfribidi"
        "--enable-librsvg"
        "--enable-libass"
        "--enable-libharfbuzz"
        "--enable-libfontconfig"
      ];
      inputs = with pkgsStaticScope; [
        openssl      openssl.dev
        libwebp
      ] ++ [ libvpxPkg libvpxPkg.dev ] ++ (with pkgsStaticScope; [
        libtheora    libtheora.dev
        libaom       libaom.dev
        openjpeg     openjpeg.dev
        libxml2      libxml2.dev
        libbs2b
        libmysofa    libmysofa.dev
        twolame
        opencore-amr
        zvbi         zvbi.dev
      ]) ++ [ svtAv1NoLto x265Static x265Static.dev soxrNoOmp soxrNoOmp.dev srtOpenssl xvidStatic libsshOpenssl libsshOpenssl.dev libbluraySafe libristNoTest qrencodeStatic qrencodeStatic.dev rubberbandLean chromaprintLean gmeStatic libopenmptLean libopenmptLean.dev quircStatic speexPkg speexPkg.dev vidStabPkg ]
        ++ (with pkgsStaticScope; [
          freetype  freetype.dev
          fribidi   fribidi.dev
          libass    libass.dev
          harfbuzz  harfbuzz.dev
          fontconfig fontconfig.dev
        ])
        ++ [ librsvgStatic librsvgStatic.dev ]
        # Off-engine musl only: nongnu libunwind for the `-lunwind` musl Rust
        # (librsvg) asks for. The engine links LLVM's libunwind itself, and
        # nongnu's i686 `_Unwind_Resume` needs a libc `setcontext` musl lacks.
        ++ (if isEngineScope || (pkgsStaticScope.stdenv.hostPlatform.isMinGW or false)
            then [ ]
            else [ pkgsStaticScope.libunwind ]);
    };
in
rec {
  native = nativeWith { };
  windows = windowsWith { };
  # darwin: the mega relinks from bitcode, so it must name the frameworks
  # itself — nothing propagates here from ffmpeg-static's buildInputs, and
  # ffmpeg's configure never recorded them as flags (the link line the hook
  # captures holds archives only). Derived, not guessed: take the undefined
  # symbols of module.bc + module_native.a AND of every auto-derived dep
  # archive, subtract what all of those plus libSystem define, and map the
  # remainder against the SDK's .tbd exports. Scanning only the module is a
  # LOWER BOUND — the mega globs `lib/*.a` across the closure, so a pulled
  # archive's own references count too (that is what Accelerate and
  # DiskArbitration turned out to be). What survives this list is 16 symbols,
  # all explained: `__dso_handle` comes from the linker, and the
  # `ff_mlp_{fir,iir}order_*` are ffmpeg's own module-level inline asm, absent
  # from the IR symbol table and materialized only at codegen.
  #
  # Four groups: ffmpeg's own darwin backends (VideoToolbox/CoreMedia/
  # CoreVideo, AudioToolbox/CoreAudio, AVFoundation for the avfoundation
  # indev, OpenGL, Accelerate for vDSP's FFT); the text-rendering chain via
  # librsvg → pango → cairo (CoreText/CoreGraphics/ImageIO); glib's gio, which
  # reaches the macOS type and handler database (CoreServices), enumerates
  # mounts through DiskArbitration, and posts notifications through
  # Foundation/AppKit; and CoreFoundation/CoreImage under those. glib arrives
  # even though ffmpeg never links it directly — librsvg is a Rust `staticlib`
  # whose archive BUNDLES its native deps' objects. Ignored off darwin
  # (darwinFrameworkFlags is host-gated).
  darwinFrameworks = [
    "VideoToolbox" "CoreMedia" "CoreVideo" "AVFoundation"
    "AudioToolbox" "CoreAudio" "OpenGL"
    "CoreText" "CoreGraphics" "CoreImage" "ImageIO" "Accelerate"
    "CoreServices" "CoreFoundation" "Foundation" "AppKit"
    "DiskArbitration"
  ];

  # Store paths FFmpeg's dependencies bake in as install-time defaults: locale
  # dirs (glib's, and gettext's own on Windows), glib's gio module and helper
  # dirs, pango/fontconfig config dirs, libthai's dictionary, libvpx's
  # build-config string, alsa-lib's and libpulse's plugin and helper dirs. A
  # static binary never loads modules or ships those files, so the paths are
  # dead; scrub them (removeReferences). FFmpeg's own configuration string
  # (`-version`) carries `--host-cc`, the build machine's compiler wrapper,
  # which on a cross build would pull that whole compiler into the closure.
  deadRefs = [
    "glib-" "gdk-pixbuf-" "pango-" "fontconfig-" "libthai-" "zvbi-" "libvpx-"
    "alsa-lib-" "libpulseaudio-" "gettext-" "gcc-wrapper-" "clang-wrapper-"
  ];

  # Linux: libpulse's internal archive sits in lib/pulseaudio/, where the
  # engine fold's dep glob (lib/*.a) doesn't look. For `multicall.depArchives`.
  depArchives = origPkgs:
    let lp = (ulib.unpinAudio (nativePkgs origPkgs).pkgsStatic).libpulse;
    in if origPkgs.stdenv.hostPlatform.isLinux
      then [ "${lp}/lib/pulseaudio/libpulsecommon-${lp.version}.a" ]
      else [ ];

  # The same build with the libraries installed too (see installLibs).
  libs = {
    native = nativeWith { installLibs = true; };
    windows = windowsWith { installLibs = true; };
  };

  # The package set the native build sees.
  nativePkgs = origPkgs:
    # Overlay darwin-specific structural fixes into `pkgsStatic`
    # so every transitive consumer sees the patched libs (linux
    # passes through unchanged — each `nativeFixes.X` short-circuits
    # to `prev.X` on non-darwin).
    #
    # - `glib`: nixpkgs' linux→darwin meson cross-file lacks
    #   `objc`/`objcpp` binaries; glib's `add_languages('objc')`
    #   aborts. Fix injects a partial cross-file pointing at
    #   `$CC`/`$CXX` (clang handles `.m`/`.mm`). Unblocks the
    #   text-rendering chain (librsvg → pango → harfbuzz, libass).
    # - `fontconfig`: two upstream tests compare sysroot paths as
    #   strings; darwin's `/tmp → /private/tmp` symlink makes them
    #   disagree. Test bug, not a fontconfig defect — fix turns
    #   `doCheck` off on darwin. Pulled transitively by cairo.
    # - `pango`: same `add_languages('objc')` cross-file gap as
    #   glib, for the Core Text font backend; same fix.
    # - `cairo`: nixpkgs cross-file generation looks up
    #   `ipc_rmid_deferred_release` by `parsed.kernel.name` against
    #   { linux, freebsd, netbsd, windows } — darwin missing, throws.
    #   Bites cross-within-darwin (aarch64-darwin ↔ x86_64-darwin),
    #   the CI path; native x86_64-darwin from Intel Mac doesn't
    #   trip. Fix reconstructs mesonFlags with an equivalent
    #   cross-file that hard-codes 'false' (macOS shmctl IPC_RMID
    #   forbids subsequent attaches).
    # - `dav1d`: nixpkgs writes `cpu_family = 'arm64'` into the
    #   darwin-aarch64 meson cross-file; dav1d reads that as ARM-32
    #   and assembles `src/arm/32/*.S` with arm64 clang → "vector
    #   register expected". Patches the cpu_family branches to route
    #   'arm64' to the 64-bit asm dispatch. Bites the native
    #   darwin-aarch64 CI runner (the `--enable-libdav1d` dep).
    # - `libopus`: same `cpu_family = 'arm64'` cross-file mismatch;
    #   opus's meson.build only matches `['arm', 'aarch64']`, so
    #   the NEON branch is skipped and it errors at line 617
    #   ("no intrinsics support for arm64"). Must live in the
    #   overlay (not just ffmpeg's direct buildInputs) because
    #   libsndfile → rubberband pull libopus transitively and would
    #   otherwise get the unpatched build.
    # - `fftw`: nixpkgs drags `gfortran-wrapper` into fftw's
    #   nativeBuildInputs on EVERY platform although fftw never
    #   enables Fortran, forcing a full cross-GCC build (~30-60 min,
    #   not on cache.nixos.org; a hard failure on darwin). The nix-lib
    #   fix strips it (output-neutral). Apply as an overlay so the
    #   transitive consumers — rubberband (double), speex/speexdsp
    #   (single) — rebuild against the gfortran-free fftw instead of
    #   each dragging cross-gfortran. ffmpeg has no fftw feature of
    #   its own; it's purely transitive. The fix targets `pkgs.fftw`,
    #   so feed it `fftwFloat` via an attr-swap to reuse the same
    #   logic (incl. the darwin openmp side-step) for single precision.
  origPkgs // {
      pkgsStatic = origPkgs.pkgsStatic.extend (final: prev:
        {
          fftw      = ulib.nativeFixes.fftw prev;
          fftwFloat = ulib.nativeFixes.fftw (prev // { fftw = prev.fftwFloat; });
          # libsndfile (pulled transitively) links the `libmpg123` attr —
          # a distinct, already-libOnly package, NOT `mpg123` — whose
          # mpg123/out123 CLI still gets built and dies on the engine LTO
          # `undefined symbol: fputs`. Route it through the same lib-only
          # fix (adds `--disable-components`). Overlay only `libmpg123`, not
          # `mpg123`: libopenmpt re-applies `nativeFixes.mpg123` via
          # `.override`, which would discard our overrideAttrs on an
          # already-overlaid `mpg123`.
          libmpg123 = ulib.nativeFixes.mpg123 prev;
        }
        # i686 only, so other arches keep their cache hit.
        // (if origPkgs.stdenv.hostPlatform.isx86_32 then {
          libvorbis = prev.libvorbis.overrideAttrs (o: {
            patches = (o.patches or [ ]) ++ [ ./libvorbis-i686-no-ieee-fp.patch ];
          });
        } else { })
        # libsndfile uses ALSA only for its sndfile-play program, yet a
        # static build propagates alsa-lib to every consumer. Drop it: the
        # one alsa-lib here is audio.nix's (see linuxOnlyExtras).
        // (if origPkgs.stdenv.hostPlatform.isLinux then {
          libsndfile = prev.libsndfile.override { alsa-lib = null; };
        } else { })
        // (if origPkgs.stdenv.hostPlatform.isDarwin then {
          glib       = ulib.nativeFixes.glib       prev;
          fontconfig = ulib.nativeFixes.fontconfig prev;
          pango      = ulib.nativeFixes.pango      prev;
          cairo      = ulib.nativeFixes.cairo      prev;
          dav1d      = ulib.nativeFixes.dav1d      prev;
          libopus    = ulib.nativeFixes.libopus    prev;
        } else { })
        # riscv64 libjpeg-turbo's broken RVV simdcoverage helper is dropped
        # SET-WIDE in nix-lib (withLibjpegNoLto for the engine scope), since
        # librsvg's transitive libjpeg never passes through this per-flake
        # overlay. Nothing to do here.
      );
    };

  nativeWith = opts: origPkgs:
    let
      pkgs = nativePkgs origPkgs;
      isDarwin = pkgs.stdenv.isDarwin;
      isLinux = pkgs.stdenv.hostPlatform.isLinux;
      # nixpkgs `pkgsStatic.libcaca` puxa `imlib2 (x11Support=true)` +
      # libX11 + libXext porque o default da recipe é `x11Support ?
      # !stdenv.isDarwin`. Em pkgsStatic isso quebra (imlib2 com X11
      # cai em libX11 → fontconfig → expat chain inviável). ffmpeg só
      # usa o `caca_outdev` que renderiza no terminal via ncurses ou
      # slang — X11 não é caminho. `.override { x11Support = false; }`
      # desativa o flag de configure (`--disable-x11`) e cai pro
      # imlib2 sem X (que builda fino).
      #
      # Segundo trap: libcaca autotools recurse sempre em SUBDIRS=
      # `kernel caca src examples tools cxx`. O `examples/conio.c:76`
      # define uma `move()` local que colide com ncurses `move()` em
      # link estático (`multiple definition of move`). Não há flag
      # autoconf pra disable-examples — a saída é limitar build +
      # install ao subdir `caca/` (que tem o .a + caca.pc + headers,
      # tudo que ffmpeg precisa). Outputs vão pra ["out" "dev"] (sem
      # `bin` porque não buildamos `tools/caca-config`).
      libcacaTerm = (pkgs.pkgsStatic.libcaca.override { x11Support = false; }).overrideAttrs (oa: {
        outputs = [ "out" "dev" ];
        buildPhase = ''
          runHook preBuild
          make -C caca
          runHook postBuild
        '';
        installPhase = ''
          runHook preInstall
          make -C caca install
          runHook postInstall
        '';
        postInstall = "";
        # libcaca's caca.pc declares `Libs.private: -lz` mas omite o
        # ncurses driver (`-lncursesw`), apesar do .a usar `curs_set`,
        # `initscr`, etc. Em distros normais (dynamic-link) o consumer
        # carrega ncurses.so transitivamente; em pkgsStatic + ffmpeg
        # `--pkg-config-flags=--static` o link falha com `undefined
        # reference to curs_set`. Appendar `Requires.private: ncursesw`
        # → pkg-config resolve ncursesw.pc e injeta `-lncursesw` no
        # tail do link line.
        postFixup = (oa.postFixup or "") + ''
          echo 'Requires.private: ncursesw' \
            >> $dev/lib/pkgconfig/caca.pc
        '';
      });
      sharedExtras = mkExtras pkgs.pkgsStatic;
      # Linux-only extras: features that only exist on a Linux kernel.
      #   - libdrm/kmsgrab: KMS is a Linux kernel ABI
      #   - libxcb/x11grab: X11 socket — macOS isn't headless X
      #   - libcdio/libcdio-paranoia: Linux CDDA ioctls
      #   - libcaca: terminal output device, niche; pulls ncurses
      audio = ulib.unpinAudio pkgs.pkgsStatic;
      linuxOnlyExtras =
        if isLinux then {
          flags = [
            "--enable-libcaca"
            "--enable-libcdio"
            "--enable-libdrm"
            "--enable-libxcb"
            "--enable-libxcb-shm"
            "--enable-libxcb-xfixes"
            "--enable-libxcb-shape"
          ];
          inputs = with pkgs.pkgsStatic; [
            libcdio      libcdio.dev
            libcdio-paranoia
            libdrm       libdrm.dev
            libxcb       libxcb.dev
          ] ++ [
            libcacaTerm libcacaTerm.dev
            # ALSA with its configuration compiled in and the pulse/pipewire
            # PCM plugin, on the libpulse client it needs (audio.nix).
            # nixpkgs' alsa-lib bakes its own store path as the configuration
            # directory, so every ALSA device failed on a user's machine.
            audio.alsaStatic audio.alsaStatic.dev
            audio.libpulse audio.libpulse.dev
          ];
        } else { flags = [ ]; inputs = [ ]; };
      extras = {
        flags = sharedExtras.flags ++ linuxOnlyExtras.flags;
        inputs = sharedExtras.inputs ++ linuxOnlyExtras.inputs;
      };
    in
    mkFfmpeg pkgs.pkgsStatic ({
      extraConfigureFlags =
        # configure finds pthreads in libSystem by itself on darwin (the
        # shipped binary imports pthread_create and `-threads 4` runs faster
        # than 1).
        (if isDarwin then [ ] else [ "--enable-pthreads" ])
        ++ extras.flags;
      extraInputs = extras.inputs;
      iconv = ulib.darwinIconvCompat {
        pkgs = origPkgs;
        toolchain = ulib.unpinToolchain origPkgs.stdenv.buildPlatform.system;
      };
    } // opts);

  # mingw: force pthreads (not w32threads) to match downstream codec
  # libs (x264, dav1d) that were built against pthreads. Same
  # `sharedExtras` feature set as linux/darwin — the per-package
  # `nativeFixes.X` registry handles mingw quirks transparently.
  windowsWith = opts: pkgs:
    let
      # The native scopes get retargetOpenssl from nix-lib; the mingw one
      # does not, so apply it here (C:/ssl, as the `openssl` package does).
      # Gated on the host: `extend` reaches this scope's buildPackages too,
      # and retargeting the build machine's openssl rebuilds every build
      # tool behind it.
      cross = (ulib.mingwStaticCross pkgs).extend (final: prev: {
        openssl =
          if prev.stdenv.hostPlatform.isWindows
          then prev.openssl.overrideAttrs (ulib.retargetOpenssl "C:/ssl")
          else prev.openssl;
      });
      extras = mkExtras cross;
    in
    mkFfmpeg cross ({
      extraConfigureFlags =
        [ "--disable-w32threads" "--enable-pthreads" ]
        ++ extras.flags;
      extraInputs = [ cross.windows.pthreads ] ++ extras.inputs;
    } // opts);
}
