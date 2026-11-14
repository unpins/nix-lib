# tzdata's `make check` ends in `now.ck`, which compares every zone against
# zonenow.tab from the build's wall clock (`./date +%s`): a release goes red
# once a zone's future rules diverge from its stale table, with nothing about
# the build changed. 2026c failed it from 2026-11 ("America/Phoenix and
# America/Vancouver identical from now on"). Run the rest of `check`;
# drop this when nixpkgs ships a tzdata whose zonenow.tab is current.
{ lib }:
{
  autoWire = "static";
  apply = pkgs: pkgs.tzdata.overrideAttrs (_: { checkTarget = "check_mild back.ck"; });
}
