# nix-lib

Shared Nix helpers for [unpins/*](https://github.com/unpins) packages.

Consumers add this flake as an input and use `unpins-lib.lib.<helper>`:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    unpins-lib.url = "github:unpins/nix-lib";
  };

  outputs = { self, nixpkgs, unpins-lib }: {
    # ... use unpins-lib.lib.staticOnlyAuto etc.
  };
}
```

## Helpers

### System lists

| Helper | Returns |
|---|---|
| `nativeSystems` | `[ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ]` — canonical native targets |
| `forAllNative f` | `{ <system> = f system; ... }` over `nativeSystems` |

### Static-only build knobs

Force a library to install only the static `.a` (no shared `.dll`/`.so`):

| Helper | Build system | Notes |
|---|---|---|
| `staticOnlyAuto` | autotools/libtool | adds `--enable-static --disable-shared`, sets `dontDisableStatic` |
| `staticOnlyMeson` | meson | adds `-Ddefault_library=static` |
| `staticOnlyCmake extras` | cmake | adds `-DBUILD_SHARED_LIBS=OFF` plus caller's extras |

### Cache-aware wrappers

Use these when the same code runs for both `pkgsStatic` (already static) and `pkgsCross.mingwW64` (shared default). They no-op on `isStatic` to preserve cache hits:

| Helper | Wraps |
|---|---|
| `keepStaticAuto pkgs drv` | `staticOnlyAuto` |
| `keepStaticMeson pkgs drv` | `staticOnlyMeson` |
| `keepStaticCmake pkgs extras drv` | `staticOnlyCmake` |
| `keepStaticZlib pkgs drv` | `.override { shared = false; }` |

### Toolchain helpers

| Helper | Returns |
|---|---|
| `crossPrefix pkgs` | `"${triple}-"` for use with ffmpeg's `--cross-prefix=` etc. Both `pkgsStatic` and `pkgsCross.mingwW64` ship cc-wrappers with only prefixed binaries — this gives the right prefix. |

### Cross-mingw wrappers

| Helper | Use |
|---|---|
| `mingwStandalone { pkg, staticDeps, extraInputs, extraConfigureFlags, filterConfigureFlag, extraOverrides }` | Wraps a `pkgsCross.mingwW64.<pkg>` so its produced `.exe` imports only system DLLs. Forces `--disable-shared --enable-static` + `LDFLAGS=-all-static`. Passes `staticDeps` via `.override` (not overlay — preserves toolchain cache). |

### Packaging

| Helper | Use |
|---|---|
| `packageWithMan pkgs name drv` | `symlinkJoin` of `drv.bin` + `drv.man`, strips the binary, preserves passthru |

## Why this exists

Unpins packages target single-binary distribution across Linux/Darwin/Windows. Cross-compiling to mingw and producing a static binary requires a half-dozen non-obvious nixpkgs incantations. Three packages (curl, jq, ffmpeg) discovered the same patterns independently. This flake captures them so the next ffmpeg-class package doesn't re-discover them.

See `feedback_unpins_big_pkgs.md` in private memory for the full playbook.
