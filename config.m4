dnl config.m4 for mod_flux
PHP_ARG_ENABLE(mod-flux, for mod_flux support,
[  --enable-mod-flux       Build as Apache module], no, no)

if test "$PHP_MOD_FLUX" != "no"; then
  AC_MSG_CHECKING(for Apache 2.x apxs)

  if test -x "$APXS"; then
    APXS="$APXS"
  else
    APXS=`which apxs 2>/dev/null`
  fi

  if test ! -x "$APXS"; then
    AC_MSG_ERROR(apxs not found. Please install Apache development headers)
  fi

  APR_CFLAGS=`$APXS -q CFLAGS`
  APR_INCLUDES=`$APXS -q INCLUDES`
  APR_LIBS=`$APXS -q LIBS`

  PHP_ADD_INCLUDE($APR_INCLUDES)
  PHP_ADD_LIBRARY_WITH_PATH(apr-1,, MOD_FLUX_SHARED_LIBADD)
  PHP_ADD_LIBRARY_WITH_PATH(aprutil-1,, MOD_FLUX_SHARED_LIBADD)

  PHP_NEW_EXTENSION(mod_flux, mod_flux.c, $ext_shared,, \\$(APXS_CFLAGS))
  PHP_SUBST(MOD_FLUX_SHARED_LIBADD)

  PHP_ADD_MAKEFILE_FRAGMENT
  AC_MSG_RESULT(yes)
fi