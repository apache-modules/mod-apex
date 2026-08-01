Name:           php-zts-full
Version:        %{php_version}
Release:        1%{?dist}
Summary:        Self-contained PHP (ZTS + embed SAPI) runtime for mod_apex

License:        PHP-3.01
URL:            https://www.php.net/
# Actual PHP/PECL sources are fetched at build time by build-php-zts.sh
# (php.net and pecl.php.net) -- this Source0 tarball only carries that
# script plus its sibling php-ini/ config files, assembled by
# tools/build_rpm.sh with the standard name-version top-level directory
# expected by the setup macro below.
Source0:        %{name}-%{version}.tar.gz

BuildRequires:  gcc, gcc-c++, make, autoconf, automake, libtool, pkgconf-pkg-config
BuildRequires:  curl, ca-certificates
BuildRequires:  httpd-devel
BuildRequires:  openssl-devel, libcurl-devel, zlib-devel, sqlite-devel
BuildRequires:  oniguruma-devel, libicu-devel, libzip-devel, libxslt-devel
BuildRequires:  freetype-devel, libjpeg-turbo-devel, libwebp-devel, libpng-devel
BuildRequires:  libsodium-devel, gmp-devel, ImageMagick-devel, libxml2-devel

# Requires: intentionally left to RPM's automatic ELF dependency scanner
# (rpmbuild's default find-requires), which inspects every shared object
# under %files and adds the correct versioned package Requires for whatever
# Fedora release this spec is actually built on -- unlike the Debian/Ubuntu
# .deb, which has no built-in equivalent and needs the manual ldd-based
# detection in tools/build_php_zts_deb.sh.

%global php_prefix /usr/local/php-zts

# PHP's Zend engine VM uses GCC global register variables (opline/execute_data
# pinned to specific registers for performance) in Zend/zend_execute.c and
# ext/opcache/jit/zend_jit_vm_helpers.c. This is incompatible with GCC's LTO
# (Fedora's default hardened build flags enable -flto=auto), which fails with
# "global register variable follows a function definition" -- LTO needs to
# merge translation units and can't honor a per-file register pinning
# reliably. Disable LTO for this package (matches upstream Fedora's own
# php.spec, which also disables LTO for the same reason).
%undefine _lto_cflags

%description
Full PHP build with OPcache + JIT enabled, and the extension set required by
WordPress, Drupal, and Symfony (curl, mbstring, openssl, PDO/mysqli/sqlite3,
zip, intl, gd, bcmath, soap, xsl, exif, sodium, gmp, apcu, redis, imagick).
Installs to /usr/local/php-zts, matching the path mod_apex expects for
/usr/local/php-zts/lib/libphp.so.

This package is generated from the same packaging/build-php-zts.sh script
used by the Docker image and the Debian/Ubuntu package, so all three stay
in sync.

%prep
%setup -q

%build
# All work (configure/make/make install for PHP + PECL extensions) happens
# in %%install via DESTDIR staging, since each PECL extension's ./configure
# depends on the freshly-installed php-config from the main PHP install a
# few steps earlier -- splitting that across %%build/%%install would just
# duplicate the same sequential dependency in two macros.

%install
rm -rf %{buildroot}
cd %{_builddir}/%{name}-%{version}
chmod +x packaging/build-php-zts.sh
PREFIX=%{php_prefix} \
DESTDIR=%{buildroot} \
PHP_VERSION=%{php_version} \
SRC_DIR=%{_builddir}/%{name}-%{version}/src \
JOBS="$(nproc)" \
    ./packaging/build-php-zts.sh

%files
%{php_prefix}

%changelog
* Sat Aug 01 2026 mod_apex maintainers <maintainers@example.com> - %{php_version}-1
- Initial php-zts-full package (OPcache + JIT, WordPress/Drupal/Symfony extension set)
