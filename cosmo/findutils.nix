# findutils via mkPkgsCosmo for Windows-x86_64 (mingw blocked: pulls
# coreutils-x86_64-w64-mingw32 as a nativeBuildInputs dep and coreutils
# on mingw dies in gnulib `lib/savewd.c` on `waitpid`).
#
# Same multicall recipe as nix-lib/native/findutils.nix: rename main →
# {find,xargs}_main on each tool's object, ship a dispatcher.o, link
# them with libfindtools.a + lib/libfind.a + gl/lib/libgnulib.a. cosmocc
# uses ELF binutils + apelink in postFixup to produce findutils.exe.
{ lib }:
final: prev:
let
  cs = import ../cosmocc.nix { pkgs = final.buildPackages; };

  dispatcherC = ''
    #include <string.h>
    #include <stdio.h>
    #include <strings.h>

    int find_main(int argc, char *argv[]);
    int xargs_main(int argc, char *argv[]);

    int main(int argc, char *argv[])
    {
        const char *name = argv[0];
        const char *slash = strrchr(name, '/');
        if (slash) name = slash + 1;

        static char buf[256];
        size_t len = strlen(name);
        if (len > 4 && !strcasecmp(name + len - 4, ".exe")) {
            if (len - 4 >= sizeof(buf)) return 1;
            memcpy(buf, name, len - 4);
            buf[len - 4] = 0;
            name = buf;
        }
        if (strncmp(name, "lt-", 3) == 0) name += 3;

        if (strcmp(name, "findutils") == 0 && argc >= 2 && argv[1][0] != '-') {
            name = argv[1];
            argv++;
            argc--;
        }

        if (strcmp(name, "find") == 0)  return find_main(argc, argv);
        if (strcmp(name, "xargs") == 0) return xargs_main(argc, argv);

        /* Default route: --version, --help, and binaries renamed by
           the CI smoke step (smoke.exe) land in find. find's getopt
           handles --version regardless of argv[0]. */
        return find_main(argc, argv);
    }
  '';

  multicallMk = final.buildPackages.writeText "unpin-multicall.mk" ''
    MULTI_OUT ?= $(top_builddir)/multicall/findutils

    .PHONY: multicall-link
    multicall-link: $(MULTI_OUT)

    $(MULTI_OUT): \
        $(top_builddir)/multicall/dispatcher.o \
        $(top_builddir)/find/ftsfind.o.renamed \
        $(top_builddir)/xargs/xargs.o.renamed \
        libfindtools.a \
        $(top_builddir)/lib/libfind.a \
        $(top_builddir)/gl/lib/libgnulib.a
    	$(CC) $(ALL_LDFLAGS) -o $@ \
    		$(top_builddir)/multicall/dispatcher.o \
    		$(top_builddir)/find/ftsfind.o.renamed \
    		$(top_builddir)/xargs/xargs.o.renamed \
    		libfindtools.a \
    		$(top_builddir)/lib/libfind.a \
    		$(top_builddir)/gl/lib/libgnulib.a \
    		$(LIBINTL) $(LIB_CLOCK_GETTIME) $(LIB_EACCESS) $(LIB_SELINUX) \
    		$(LIB_CLOSE) $(MODF_LIBM) $(FINDLIBS) $(GETHOSTNAME_LIB) \
    		$(LIB_SETLOCALE_NULL) $(LIB_MBRTOWC)
  '';

  appletAliases = [ "find" "xargs" ];
in
if (prev.stdenv.hostPlatform.isCosmo or false) then {
  findutils =
    let
      patched = prev.findutils.overrideAttrs (oa: {
        pname = "findutils-multi";

        # cosmo's <stdint.h> defines __STDC_LIMIT_MACROS as empty
        # (the C99-style guard, not a value). xargs.c uses
        # `(void) __STDC_LIMIT_MACROS;` to silence an unused-define
        # warning — with the empty macro that becomes `(void) ;`, a
        # parse error. Replace with `(void) 0;`, same semantics.
        postPatch = (oa.postPatch or "") + ''
          substituteInPlace xargs/xargs.c \
            --replace-fail '(void) __STDC_LIMIT_MACROS;' '(void) 0;'
        '';

        postBuild = (oa.postBuild or "") + ''
          mkdir -p multicall
          cat > multicall/dispatcher.c <<'DISPATCHER_EOF'
${dispatcherC}
DISPATCHER_EOF
          $CC -O2 -c -o multicall/dispatcher.o multicall/dispatcher.c

          cp find/ftsfind.o find/ftsfind.o.renamed
          cp xargs/xargs.o  xargs/xargs.o.renamed
          $OBJCOPY --redefine-sym main=find_main  find/ftsfind.o.renamed
          $OBJCOPY --redefine-sym main=xargs_main xargs/xargs.o.renamed

          install -m644 ${multicallMk} find/unpin-multicall.mk
          make -C find -f Makefile -f unpin-multicall.mk multicall-link
        '';

        postInstall = (oa.postInstall or "") + ''
          rm -f $out/bin/find $out/bin/xargs
          install -m755 multicall/findutils $out/bin/findutils
        '';

        postFixup = (oa.postFixup or "") + ''
          ${cs.cosmocc}/bin/apelink \
            -V ${toString cs.platformBits.windows} \
            -o $out/bin/findutils.exe \
            $out/bin/findutils
          rm -f $out/bin/findutils
        '';
      });
    in
    lib.withAliases final
      {
        primary = "findutils.exe";
        aliases = appletAliases;
      }
      patched;
} else { }
