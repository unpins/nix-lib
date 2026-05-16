# Strip terminfo from the mingw ncurses build.
#
# Why: ncurses on Windows ships two drivers (selected at runtime by
# `--enable-term-driver`): `tinfo` for terminfo-backed terminals and
# `win32console` for the Windows Console API. The win32console driver
# talks `WriteConsoleW` / `SetConsoleMode` / `ReadConsoleInputA` directly —
# no terminal description needed, the Console API is the contract.
#
# By default nixpkgs builds the mingw ncurses with the terminfo database
# baked at `/nix/store/.../share/terminfo` and configures the runtime to
# pick the tinfo driver whenever `TERM` matches a known entry. Users
# running our binaries under Git Bash or MSYS2 inherit `TERM=xterm-256color`
# and ncurses falls into the tinfo path, fails to find the nix store path,
# and degrades.
#
# `--disable-database` removes the terminfo lookup machinery entirely;
# `--with-fallbacks=` (empty) leaves no baked entries either, so the tinfo
# driver returns "unknown terminal" for any TERM value. ncurses then
# always selects the win32console driver regardless of the user's TERM
# env var — the behavior we want, since the Windows Console behavior is
# fixed and doesn't need parameterized descriptions.
#
# Knock-on: nano.exe stops carrying the `TERMINFO` / `TERMINFO_DIRS` /
# `/nix/store/.../share/terminfo` strings, and works identically under
# cmd, PowerShell, Windows Terminal, conhost, AND msys2 shells.
{ lib }:
self: super:
super.ncurses.overrideAttrs (old: {
  configureFlags = (old.configureFlags or [ ]) ++ [
    # No external terminfo database — every supported entry is baked into
    # libtinfo via --with-fallbacks. Runtime lookups consult `_nc_fallback[]`
    # arrays compiled into the static archive; no file I/O, no env-var path
    # mismatch when the binary is dropped onto a user's Windows machine.
    "--disable-database"
    # Curated for terminals that actually exist on Windows. Default consoles
    # (cmd / PowerShell / conhost / Windows Terminal) set no TERM and route
    # through the win32console driver, so no entry is needed for them — the
    # list below covers the cases where a shell DOES export TERM:
    #
    #   xterm, xterm-256color  default for mintty (Git Bash, MSYS2, Cygwin),
    #                           VS Code integrated terminal, ConEmu/Cmder,
    #                           Windows Terminal-with-MSYS-shell. Universal
    #                           fallback whenever a unix-style shell is on
    #                           top of a Windows console.
    #   mintty                 explicit; mintty sets TERM=mintty rarely but
    #                           some configs use it.
    #   cygwin                 Cygwin's legacy non-mintty terminal.
    #   ms-terminal            Windows Terminal users who manually export it.
    #   vscode                 VS Code shell-integration mode.
    #   ansi, vt100, vt220     legacy baselines; SSH clients still emit them.
    #   dumb                   ncurses fallback for pipes/non-tty output.
    #
    # Plus the multiplexer entries — screen and tmux don't ship for Windows
    # today but unpins has them on the port roadmap, and if they land users
    # will set TERM=screen-256color / tmux-256color inside the multiplexer.
    #
    # Skipped on purpose: kitty/foot/iterm/iterm2/gnome/konsole (no native
    # Windows builds), alacritty/wezterm (Windows builds exist but ship their
    # own terminfo and the user population is small), rxvt (needs a Unix
    # runtime to be the active terminal at all).
    "--with-fallbacks=xterm,xterm-256color,mintty,cygwin,ms-terminal,vscode,screen,screen-256color,tmux,tmux-256color,ansi,vt100,vt220,dumb"
  ];
})
