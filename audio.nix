# Static audio for the catalog: a libao that compiles its backends INTO libao.a
# as built-in drivers (ogg123, sox), and the alsa-lib + libpulse client it is
# built on, which ffmpeg's ALSA devices use too. No dlopen anywhere.
#
# Upstream libao ships each backend as a libtool `.la` loadable module dlopen'd
# at runtime from lib/ao/plugins-4/. Under static musl/mingw, dlopen is a no-op
# (audio_out.c stubs it), so only the compiled-in `static_drivers[]` table is
# reachable. We therefore wrap each backend's plugin source — renaming its
# generic `ao_plugin_*` exports to `ao_<drv>_*` (so several co-link without
# colliding), #including the source, and synthesising the built-in
# `ao_functions ao_<drv>` table — add it to libao_la_SOURCES, and register it in
# static_drivers[]. Selection is by ao_info.priority: pulse(50) > alsa(35) >
# oss(20) on Linux; macosx(30) on Darwin. (Windows uses libao's already-built-in
# WMM driver — no surgery — handled in flake.nix's mingw path.)
#
#   Linux  : pulse (socket→pipewire/pulse daemon) + alsa (hw/dmix) + oss (/dev/dsp)
#   Darwin : macosx (CoreAudio), linking the system AudioUnit/CoreAudio frameworks
#
# `ps` is a pkgsStatic-like scope (the native target). Returns the libao deriv.
{ lib }:
ps:
let
  isDarwin = ps.stdenv.hostPlatform.isDarwin or false;

  # ---- static libpulse client (Linux) -------------------------------------
  # daemon/dbus/glib/oss-output off + shared_library→library so the client libs build as .a under the static
  # crt. Talks the native protocol over the unix socket; no dlopen, no daemon.
  libpulse = ps.libpulseaudio.overrideAttrs (o: {
    meta = (o.meta or { }) // { badPlatforms = [ ]; };
    mesonFlags = (o.mesonFlags or [ ]) ++ [
      "-Dclient=true"
      "-Ddaemon=false"
      "-Dtests=false"
      "-Doss-output=disabled"
      "-Ddbus=disabled"
      "-Dglib=disabled"
    ];
    postPatch = (o.postPatch or "") + ''
      substituteInPlace src/meson.build \
        --replace-fail "libpulsecommon = shared_library(" "libpulsecommon = library("
      substituteInPlace src/pulse/meson.build \
        --replace-fail "libpulse = shared_library(" "libpulse = library(" \
        --replace-fail "libpulse_simple = shared_library(" "libpulse_simple = library(" \
        --replace-fail "libpulse_mainloop_glib = shared_library(" "libpulse_mainloop_glib = library("
    '';
  });

  # ---- static "pipewire" ALSA plugin, served over the pulse-compat socket ---
  #
  # The hard problem: a PipeWire (or PulseAudio) desktop reconfigures ALSA's
  # `pcm.!default` to `type pipewire` (see /etc/alsa/conf.d/99-pipewire-default).
  # alsa-lib has no built-in `pipewire` type, so snd_pcm_open_conf() synthesises
  # the module name `libasound_module_pcm_pipewire.so` and snd_dlopen()s it —
  # dead under static musl, and the native plugin would drag libpipewire (which
  # dlopen's SPA modules anyway). So libao's alsa driver, opening `default`,
  # hits a dlopen wall on exactly the machines people run.
  #
  # We honour the machine config (`default → pipewire`) but service the
  # `pipewire` type STATICALLY, with zero dlopen, by routing it through the
  # pulse-compat protocol — the very socket the proven static libpulse client
  # already talks to (pipewire-pulse / PulseAudio). Two facts from alsa-lib make
  # this work without touching any config on disk:
  #
  #   1. snd_pcm_open_conf() only synthesises a `.so` name (→ dlopen) when the
  #      type is ABSENT from its compiled-in `build_in_pcms[]` list. Add
  #      "pipewire"/"pulse" to that array and `lib` stays NULL → snd_dlopen(NULL)
  #      → the static symbol table (`snd_dlsym_start`, live because pkgsStatic
  #      builds alsa-lib non-PIC), never dlopen.
  #   2. A plugin registers into that table via the SND_PCM_PLUGIN_SYMBOL
  #      constructor (`_snd_pcm_<type>_open`). We compile alsa-plugins' pulse
  #      module (needs only libpulse — no libpipewire/SPA) and a glue TU that
  #      aliases `_snd_pcm_pipewire_open → _snd_pcm_pulse_open`, then `ar` both
  #      into libasound.a. A `_snd_module_pcm_pulse` anchor referenced from
  #      pcm_symbols.c's open-objects array force-links the constructors.
  #
  # The pipewire `pcm.!default` carries `playback_node`/`capture_node` fields the
  # pulse plugin doesn't know; we make its config loop ignore unknown fields,
  # and the glue drops `server` (a PipeWire socket name, not a pulse one). Net:
  # `default → pipewire` resolves to a static symbol that reaches the SAME
  # PipeWire daemon, no dlopen, machine routing untouched. Linux-only.
  alsaPluginsSrc = ps.alsa-plugins.src;

  glueC = ps.writeText "pcm_pipewire_glue.c" ''
    #include <alsa/asoundlib.h>
    #include <alsa/pcm_external.h>

    extern int _snd_pcm_pulse_open(snd_pcm_t **, const char *, snd_config_t *,
                                   snd_config_t *, snd_pcm_stream_t, int);

    /* The machine routes default → `type pipewire`; service it via the
       pulse-compat protocol (same PipeWire daemon), statically, no dlopen.
       The consumer's source references _snd_pcm_pipewire_open, which
       pulls this TU and — via the ref below — pcm_pulse.o, running both
       SND_PCM_PLUGIN_SYMBOL constructors so each registers in snd_dlsym_start. */
    int _snd_pcm_pipewire_open(snd_pcm_t **pcmp, const char *name,
                               snd_config_t *root, snd_config_t *conf,
                               snd_pcm_stream_t stream, int mode) {
        /* A pipewire `server` names a PipeWire socket (`pcm.pipewire` passes
           "pipewire-0"), not a pulse server: drop it so the plugin connects
           to the default pulse socket. The plugin reads conf only during open. */
        snd_config_t *copy, *server;
        int err = snd_config_copy(&copy, conf);
        if (err < 0)
            return err;
        if (snd_config_search(copy, "server", &server) >= 0)
            snd_config_delete(server);
        err = _snd_pcm_pulse_open(pcmp, name, root, copy, stream, mode);
        snd_config_delete(copy);
        return err;
    }
    SND_PCM_PLUGIN_SYMBOL(pipewire);
  '';

  # ---- ALSA configuration compiled into libasound (Linux) -------------------
  # ALSA_CONFIG_DIR is set to this path, which exists on no disk. alsa-lib
  # reaches its configuration files through three calls — fopen (input.c),
  # stat64 and access (conf.c) — and those are redirected here: a path under
  # the directory is answered from the arrays generated from src/conf; any
  # other path (/etc/asound.conf, ~/.asoundrc, …) goes to the real call.
  # ALSA_CONFIG_DIR / ALSA_CONFIG_PATH in the environment still override it.
  alsaBuiltinDir = "/__unpins_alsa__";
  alsaBuiltinC = ps.writeText "unpin_alsa_builtin.h" ''
    /* unpins: ALSA's configuration tree, compiled in (see audio.nix). */
    #include <errno.h>
    #include <stdio.h>
    #include <string.h>
    #include <unistd.h>

    struct unpin_alsa_conf {
    	const char *name;
    	const unsigned char *data;
    	size_t len;
    };

    #include "unpin_alsa_conf.h"

    static const struct unpin_alsa_conf *unpin_alsa_builtin(const char *path)
    {
    	const char *dir = ALSA_CONFIG_DIR;
    	size_t i, n = strlen(dir);

    	if (strncmp(path, dir, n) != 0 || path[n] != '/')
    		return NULL;
    	path += n;
    	while (*path == '/')
    		path++;
    	for (i = 0; i < sizeof(unpin_alsa_confs) / sizeof(unpin_alsa_confs[0]); i++)
    		if (strcmp(path, unpin_alsa_confs[i].name) == 0)
    			return &unpin_alsa_confs[i];
    	return NULL;
    }

    FILE *_snd_unpin_conf_fopen(const char *path, const char *mode)
    {
    	const struct unpin_alsa_conf *c = unpin_alsa_builtin(path);

    	if (!c)
    		return fopen(path, mode);
    	if (mode[0] != 'r' || strchr(mode, '+')) {
    		errno = EROFS;
    		return NULL;
    	}
    	return fmemopen((void *)c->data, c->len, "r");
    }

    static int unpin_alsa_stat64(const char *path, struct stat64 *st)
    {
    	const struct unpin_alsa_conf *c = unpin_alsa_builtin(path);

    	if (!c)
    		return stat64(path, st);
    	memset(st, 0, sizeof(*st));
    	st->st_mode = S_IFREG | 0444;
    	st->st_size = c->len;
    	st->st_ino = (c - unpin_alsa_confs) + 1;
    	return 0;
    }

    static int unpin_alsa_access(const char *path, int mode)
    {
    	if (!unpin_alsa_builtin(path))
    		return access(path, mode);
    	if (mode & (W_OK | X_OK)) {
    		errno = EACCES;
    		return -1;
    	}
    	return 0;
    }
  '';

  alsaStatic =
    if isDarwin then ps.alsa-lib
    else ps.alsa-lib.overrideAttrs (o: {
      buildInputs = (o.buildInputs or [ ]) ++ [ libpulse libpulse.dev ];
      # Compile ALSA's configuration tree (alsa.conf, cards/, pcm/, ctl/) into
      # libasound. The default config dir is this derivation's own share/alsa —
      # a store path no user machine has — so every ALSA open (sox's `rec`, and `play`
      # whenever libao picks its alsa driver) failed with "Cannot access file
      # …/alsa.conf" and "Unknown PCM default". Pointing it at the distro's
      # /usr/share/alsa would only move the dependency (containers and minimal
      # systems don't have it, and its version needn't match this alsa-lib). So
      # the config dir is a directory no disk has, and every file under it is
      # served from memory (unpin_alsa_builtin.h). The embedded alsa.conf still
      # loads the machine's own settings — /etc/asound.conf, /etc/alsa/conf.d,
      # ~/.asoundrc — from disk. The files still install into $out.
      configureFlags = (o.configureFlags or [ ]) ++ [ "--with-configdir=${alsaBuiltinDir}" ];
      installFlags = (o.installFlags or [ ]) ++ [ "alsaconfigdir=${builtins.placeholder "out"}/share/alsa" ];
      postPatch = (o.postPatch or "") + ''
        echo "unpins: compiling the ALSA configuration into libasound"
        files=$(cd src/conf && find . -name '*.conf' | sed 's|^\./||' | LC_ALL=C sort)
        [ "$(printf '%s\n' "$files" | grep -c '^alsa.conf$')" = 1 ] || { echo "unpins: src/conf/alsa.conf not found"; exit 1; }
        {
          i=0
          for f in $files; do
            echo "static const unsigned char unpin_alsa_conf_$i[] = {"
            od -An -v -tx1 "src/conf/$f" | sed 's/ *\([0-9a-f][0-9a-f]\)/0x\1,/g'
            echo "};"
            i=$((i + 1))
          done
          echo "static const struct unpin_alsa_conf unpin_alsa_confs[] = {"
          i=0
          for f in $files; do
            echo "	{ \"$f\", unpin_alsa_conf_$i, sizeof(unpin_alsa_conf_$i) },"
            i=$((i + 1))
          done
          echo "};"
        } > src/unpin_alsa_conf.h
        echo "unpins: $(printf '%s\n' "$files" | wc -l) configuration files embedded"
        cp ${alsaBuiltinC} src/unpin_alsa_builtin.h
        substituteInPlace src/conf.c \
          --replace-fail '#include <locale.h>' '#include <locale.h>
        #include "unpin_alsa_builtin.h"' \
          --replace-fail 'if (!errors && access(fn, R_OK) < 0)' 'if (!errors && unpin_alsa_access(fn, R_OK) < 0)' \
          --replace-fail 'if (stat64(fn, &st) < 0) {' 'if (unpin_alsa_stat64(fn, &st) < 0) {' \
          --replace-fail 'if (stat64(lf->name, &st) >= 0) {' 'if (unpin_alsa_stat64(lf->name, &st) >= 0) {'
        substituteInPlace src/input.c \
          --replace-fail '#include <unistd.h>' '#include <unistd.h>
        FILE *_snd_unpin_conf_fopen(const char *path, const char *mode);' \
          --replace-fail 'FILE *fp = fopen(file, mode);' 'FILE *fp = _snd_unpin_conf_fopen(file, mode);'

        # Make pulse/pipewire build-in pcm types: snd_pcm_open_conf() then leaves
        # `lib` NULL (no synthesised module name) → snd_dlopen(NULL) → the static
        # symbol table is consulted, and snd_dlopen() of a `.so` never happens.
        substituteInPlace src/pcm/pcm.c \
          --replace-fail \
            '"adpcm", "alaw", "copy", "dmix",' \
            '"pulse", "pipewire", "adpcm", "alaw", "copy", "dmix",'
      '';
      # Compile alsa-plugins' pulse module + the pipewire-alias glue non-PIC and
      # ar them into the just-built static libasound.a. In-tree `include/alsa`
      # is a `.` symlink (configure), so <alsa/...> resolves with -Iinclude.
      postBuild = (o.postBuild or "") + ''
        echo "unpins: baking static pulse-compat ALSA plugin into libasound.a"
        asrc=$PWD
        arch=$(find "$asrc" -name libasound.a -path '*/.libs/*' | head -1)
        [ -n "$arch" ] || { echo "unpins: libasound.a not found"; exit 1; }
        plug=$(mktemp -d)
        tar xf ${alsaPluginsSrc} -C "$plug" --strip-components=1
        cd "$plug/pulse"
        # Ignore config fields the pulse plugin doesn't know (pipewire's
        # playback_node/capture_node); the trailing return becomes dead code.
        substituteInPlace pcm_pulse.c \
          --replace-fail 'SNDERR("Unknown field %s", id);' 'continue;'
        cp ${glueC} pcm_pipewire_glue.c
        for f in pcm_pulse.c pulse.c pcm_pipewire_glue.c; do
          echo "unpins: CC $f"
          $CC -D_GNU_SOURCE -I"$asrc/include" -c "$f" -o "''${f%.c}.o"
        done
        $AR r "$arch" pcm_pulse.o pulse.o pcm_pipewire_glue.o
        ''${RANLIB:-ranlib} "$arch"
        cd "$asrc"
      '';
      # libasound.a now pulls pa_* symbols → a static consumer must link libpulse.
      # (The plugin objects are force-pulled by libao's alsa wrapper referencing
      # _snd_pcm_pipewire_open — see the audio_out.c force-ref below — so this
      # works for every libao consumer regardless of its own link flags.)
      postInstall = (o.postInstall or "") + ''
        pc=$(find "''${dev:-$out}" "$out" -name alsa.pc 2>/dev/null | head -1)
        [ -n "$pc" ] && substituteInPlace "$pc" \
          --replace-fail 'Libs.private: -lm -lpthread -lrt' \
            'Libs.private: -lm -lpthread -lrt
      Requires.private: libpulse'
      '';
    });

  # ---- built-in-driver wrapper generator ----------------------------------
  baseSyms = [
    "test"
    "driver_info"
    "device_init"
    "set_option"
    "open"
    "play"
    "close"
    "device_clear"
    "file_extension"
  ];
  # `drv` = plugin dir/file stem; `syms` = the ao_plugin_* names it defines.
  mkWrap = drv: syms: ps.writeText "ao_${drv}_static.c" (
    (lib.concatMapStrings (s: "#define ao_plugin_${s} ao_${drv}_${s}\n") syms)
    + ''
      #include "plugins/${drv}/ao_${drv}.c"
      ao_functions ao_${drv} = {
        ao_${drv}_test, ao_${drv}_driver_info, ao_${drv}_device_init,
        ao_${drv}_set_option, ao_${drv}_open, ao_${drv}_play,
        ao_${drv}_close, ao_${drv}_device_clear, 0
      };
    ''
  );

  # Per-platform driver list (each: name → the ao_plugin_* symbols it defines).
  drivers =
    if isDarwin then [
      { name = "macosx"; syms = baseSyms; }
    ] else [
      { name = "pulse"; syms = baseSyms; }
      { name = "alsa"; syms = baseSyms ++ [ "playi" ]; }
      { name = "oss"; syms = baseSyms; }
    ];

  wrapFiles = lib.concatMapStringsSep "\n"
    (d: "cp ${mkWrap d.name d.syms} src/ao_${d.name}_static.c")
    drivers;
  wrapSourceList = lib.concatMapStringsSep " " (d: "ao_${d.name}_static.c") drivers;
  externLine = lib.concatMapStrings (d: "extern ao_functions ao_${d.name}; ") drivers;
  arrayEntries = lib.concatMapStrings (d: "\n    \t&ao_${d.name},") drivers;

  # ao.pc additions so a static consumer (sox/vorbis-tools' configure → pkg-config)
  # resolves the backend closure. Linux: Requires.private chains libpulse/alsa.
  # Darwin: the CoreAudio frameworks ride in Libs.private.
  pcEdit =
    if isDarwin then ''
      substituteInPlace ao.pc.in \
        --replace-fail "Libs.private: @LIBS@" \
          "Libs.private: @LIBS@ -framework AudioUnit -framework CoreAudio -framework CoreServices"
    '' else ''
      substituteInPlace ao.pc.in \
        --replace-fail "Conflicts:" "Requires.private: libpulse-simple libpulse alsa
      Conflicts:"
    '';

  extraConfigure = lib.optionals (!isDarwin) [ "--enable-pulse" ];
  # On Linux, ao.pc's Requires.private needs libpulse/alsa .pc reachable in the
  # consumer's PKG_CONFIG_PATH; pkgsStatic only auto-propagates `out` (the .pc is
  # in `.dev`) → propagate .dev explicitly (the pkgsStatic-multi-output trap).
  # alsaStatic (not ps.alsa-lib) is the one carrying the baked-in pipewire plugin.
  extraPropagated = lib.optionals (!isDarwin) [
    libpulse
    libpulse.dev
    alsaStatic
    alsaStatic.dev
  ];
  extraBuildInputs = lib.optionals (!isDarwin) [ libpulse libpulse.dev ];
