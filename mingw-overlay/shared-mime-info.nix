# shared-mime-info on mingw: `src/meson.build`'s two test executables
# (`install: false`) link `libintl.a`, which needs `-liconv` that
# neither the libiconv setup-hook nor explicit `NIX_LDFLAGS` injects
# into meson's link recipe here. The tests aren't installed and we run
# none, so rewrite `src/meson.build` to keep only update-mime-database
# (which links clean — gettext's hook injects `-lintl` for it).
{ lib }:
self: super:
super.shared-mime-info.overrideAttrs (old: {
  postPatch = (old.postPatch or "") + ''
    cat > src/meson.build <<'EOF'
    configure_file(
        output: 'config.h',
        configuration: config,
    )

    update_mime_database = executable('update-mime-database',
        'update-mime-database.cpp',
        dependencies: [
            glib2,
            libxml,
        ],
        install: true,
    )
    EOF
  '';
})
