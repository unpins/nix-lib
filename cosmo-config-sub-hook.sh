# Setup hook: teach autoconf's `config.sub` about cosmo-gnu before
# configure runs. Without this, every autotools package fails with:
#   Invalid configuration 'x86_64-unknown-cosmo-gnu':
#   Kernel 'cosmo' not known to work with OS 'gnu'.
#
# Runs as a preConfigureHook so it patches whatever config.sub is on
# disk at that point — covers both (a) the package's bundled config.sub
# and (b) the gnu-config-substituted one from updateAutotoolsGnuConfigScriptsHook
# (which runs in patchPhase, earlier).
#
# We avoid patching the gnu-config derivation itself (which would change
# its drv hash and cascade-rebuild every consumer through xgcc bootstrap).
# Patching the source tree on disk during the build is contained.
patchCosmoConfigSub() {
    local cs
    for cs in $(find . -name config.sub -type f 2>/dev/null); do
        if [ -w "$cs" ] || chmod u+w "$cs"; then
            if ! grep -q 'cosmo\*' "$cs"; then
                sed -i 's/| ironclad\* )/| ironclad* | cosmo* )/' "$cs"
            fi
            if ! grep -q 'cosmo-gnu\*-' "$cs"; then
                sed -i '/uclinux-uclibc\*- )/i\	cosmo-gnu*- )\n\t\t;;' "$cs"
            fi
        fi
    done
}

preConfigureHooks+=(patchCosmoConfigSub)
