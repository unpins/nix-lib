# nix-lib

Shared Nix helpers for the [unpins](https://unpins.org) project — native single-binary builds for Linux, macOS or Windows, with no third-party runtime dependencies.

Consumers add this flake as an input and call `unpins-lib.lib.mkStandaloneFlake`:

```nix
{
  inputs.unpins-lib.url = "github:unpins/nix-lib";

  outputs = { self, unpins-lib }:
    unpins-lib.lib.mkStandaloneFlake {
      inherit self;
      name = "jq";
      windows = true;     # opt in to mingw cross output
    };
}
```

`mkStandaloneFlake` emits `packages.<system>.default` (native `pkgsStatic`) and `apps.<system>.default` for `nix run`. With `windows = true` (or a custom `windowsBuild`), it adds `packages.x86_64-linux."windows-x86_64"` (mingw cross). On `aarch64-darwin` it also emits `packages.aarch64-darwin."darwin-x86_64"` (cross within darwin). The `manifest` attr is read by [action-build](https://github.com/unpins/action-build) for CI.

## Per-package quirks

Most packages need at least one platform-specific tweak (a flag autotools chokes on, a missing pthread dep, a `.pc` file rewrite). These live in the `fixes` registry inside this flake's `flake.nix`, keyed by package name:

```nix
fixes = {
  htop.native          = pkgs: ...;          # native build (branches on isDarwin/isLinux)
  jq.mingw             = pkgs: ...;          # mingw cross build
  libidn2.mingwOverlay = self: super: ...;   # transitive dep, applied as overlay
};
```

`mkStandaloneFlake` looks up `fixes.${name}.{native,mingw}` and uses it, falling back to `pkgs.pkgsStatic.${name}` / `(mingwStaticCross pkgs).${name}` when not registered. Consumer flakes never branch on platform — add a registry entry here instead.

## Customizing the build

When the build is fully custom (curl's Schannel link, vim's `Make_ming.mak`), pass `build` / `windowsBuild` directly:

```nix
mkStandaloneFlake {
  inherit self;
  name = "curl";
  build = pkgs: pkgs.pkgsStatic.curl.override { http3Support = false; };
  windowsBuild = pkgs: unpins-lib.lib.mingwStaticBinary {
    pkg = (unpins-lib.lib.mingwStaticCross pkgs).curl;
    staticDeps = { opensslSupport = false; scpSupport = false; };
    extraConfigureFlags = [ "--with-schannel" ];
    extraCFlags = [ "-DNGHTTP2_STATICLIB" "-DCURL_STATICLIB" "-DPSL_STATIC" ];
  };
}
```

## `mkStandaloneFlake` parameters

| Param              | Default    | Use                                                          |
| ------------------ | ---------- | ------------------------------------------------------------ |
| `self`             | required   | Pass `inherit self;` so `apps` can reference outputs.        |
| `name`             | required   | Package name; key into the `fixes` registry.                 |
| `build`            | `null`     | Custom native build. Falls back to `fixes.${name}.native`.   |
| `windowsBuild`     | `null`     | Custom mingw build. Implies `windows = true`.                |
| `windows`          | `false`    | Opt in to the mingw output without a custom `windowsBuild`.  |
| `nativeBuild`      | `true`     | Set `false` for windows-only packages (gvim).                |
| `binName`          | `name`     | Override when the produced bin name ≠ `name`.                |
| `package_data`     | `true`     | Forwarded into `manifest` for action-build CI.               |
| `bootstrap_naming` | `false`    | Forwarded into `manifest`.                                   |
| `own_software`     | `false`    | Forwarded into `manifest`.                                   |

## Public helpers

| Helper                             | Purpose                                                                          |
| ---------------------------------- | -------------------------------------------------------------------------------- |
| `mkStandaloneFlake { ... }`        | Flake template (see above).                                                      |
| `mingwStaticCross pkgs`            | `pkgs.pkgsCross.mingwW64` with a static-libs stdenv adapter + overlay fixes.     |
| `mingwStaticBinary { pkg, ... }`   | Finalize a mingw binary: `LDFLAGS=-all-static`, strip, thread `staticDeps`.      |
| `dropSharedLibs drv`               | postFixup that strips `.so`/`.dylib`/`.la`/`.dll`/`.dll.a`. No-op on `isStatic`. |
| `withDepsSharedPruned pkgs drv`    | Rebuild `drv` with deps wrapped in `dropSharedLibs`. Darwin tmux fallback.       |
| `packageWithMan pkgs name drv`     | `symlinkJoin` of `drv.bin` + `drv.man`, strips the binary, keeps `passthru`.     |
| `strippedOrJoined pkgs name drv`   | Single `result` for both single- and multi-output drvs (strip vs join).          |
| `nativeSystems`                    | `[ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ]`.           |
| `forAllNative f`                   | `{ <system> = f system; ... }` over `nativeSystems`. Pure Nix.                   |

## Why this exists

unpins ships single binaries that bundle every third-party dependency — no companion DLLs, no `/nix/store` closure, only the OS's own libraries on the dynamic-link side. Cross-compiling to mingw and getting truly DLL-free `.exe` output takes a half-dozen non-obvious nixpkgs incantations: libtool `-all-static`, `__declspec(dllimport)` `*_STATICLIB` defines, `.pc` file rewrites for `libpsl`/`libidn2`, and avoiding `pkgsCross.mingwW64.pkgsStatic` (rebuilds the cross toolchain for byte-identical output). Multiple packages discovered the same patterns independently. This flake captures them, and the `fixes` registry stores the per-package exceptions so consumer flakes stay short (~20 lines).
