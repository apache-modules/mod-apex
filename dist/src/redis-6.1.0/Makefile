srcdir = /home/bode/sites/mod_apex/dist/src/redis-6.1.0
builddir = /home/bode/sites/mod_apex/dist/src/redis-6.1.0
top_srcdir = /home/bode/sites/mod_apex/dist/src/redis-6.1.0
top_builddir = /home/bode/sites/mod_apex/dist/src/redis-6.1.0
EGREP = /usr/bin/grep -E
SED = /usr/bin/sed
AWK = gawk
SHLIB_SUFFIX_NAME = so
SHLIB_DL_SUFFIX_NAME = so
REDIS_SHARED_LIBADD =
shared_objects_redis = redis.lo redis_commands.lo library.lo redis_session.lo redis_array.lo redis_array_impl.lo redis_cluster.lo cluster_library.lo redis_sentinel.lo sentinel_library.lo backoff.lo
PHP_PECL_EXTENSION = redis
PHP_MODULES = $(phplibdir)/redis.la
PHP_ZEND_EX =
all_targets = $(PHP_MODULES) $(PHP_ZEND_EX)
install_targets = install-modules install-headers
prefix = /usr/local/php-zts
exec_prefix = $(prefix)
libdir = ${exec_prefix}/lib
phpincludedir = /usr/local/php-zts/include/php
CC = cc
CFLAGS = -g -O2
CFLAGS_CLEAN = $(CFLAGS) -D_GNU_SOURCE
CPP = cc -E
CPPFLAGS = -DHAVE_CONFIG_H
CXX =
CXXFLAGS =
CXXFLAGS_CLEAN = $(CXXFLAGS)
EXTENSION_DIR = /usr/local/php-zts/lib/php/extensions/no-debug-zts-20240924
PHP_EXECUTABLE = /usr/local/php-zts/bin/php
EXTRA_LDFLAGS =
EXTRA_LIBS =
INCLUDES = -I/usr/local/php-zts/include/php -I/usr/local/php-zts/include/php/main -I/usr/local/php-zts/include/php/TSRM -I/usr/local/php-zts/include/php/Zend -I/usr/local/php-zts/include/php/ext -I/usr/local/php-zts/include/php/ext/date/lib -I/usr/local/php-zts/include/php/ext
LDFLAGS =
LIBTOOL = $(SHELL) $(top_builddir)/libtool
SHELL = /bin/bash
INSTALL_HEADERS =
BUILD_CC = cc
phplibdir = /home/bode/sites/mod_apex/dist/src/redis-6.1.0/modules
mkinstalldirs = $(top_srcdir)/build/shtool mkdir -p
INSTALL = $(top_srcdir)/build/shtool install -c
INSTALL_DATA = $(INSTALL) -m 644

COMMON_FLAGS = $(INCLUDES) $(EXTRA_INCLUDES) $(CPPFLAGS) $(PHP_FRAMEWORKPATH)

all: $(all_targets)
	@echo
	@echo "Build complete."
	@echo "Don't forget to run 'make test'."
	@echo

build-modules: $(PHP_MODULES) $(PHP_ZEND_EX)

build-binaries: $(PHP_BINARIES)

libphp.la: $(PHP_GLOBAL_OBJS) $(PHP_SAPI_OBJS)
	$(LIBTOOL) --tag=CC --mode=link $(CC) $(LIBPHP_CFLAGS) $(CFLAGS) $(EXTRA_CFLAGS) -rpath $(phptempdir) $(EXTRA_LDFLAGS) $(LDFLAGS) $(PHP_RPATHS) $(PHP_GLOBAL_OBJS) $(PHP_SAPI_OBJS) $(EXTRA_LIBS) $(ZEND_EXTRA_LIBS) -o $@
	-@$(LIBTOOL) --tag=CC --mode=install cp $@ $(phptempdir)/$@ >/dev/null 2>&1

libphp.dylib: libphp.la
	$(LIBTOOL) --tag=CC --mode=link $(CC) -dynamiclib $(LIBPHP_CFLAGS) $(CFLAGS_CLEAN) $(EXTRA_CFLAGS) -rpath $(phptempdir) -install_name @rpath/$@ $(EXTRA_LDFLAGS) $(LDFLAGS) $(PHP_RPATHS) $(PHP_GLOBAL_OBJS) $(PHP_SAPI_OBJS) $(EXTRA_LIBS) $(ZEND_EXTRA_LIBS) -o $@
	-@$(LIBTOOL) --silent --tag=CC --mode=install cp $@ $(phptempdir)/$@ >/dev/null 2>&1