in
(ps.libao.override (lib.optionalAttrs (!isDarwin) { alsa-lib = alsaStatic; })).overrideAttrs (o: {
  # Expose the pipewire-static alsa-lib so the consumer (sox/vorbis-tools) can
  # point its OWN native alsa backend at the SAME libasound.a — otherwise the
  # app drags a second, vanilla alsa-lib whose `default` still dlopen-fails.
  # The static libpulse is exposed too, so a consumer with its own pulse backend
  # (sox) links the same client libao does, and the engine self-fold can name
  # its nested `lib/pulseaudio/libpulsecommon-<ver>.a`, which the auto dep glob
  # (lib/*.a) misses (`pulseCommonArchive`). null on Darwin (no pulse).
  passthru = (o.passthru or { }) // { inherit alsaStatic; }
    // lib.optionalAttrs (!isDarwin) { inherit libpulse; };
  buildInputs = (o.buildInputs or [ ]) ++ extraBuildInputs;
  propagatedBuildInputs = (o.propagatedBuildInputs or [ ]) ++ extraPropagated;
  # Drop nixpkgs' --enable-alsa-mmap: it makes the alsa driver request
  # SND_PCM_ACCESS_MMAP_INTERLEAVED, which the pulse-compat ioplug (our static
  # `pipewire` path) does NOT support → snd_pcm_hw_params_set_access fails with
  # EIO. Plain RW_INTERLEAVED (the non-mmap default) works on the ioplug AND on
  # real hardware (hw/dmix), so it's the universally safe access mode. The
  # runtime `use_mmap` option is still there for bare-metal users who want it.
  configureFlags = (lib.filter (f: f != "--enable-alsa-mmap") (o.configureFlags or [ ]))
    ++ extraConfigure;
  meta = (o.meta or { }) // { platforms = lib.platforms.all; broken = false; };
  postPatch = (o.postPatch or "") + ''
    ${wrapFiles}
    ${lib.optionalString (!isDarwin) ''
      # Force-link the baked-in static pulse/pipewire plugin: ao_alsa_static.o is
      # always pulled (its ao_alsa table is in static_drivers[]), so a reference
      # here drags the plugin's glue + pcm_pulse objects out of libasound.a,
      # running their SND_PCM_PLUGIN_SYMBOL constructors at startup. This is what
      # makes `default → type pipewire` resolve to a static symbol — for ANY
      # libao consumer (ogg123, sox), no per-consumer link flag needed.
      chmod u+w src/ao_alsa_static.c
      printf '%s\n' \
        'extern int _snd_pcm_pipewire_open(void);' \
        'void *const _ao_unpin_force_pipewire = (void *)&_snd_pcm_pipewire_open;' \
        >> src/ao_alsa_static.c
    ''}

    substituteInPlace src/Makefile.am \
      --replace-fail \
        "libao_la_SOURCES = audio_out.c config.c ao_null.c ao_wav.c ao_au.c ao_raw.c ao_aixs.c \$(wmm)" \
        "libao_la_SOURCES = audio_out.c config.c ao_null.c ao_wav.c ao_au.c ao_raw.c ao_aixs.c \$(wmm) ${wrapSourceList}"

    substituteInPlace src/audio_out.c \
      --replace-fail \
        "static ao_functions *static_drivers[] = {" \
        "${externLine}static ao_functions *static_drivers[] = {${arrayEntries}"

    ${pcEdit}
  '';
})
