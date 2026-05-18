# Upstream findutils is two binaries: find/find (from ftsfind.c + libfindtools.a)
# and xargs/xargs (from xargs.c). To honour the unpins one-pkg-one-bin rule we
# post-link them into a single multicall ELF/Mach-O.
#
# Why a post-link route: each tool keeps its own `int main()`. find depends on
# find/libfindtools.a (parser.o, pred.o, tree.o, …), both depend on lib/libfind.a
# + gl/lib/libgnulib.a. The cleanest path is:
#
#   1. Let `make` run upstream normally → find/find, xargs/xargs both built.
#      All .o files land in find/ and xargs/, archives in find/, lib/, gl/lib/.
#   2. Rename `main` to `find_main` / `xargs_main` on each tool's main .o via
#      objcopy --redefine-sym (branch on ABI: `_main` on Mach-O, `main` on ELF).
#   3. Compile a small dispatcher.c (basename(argv[0]) → tool_main).
#   4. Delegate the final link to find/Makefile via an injected
#      `unpin-multicall.mk`. Reason: `$(LDADD)` resolves to ~12 configure-driven
#      vars (LIB_CLOSE, LIB_SETLOCALE_NULL, LIB_MBRTOWC, LIBINTL, FINDLIBS,
#      LIB_SELINUX, MODF_LIBM, …) that differ per target. Letting make do the
#      substitution against find's own context keeps every detail intact —
#      `lib/libfind.a` and `gl/lib/libgnulib.a` get pulled in via libfindtools
#      relative paths, exactly like upstream's recipe.
#   5. Strip upstream's binaries and replace with one `findutils` plus
#      `find`/`xargs` applet symlinks. `lib.withAliases` harvests the
#      symlinks, embeds the names in UNPIN_META, and strips them.
{ lib }:
pkgs:
let
  isTargetDarwin = pkgs.pkgsStatic.stdenv.hostPlatform.isDarwin;

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

  # Custom Makefile fragment lives in find/ — find_LDADD has the union of
  # link bits both tools need (libfindtools is find-only but harmless when
  # linked into a binary that has xargs's main too). $(top_builddir) is one
  # level up so xargs/xargs.o.renamed and gl/lib/libgnulib.a resolve.
  multicallMk = pkgs.writeText "unpin-multicall.mk" ''
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

  multicall = pkgs.pkgsStatic.findutils.overrideAttrs (old: {
    pname = "findutils-multi";

    postBuild = (old.postBuild or "") + ''
      mkdir -p multicall
      cat > multicall/dispatcher.c <<'DISPATCHER_EOF'
${dispatcherC}
DISPATCHER_EOF
      $CC -O2 -c -o multicall/dispatcher.o multicall/dispatcher.c

      ${if isTargetDarwin then ''
        cp find/ftsfind.o find/ftsfind.o.renamed
        cp xargs/xargs.o  xargs/xargs.o.renamed
        $OBJCOPY --redefine-sym _main=_find_main  find/ftsfind.o.renamed
        $OBJCOPY --redefine-sym _main=_xargs_main xargs/xargs.o.renamed
      '' else ''
        cp find/ftsfind.o find/ftsfind.o.renamed
        cp xargs/xargs.o  xargs/xargs.o.renamed
        $OBJCOPY --redefine-sym main=find_main  find/ftsfind.o.renamed
        $OBJCOPY --redefine-sym main=xargs_main xargs/xargs.o.renamed
      ''}

      install -m644 ${multicallMk} find/unpin-multicall.mk
      make -C find -f Makefile -f unpin-multicall.mk multicall-link
    '';

    postInstall = (old.postInstall or "") + ''
      rm -f $out/bin/find $out/bin/xargs
      install -m755 multicall/findutils $out/bin/findutils
      for n in ${lib.concatStringsSep " " appletAliases}; do
        ln -s findutils $out/bin/$n
      done
    '';
  });
in
lib.withAliases pkgs
  {
    primary = "findutils";
    aliasesFromSymlinksIn = "bin";
  }
  multicall
