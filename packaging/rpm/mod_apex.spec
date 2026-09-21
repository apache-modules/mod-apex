Name:           mod_apex
Version:        %{mod_apex_version}
Release:        1%{?dist}
Summary:        Apache module embedding a persistent, per-thread PHP (ZTS) runtime

License:        Apache-2.0
URL:            https://github.com/apache-modules/mod-apex
Source0:        %{name}-%{version}.tar.gz

BuildRequires:  gcc, make, httpd-devel
# php-zts-full provides /usr/local/php-zts/{bin/php-config,lib/libphp.so}
# used to build and load mod_apex; see packaging/rpm/php-zts-full.spec.
BuildRequires:  php-zts-full
Requires:       httpd
Requires:       php-zts-full

%description
mod_apex embeds PHP (ZTS, embed SAPI) directly into Apache httpd worker
threads instead of shelling out to php-fpm/CGI, keeping a persistent
per-thread PHP engine alive across requests. Requires OPcache+JIT-enabled
PHP built with --enable-zts --enable-embed (see php-zts-full).

%prep
%setup -q

%build
cd %{_builddir}/%{name}-%{version}
chmod +x build-install.sh
PHP_PREFIX=/usr/local/php-zts \
PHP_CONFIG=/usr/local/php-zts/bin/php-config \
INSTALL_MODE=never \
    ./build-install.sh

%install
rm -rf %{buildroot}
cd %{_builddir}/%{name}-%{version}
install -D -m 0755 .libs/mod_apex.so \
    %{buildroot}/usr/lib64/httpd/modules/mod_apex.so
install -D -m 0644 packaging/rpm/apex.load \
    %{buildroot}/etc/httpd/conf.modules.d/10-mod_apex.conf
install -D -m 0644 docker/apex.conf \
    %{buildroot}/etc/httpd/conf.d/mod_apex.conf
install -D -m 0755 tools/apache_mode.sh \
    %{buildroot}/usr/local/sbin/php-apex-mode
install -D -m 0644 packaging/apex-sizing.sh \
    %{buildroot}/usr/local/lib/php-apex/apex-sizing.sh
install -D -m 0644 packaging/apache-wordpress.conf \
    %{buildroot}/etc/httpd/conf.d/php-apex-performance.conf
install -D -m 0644 docker/security-hardening.conf \
    %{buildroot}/etc/httpd/conf.d/php-apex-security.conf

%files
%license LICENSE
%doc NOTICE
/usr/lib64/httpd/modules/mod_apex.so
%config(noreplace) /etc/httpd/conf.modules.d/10-mod_apex.conf
%config(noreplace) /etc/httpd/conf.d/mod_apex.conf
%config(noreplace) /etc/httpd/conf.d/php-apex-performance.conf
%config(noreplace) /etc/httpd/conf.d/php-apex-security.conf
/usr/local/sbin/php-apex-mode
/usr/local/lib/php-apex/apex-sizing.sh

%post
if [ -x /usr/local/sbin/php-apex-mode ] \
    && httpd -M 2>/dev/null | grep -q 'mpm_event_module'; then
    /usr/local/sbin/php-apex-mode auto || \
        echo "WARNING: run 'sudo php-apex-mode auto' after Apache is available." >&2
else
    echo "PHP Apex: enable mpm_event, then run 'sudo php-apex-mode auto'." >&2
fi

%changelog
* Mon Sep 21 2026 mod_apex maintainers <maintainers@example.com> - %{mod_apex_version}-1
- Ship Apache security-header defaults in native packages

* Sat Aug 01 2026 mod_apex maintainers <maintainers@example.com> - %{mod_apex_version}-1
- Initial mod_apex RPM package
