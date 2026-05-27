# shared-mime-info on mingw: `src/meson.build` builds two test
# executables — `test-subclassing` and `tree-magic` (declared
# `install: false`, only consumed by `meson test`). Both link
# `libintl.a` from gettext which needs `libiconv_open`/`libiconv`
# from libiconv; nixpkgs' libiconv setup-hook fails to inject
# `-liconv` here (libiconv only reaches us as a transitive
# propagated input via glib), and setting `NIX_LDFLAGS += -liconv`
# explicitly doesn't survive meson's link recipe either. Since
# these binaries aren't installed and we run no tests, rewrite
# `src/meson.build` to keep only the installed binary
# (`update-mime-database.exe`, which links clean because
# gettext's setup-hook injects `-lintl` for it).
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
