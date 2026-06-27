# Shared fallback-terminfo machinery for ncurses, used by all three platform
# overlays (native-overlay/ncurses.nix, cosmo/ncurses.nix, mingw-overlay/
# ncurses.nix) and reexported through `lib` for the non-engine / darwin consumer
# flakes that still wrap ncurses by hand. Kept in one file so the curated
# terminal list and the two embed variants live together, with no overlay
# depending on another overlay's file.
rec {
  # Curated terminfo entries baked into libtinfo.a via ncurses
  # `--with-fallbacks=`. We can't assume `/usr/share/terminfo` exists on the
  # host (scratch containers, raw Windows), so embedding ~35 essentials keeps
  # libedit / ncurses-TUI consumers working with zero data files. See
  # docs/runtime-data.md for the complete-coverage path (not yet wired).
  # Entries ncurses 6.6 doesn't ship (`xterm-ghostty`, `xterm-kitty`,
  # `rxvt-unicode*`) come from `extra-terminfo.src`; the `xterm-…` aliases
  # are the $TERM names Ghostty/kitty set by default (ncurses' own entries
  # lack those aliases).
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

  # Patch ncurses to append `extra-terminfo.src` (so newer entries are
  # known to tic) and `--with-fallbacks=` (compile each into libtinfo.a as a
  # C array). Host terminfo still wins at runtime (database lookup stays on).
  embedFallbackTerminfo = ncurses: ncurses.overrideAttrs (oa: {
    postPatch = (oa.postPatch or "") + ''
      cat ${./extra-terminfo.src} >> misc/terminfo.src
    '';
    configureFlags = (oa.configureFlags or [ ]) ++ [
      "--with-fallbacks=${fallbackTerminals}"
    ];
  });

  # embedFallbackTerminfo + `--disable-database` (no runtime path lookup).
  # For Windows (cosmo, mingw): the compiled-in /nix/store terminfo path
  # doesn't exist on the user's machine and there's no system convention, so
  # the baked array is the only source of truth.
  embedFallbackTerminfoOnly = ncurses: ncurses.overrideAttrs (oa: {
    postPatch = (oa.postPatch or "") + ''
      cat ${./extra-terminfo.src} >> misc/terminfo.src
    '';
    configureFlags = (oa.configureFlags or [ ]) ++ [
      "--disable-database"
      "--with-fallbacks=${fallbackTerminals}"
    ];
  });
}