libs/libphp.bundle: $(PHP_GLOBAL_OBJS) $(PHP_SAPI_OBJS)
	$(CC) $(MH_BUNDLE_FLAGS) $(CFLAGS_CLEAN) $(EXTRA_CFLAGS) $(LDFLAGS) $(EXTRA_LDFLAGS) $(PHP_GLOBAL_OBJS:.lo=.o) $(PHP_SAPI_OBJS:.lo=.o) $(PHP_FRAMEWORKS) $(EXTRA_LIBS) $(ZEND_EXTRA_LIBS) -o $@ && cp $@ libs/libphp.so

install: $(all_targets) $(install_targets)

install-sapi: $(OVERALL_TARGET)
	@echo "Installing PHP SAPI module:       $(PHP_SAPI)"
	-@$(mkinstalldirs) $(INSTALL_ROOT)$(bindir)
	-@if test ! -r $(phptempdir)/libphp.$(SHLIB_DL_SUFFIX_NAME); then \
		for i in 0.0.0 0.0 0; do \
			if test -r $(phptempdir)/libphp.$(SHLIB_DL_SUFFIX_NAME).$$i; then \
				$(LN_S) $(phptempdir)/libphp.$(SHLIB_DL_SUFFIX_NAME).$$i $(phptempdir)/libphp.$(SHLIB_DL_SUFFIX_NAME); \
				break; \
			fi; \
		done; \
	fi
	@$(INSTALL_IT)

install-binaries: build-binaries $(install_binary_targets)

