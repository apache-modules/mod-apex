/*
   +----------------------------------------------------------------------+
   | Copyright (c) The PHP Group                                          |
   +----------------------------------------------------------------------+
   | This source file is subject to version 3.01 of the PHP license,      |
   | that is bundled with this package in the file LICENSE, and is        |
   | available through the world-wide-web at the following url:           |
   | https://www.php.net/license/3_01.txt                                 |
   | If you did not receive a copy of the PHP license and are unable to   |
   | obtain it through the world-wide-web, please send a note to          |
   | license@php.net so we can mail you a copy immediately.               |
   +----------------------------------------------------------------------+
   | Author: Stig Sæther Bakken <ssb@php.net>                             |
   +----------------------------------------------------------------------+
*/

#define CONFIGURE_COMMAND " './configure'  '--prefix=/usr/local/php-zts' '--enable-zts' '--enable-embed' '--enable-opcache' '--enable-mbstring' '--with-curl' '--with-openssl' '--with-zlib' '--with-sqlite3' '--enable-pdo' '--with-pdo-sqlite' '--with-pdo-mysql' '--with-mysqli' '--disable-cgi' '--disable-phpdbg' '--with-config-file-path=/usr/local/php-zts/etc' '--with-config-file-scan-dir=/usr/local/php-zts/etc/conf.d' '--enable-exif' '--enable-intl' '--with-zip' '--enable-bcmath' '--enable-soap' '--with-xsl' '--enable-gd' '--with-freetype' '--with-jpeg' '--with-webp' '--with-sodium' '--with-gmp'"
#define PHP_ODBC_CFLAGS	""
#define PHP_ODBC_LFLAGS		""
#define PHP_ODBC_LIBS		""
#define PHP_ODBC_TYPE		""
#define PHP_PROG_SENDMAIL	"/usr/sbin/sendmail"
#define PEAR_INSTALLDIR         ""
#define PHP_INCLUDE_PATH	".:"
#define PHP_EXTENSION_DIR       "/usr/local/php-zts/lib/php/extensions/no-debug-zts-20240924"
#define PHP_PREFIX              "/usr/local/php-zts"
#define PHP_BINDIR              "/usr/local/php-zts/bin"
#define PHP_SBINDIR             "/usr/local/php-zts/sbin"
#define PHP_MANDIR              "/usr/local/php-zts/php/man"
#define PHP_LIBDIR              "/usr/local/php-zts/lib/php"
#define PHP_DATADIR             "/usr/local/php-zts/share/php"
#define PHP_SYSCONFDIR          "/usr/local/php-zts/etc"
#define PHP_LOCALSTATEDIR       "/usr/local/php-zts/var"
#define PHP_CONFIG_FILE_PATH    "/usr/local/php-zts/etc"
#define PHP_CONFIG_FILE_SCAN_DIR    "/usr/local/php-zts/etc/conf.d"
#define PHP_SHLIB_SUFFIX        "so"
#define PHP_SHLIB_EXT_PREFIX    ""