install-modules: build-modules
	@test -d modules && \
	$(mkinstalldirs) $(INSTALL_ROOT)$(EXTENSION_DIR)
	@echo "Installing shared extensions:     $(INSTALL_ROOT)$(EXTENSION_DIR)/"
	@rm -f modules/*.la >/dev/null 2>&1
	@$(INSTALL) modules/* $(INSTALL_ROOT)$(EXTENSION_DIR)

install-headers:
	-@if test "$(INSTALL_HEADERS)"; then \
		for i in `echo $(INSTALL_HEADERS)`; do \
			i=`$(top_srcdir)/build/shtool path -d $$i`; \
			paths="$$paths $(INSTALL_ROOT)$(phpincludedir)/$$i"; \
		done; \
		$(mkinstalldirs) $$paths && \
		echo "Installing header files:          $(INSTALL_ROOT)$(phpincludedir)/" && \
		for i in `echo $(INSTALL_HEADERS)`; do \
			if test "$(PHP_PECL_EXTENSION)"; then \
				src=`echo $$i | $(SED) -e "s#ext/$(PHP_PECL_EXTENSION)/##g"`; \
			else \
				src=$$i; \
			fi; \
			if test -f "$(top_srcdir)/$$src"; then \
				$(INSTALL_DATA) $(top_srcdir)/$$src $(INSTALL_ROOT)$(phpincludedir)/$$i; \
			elif test -f "$(top_builddir)/$$src"; then \
				$(INSTALL_DATA) $(top_builddir)/$$src $(INSTALL_ROOT)$(phpincludedir)/$$i; \
			else \
				(cd $(top_srcdir)/$$src && $(INSTALL_DATA) *.h $(INSTALL_ROOT)$(phpincludedir)/$$i; \
				cd $(top_builddir)/$$src && $(INSTALL_DATA) *.h $(INSTALL_ROOT)$(phpincludedir)/$$i) 2>/dev/null || true; \
			fi \
		done; \
	fi

PHP_TEST_SETTINGS = -d 'open_basedir=' -d 'output_buffering=0' -d 'memory_limit=-1'
PHP_TEST_SHARED_EXTENSIONS =  ` \
	if test "x$(PHP_MODULES)" != "x"; then \
		for i in $(PHP_MODULES)""; do \
			. $$i; \
			if test "x$$dlname" != "xdl_test.so"; then \
				$(top_srcdir)/build/shtool echo -n -- " -d extension=$$dlname"; \
			fi; \
		done; \
	fi; \
	if test "x$(PHP_ZEND_EX)" != "x"; then \
		for i in $(PHP_ZEND_EX)""; do \
			. $$i; $(top_srcdir)/build/shtool echo -n -- " -d zend_extension=$(top_builddir)/modules/$$dlname"; \
		done; \
	fi`
PHP_DEPRECATED_DIRECTIVES_REGEX = '^[\t\ ]*(magic_quotes_(gpc|runtime|sybase)?|(zend_)?extension(_debug)?(_ts)?|session\.sid_(length|bits_per_character))[\t\ ]*='

test: all
	@if test ! -z "$(PHP_EXECUTABLE)" && test -x "$(PHP_EXECUTABLE)"; then \
		INI_FILE=`$(PHP_EXECUTABLE) -d 'display_errors=stderr' -r 'echo php_ini_loaded_file();' 2> /dev/null`; \
		if test "$$INI_FILE"; then \
			$(EGREP) -h -v $(PHP_DEPRECATED_DIRECTIVES_REGEX) "$$INI_FILE" > $(top_builddir)/tmp-php.ini; \
		else \
			echo > $(top_builddir)/tmp-php.ini; \
		fi; \
		INI_SCANNED_PATH=`$(PHP_EXECUTABLE) -d 'display_errors=stderr' -r '$$a = explode(",\n", trim(php_ini_scanned_files())); echo $$a[0];' 2> /dev/null`; \
		if test "$$INI_SCANNED_PATH"; then \
			INI_SCANNED_PATH=`$(top_srcdir)/build/shtool path -d $$INI_SCANNED_PATH`; \
			$(EGREP) -h -v $(PHP_DEPRECATED_DIRECTIVES_REGEX) "$$INI_SCANNED_PATH"/*.ini >> $(top_builddir)/tmp-php.ini; \
		fi; \
		TEST_PHP_EXECUTABLE=$(PHP_EXECUTABLE) \
		TEST_PHP_SRCDIR=$(top_srcdir) \
		CC="$(CC)" \
			$(PHP_EXECUTABLE) -n -c $(top_builddir)/tmp-php.ini $(PHP_TEST_SETTINGS) $(top_srcdir)/run-tests.php -n -c $(top_builddir)/tmp-php.ini -d extension_dir=$(top_builddir)/modules/ $(PHP_TEST_SHARED_EXTENSIONS) $(TESTS); \
		TEST_RESULT_EXIT_CODE=$$?; \
		rm $(top_builddir)/tmp-php.ini; \
		exit $$TEST_RESULT_EXIT_CODE; \
	else \
		echo "ERROR: Cannot run tests without CLI sapi."; \
	fi

clean:
	find . -name \*.gcno -o -name \*.gcda | xargs rm -f
	find . -name \*.lo -o -name \*.o -o -name \*.dep | xargs rm -f
	find . -name \*.la -o -name \*.a | xargs rm -f
	find . -name \*.so | xargs rm -f
	find . -name .libs -a -type d|xargs rm -rf
	rm -f libphp.la $(SAPI_CLI_PATH) $(SAPI_CGI_PATH) $(SAPI_LITESPEED_PATH) $(SAPI_FPM_PATH) $(OVERALL_TARGET) modules/* libs/*
	rm -f ext/opcache/jit/ir/gen_ir_fold_hash
	rm -f ext/opcache/jit/ir/minilua
	rm -f ext/opcache/jit/ir/ir_fold_hash.h
	rm -f ext/opcache/jit/ir/ir_emit_x86.h
	rm -f ext/opcache/jit/ir/ir_emit_aarch64.h

distclean: clean
	rm -f Makefile config.cache config.log config.status Makefile.objects Makefile.fragments libtool main/php_config.h main/internal_functions_cli.c main/internal_functions.c Zend/zend_dtrace_gen.h Zend/zend_dtrace_gen.h.bak Zend/zend_config.h
	rm -f main/build-defs.h scripts/phpize
	rm -f ext/date/lib/timelib_config.h ext/mbstring/libmbfl/config.h
	rm -f scripts/man1/phpize.1 scripts/php-config scripts/man1/php-config.1 sapi/cli/php.1 sapi/cgi/php-cgi.1 sapi/phpdbg/phpdbg.1 ext/phar/phar.1 ext/phar/phar.phar.1
	rm -f sapi/fpm/php-fpm.conf sapi/fpm/init.d.php-fpm sapi/fpm/php-fpm.service sapi/fpm/php-fpm.8 sapi/fpm/status.html
	rm -f ext/phar/phar.phar ext/phar/phar.php
	if test "$(srcdir)" != "$(builddir)"; then \
		rm -f ext/phar/phar/phar.inc; \
	fi

prof-gen:
	CCACHE_DISABLE=1 $(MAKE) PROF_FLAGS=-fprofile-generate all
	find . -name \*.gcda | xargs rm -f

prof-clean:
	find . -name \*.lo -o -name \*.o | xargs rm -f
	find . -name \*.la -o -name \*.a | xargs rm -f
	find . -name \*.so | xargs rm -f
	rm -f libphp.la $(SAPI_CLI_PATH) $(SAPI_CGI_PATH) $(SAPI_LITESPEED_PATH) $(SAPI_FPM_PATH) $(OVERALL_TARGET) modules/* libs/*

prof-use:
	CCACHE_DISABLE=1 $(MAKE) PROF_FLAGS=-fprofile-use all

%_arginfo.h: %.stub.php
	@if test -e "$(top_srcdir)/build/gen_stub.php"; then \
		if test ! -z "$(PHP)"; then \
			echo Parse $< to generate $@;\
			$(PHP) $(top_srcdir)/build/gen_stub.php $<; \
		elif test ! -z "$(PHP_EXECUTABLE)" && test -x "$(PHP_EXECUTABLE)"; then \
			echo Parse $< to generate $@;\
			$(PHP_EXECUTABLE) $(top_srcdir)/build/gen_stub.php $<; \
		fi; \
	fi;

.PHONY: all clean install distclean test prof-gen prof-clean prof-use
-include redis.dep
redis.lo: /home/bode/sites/mod_apex/dist/src/redis-6.1.0/redis.c
	$(LIBTOOL) --tag=CC --mode=compile $(CC) -I. -I/home/bode/sites/mod_apex/dist/src/redis-6.1.0 $(COMMON_FLAGS) $(CFLAGS_CLEAN) $(EXTRA_CFLAGS)   -DZEND_COMPILE_DL_EXT=1 -c /home/bode/sites/mod_apex/dist/src/redis-6.1.0/redis.c -o redis.lo  -MMD -MF redis.dep -MT redis.lo
-include redis_commands.dep
redis_commands.lo: /home/bode/sites/mod_apex/dist/src/redis-6.1.0/redis_commands.c
	$(LIBTOOL) --tag=CC --mode=compile $(CC) -I. -I/home/bode/sites/mod_apex/dist/src/redis-6.1.0 $(COMMON_FLAGS) $(CFLAGS_CLEAN) $(EXTRA_CFLAGS)   -DZEND_COMPILE_DL_EXT=1 -c /home/bode/sites/mod_apex/dist/src/redis-6.1.0/redis_commands.c -o redis_commands.lo  -MMD -MF redis_commands.dep -MT redis_commands.lo
-include library.dep
library.lo: /home/bode/sites/mod_apex/dist/src/redis-6.1.0/library.c
	$(LIBTOOL) --tag=CC --mode=compile $(CC) -I. -I/home/bode/sites/mod_apex/dist/src/redis-6.1.0 $(COMMON_FLAGS) $(CFLAGS_CLEAN) $(EXTRA_CFLAGS)   -DZEND_COMPILE_DL_EXT=1 -c /home/bode/sites/mod_apex/dist/src/redis-6.1.0/library.c -o library.lo  -MMD -MF library.dep -MT library.lo
-include redis_session.dep
redis_session.lo: /home/bode/sites/mod_apex/dist/src/redis-6.1.0/redis_session.c
	$(LIBTOOL) --tag=CC --mode=compile $(CC) -I. -I/home/bode/sites/mod_apex/dist/src/redis-6.1.0 $(COMMON_FLAGS) $(CFLAGS_CLEAN) $(EXTRA_CFLAGS)   -DZEND_COMPILE_DL_EXT=1 -c /home/bode/sites/mod_apex/dist/src/redis-6.1.0/redis_session.c -o redis_session.lo  -MMD -MF redis_session.dep -MT redis_session.lo
-include redis_array.dep
redis_array.lo: /home/bode/sites/mod_apex/dist/src/redis-6.1.0/redis_array.c
	$(LIBTOOL) --tag=CC --mode=compile $(CC) -I. -I/home/bode/sites/mod_apex/dist/src/redis-6.1.0 $(COMMON_FLAGS) $(CFLAGS_CLEAN) $(EXTRA_CFLAGS)   -DZEND_COMPILE_DL_EXT=1 -c /home/bode/sites/mod_apex/dist/src/redis-6.1.0/redis_array.c -o redis_array.lo  -MMD -MF redis_array.dep -MT redis_array.lo
-include redis_array_impl.dep
redis_array_impl.lo: /home/bode/sites/mod_apex/dist/src/redis-6.1.0/redis_array_impl.c
	$(LIBTOOL) --tag=CC --mode=compile $(CC) -I. -I/home/bode/sites/mod_apex/dist/src/redis-6.1.0 $(COMMON_FLAGS) $(CFLAGS_CLEAN) $(EXTRA_CFLAGS)   -DZEND_COMPILE_DL_EXT=1 -c /home/bode/sites/mod_apex/dist/src/redis-6.1.0/redis_array_impl.c -o redis_array_impl.lo  -MMD -MF redis_array_impl.dep -MT redis_array_impl.lo
-include redis_cluster.dep
redis_cluster.lo: /home/bode/sites/mod_apex/dist/src/redis-6.1.0/redis_cluster.c
	$(LIBTOOL) --tag=CC --mode=compile $(CC) -I. -I/home/bode/sites/mod_apex/dist/src/redis-6.1.0 $(COMMON_FLAGS) $(CFLAGS_CLEAN) $(EXTRA_CFLAGS)   -DZEND_COMPILE_DL_EXT=1 -c /home/bode/sites/mod_apex/dist/src/redis-6.1.0/redis_cluster.c -o redis_cluster.lo  -MMD -MF redis_cluster.dep -MT redis_cluster.lo
-include cluster_library.dep
cluster_library.lo: /home/bode/sites/mod_apex/dist/src/redis-6.1.0/cluster_library.c
	$(LIBTOOL) --tag=CC --mode=compile $(CC) -I. -I/home/bode/sites/mod_apex/dist/src/redis-6.1.0 $(COMMON_FLAGS) $(CFLAGS_CLEAN) $(EXTRA_CFLAGS)   -DZEND_COMPILE_DL_EXT=1 -c /home/bode/sites/mod_apex/dist/src/redis-6.1.0/cluster_library.c -o cluster_library.lo  -MMD -MF cluster_library.dep -MT cluster_library.lo
-include redis_sentinel.dep
redis_sentinel.lo: /home/bode/sites/mod_apex/dist/src/redis-6.1.0/redis_sentinel.c
	$(LIBTOOL) --tag=CC --mode=compile $(CC) -I. -I/home/bode/sites/mod_apex/dist/src/redis-6.1.0 $(COMMON_FLAGS) $(CFLAGS_CLEAN) $(EXTRA_CFLAGS)   -DZEND_COMPILE_DL_EXT=1 -c /home/bode/sites/mod_apex/dist/src/redis-6.1.0/redis_sentinel.c -o redis_sentinel.lo  -MMD -MF redis_sentinel.dep -MT redis_sentinel.lo
-include sentinel_library.dep
sentinel_library.lo: /home/bode/sites/mod_apex/dist/src/redis-6.1.0/sentinel_library.c
	$(LIBTOOL) --tag=CC --mode=compile $(CC) -I. -I/home/bode/sites/mod_apex/dist/src/redis-6.1.0 $(COMMON_FLAGS) $(CFLAGS_CLEAN) $(EXTRA_CFLAGS)   -DZEND_COMPILE_DL_EXT=1 -c /home/bode/sites/mod_apex/dist/src/redis-6.1.0/sentinel_library.c -o sentinel_library.lo  -MMD -MF sentinel_library.dep -MT sentinel_library.lo
-include backoff.dep
backoff.lo: /home/bode/sites/mod_apex/dist/src/redis-6.1.0/backoff.c
	$(LIBTOOL) --tag=CC --mode=compile $(CC) -I. -I/home/bode/sites/mod_apex/dist/src/redis-6.1.0 $(COMMON_FLAGS) $(CFLAGS_CLEAN) $(EXTRA_CFLAGS)   -DZEND_COMPILE_DL_EXT=1 -c /home/bode/sites/mod_apex/dist/src/redis-6.1.0/backoff.c -o backoff.lo  -MMD -MF backoff.dep -MT backoff.lo
$(phplibdir)/redis.la: ./redis.la
	$(LIBTOOL) --tag=CC --mode=install cp ./redis.la $(phplibdir)

./redis.la: $(shared_objects_redis) $(REDIS_SHARED_DEPENDENCIES)
	$(LIBTOOL) --tag=CC --mode=link $(CC) -shared $(COMMON_FLAGS) $(CFLAGS_CLEAN) $(EXTRA_CFLAGS) $(LDFLAGS)  -o $@ -export-dynamic -avoid-version -prefer-pic -module -rpath $(phplibdir) $(EXTRA_LDFLAGS) $(shared_objects_redis) $(REDIS_SHARED_LIBADD)

