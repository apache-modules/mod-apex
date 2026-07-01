# syntax=docker/dockerfile:1
#
# mod_apex all-in-one image: Apache 2.4 (event MPM) + PHP (ZTS, embed SAPI)
# + mod_apex, all built from source in a single Dockerfile.
#
# Works identically with Docker and Podman:
#   docker build -t mod-apex .   /   podman build -t mod-apex .
#   docker run  --rm -p 8080:80 mod-apex   /   podman run --rm -p 8080:80 mod-apex
# No rootless-specific changes are required for Podman; the image itself
# still runs Apache as root (dropping privileges internally to www-data for
# worker processes), which podman run maps the same way docker does.
#
# Mount your application into /var/www/html, e.g.:
#   docker run --rm -p 8080:80 -v "$PWD/app:/var/www/html:ro" mod-apex

ARG PHP_VERSION=8.4.21

########################################################################
# Stage 1: build PHP (ZTS + embed SAPI) and mod_apex from source
########################################################################
FROM debian:bookworm-slim AS builder
ARG PHP_VERSION
ENV DEBIAN_FRONTEND=noninteractive

# Build toolchain + dev headers for the PHP extensions enabled below.
# (mysqli/pdo_mysql use PHP's bundled mysqlnd driver -- no external MySQL
# client dev package is needed.) autoconf/automake/libtool are required by
# phpize when building the APCu PECL extension below.
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        autoconf \
        automake \
        libtool \
        pkg-config \
        curl \
        ca-certificates \
        apache2-dev \
        libxml2-dev \
        libssl-dev \
        libcurl4-openssl-dev \
        zlib1g-dev \
        libsqlite3-dev \
        libonig-dev \
        libicu-dev \
        libzip-dev \
        libxslt1-dev \
        libfreetype6-dev \
        libjpeg62-turbo-dev \
        libwebp-dev \
        libpng-dev \
    && rm -rf /var/lib/apt/lists/*

# Fetch and extract the official PHP source tarball (already-generated
# configure/lexer/parser files, so no autoconf/bison/re2c needed here).
WORKDIR /usr/src
RUN curl -fsSL "https://www.php.net/distributions/php-${PHP_VERSION}.tar.gz" -o php.tar.gz \
    && tar xzf php.tar.gz \
    && rm php.tar.gz

# Configure flags mirror the PHP build this project was developed and
# validated against (see README.md "Requirements" and AGENTS.md).
WORKDIR /usr/src/php-${PHP_VERSION}
RUN ./configure \
        --prefix=/usr/local/php-zts \
        --enable-zts \
        --enable-embed \
        --enable-opcache \
        --enable-mbstring \
        --with-curl \
        --with-openssl \
        --with-zlib \
        --with-sqlite3 \
        --enable-pdo \
        --with-pdo-sqlite \
        --with-pdo-mysql \
        --with-mysqli \
        --disable-cgi \
        --disable-phpdbg \
        --with-config-file-path=/usr/local/php-zts/etc \
        --with-config-file-scan-dir=/usr/local/php-zts/etc/conf.d \
        --enable-exif \
        --enable-intl \
        --with-zip \
        --enable-bcmath \
        --enable-soap \
        --with-xsl \
        --enable-gd \
        --with-freetype \
        --with-jpeg \
        --with-webp \
    && make -j"$(nproc)" \
    && make install

RUN mkdir -p /usr/local/php-zts/etc/conf.d \
    && cp php.ini-production /usr/local/php-zts/etc/php.ini

COPY docker/opcache.ini /usr/local/php-zts/etc/conf.d/10-opcache.ini

# APCu (PECL extension, not bundled with core PHP) -- used for object/data
# caching (see /memories/repo notes on the WordPress APCu object cache).
ARG APCU_VERSION=5.1.24
WORKDIR /usr/src
RUN curl -fsSL "https://pecl.php.net/get/apcu-${APCU_VERSION}.tgz" -o apcu.tgz \
    && tar xzf apcu.tgz \
    && rm apcu.tgz \
    && cd apcu-${APCU_VERSION} \
    && /usr/local/php-zts/bin/phpize \
    && ./configure --with-php-config=/usr/local/php-zts/bin/php-config \
    && make -j"$(nproc)" \
    && make install
COPY docker/apcu.ini /usr/local/php-zts/etc/conf.d/20-apcu.ini

# Build mod_apex against the PHP ZTS/embed library just built, reusing the
# repo's own build script so the apxs flags stay in one place (build-install.sh
# already applies compiler/linker hardening -- see README.md#security-hardening).
WORKDIR /usr/src/mod_apex
COPY mod_apex.c build-install.sh ./
RUN chmod +x build-install.sh \
    && PHP_PREFIX=/usr/local/php-zts \
       PHP_CONFIG=/usr/local/php-zts/bin/php-config \
       INSTALL_MODE=never \
       ./build-install.sh

########################################################################
# Stage 2: runtime image
########################################################################
FROM debian:bookworm-slim
ENV DEBIAN_FRONTEND=noninteractive

# Runtime libraries for the extensions enabled above. This reuses the same
# -dev packages as the builder stage (instead of hand-picking exact
# version-suffixed runtime packages like libicu72) so apt resolves the
# correct matching shared libraries for whatever bookworm point release is
# current, at the cost of also shipping unused headers. If image size
# matters more than that safety margin, replace this list with the specific
# runtime (non-dev) package names verified against your base image.
RUN apt-get update && apt-get install -y --no-install-recommends \
        apache2 \
        libxml2-dev \
        libssl-dev \
        libcurl4-openssl-dev \
        zlib1g-dev \
        libsqlite3-dev \
        libonig-dev \
        libicu-dev \
        libzip-dev \
        libxslt1-dev \
        libfreetype6-dev \
        libjpeg62-turbo-dev \
        libwebp-dev \
        libpng-dev \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && a2dismod mpm_prefork >/dev/null 2>&1 || true \
    && a2enmod mpm_event

# PHP ZTS/embed runtime + mod_apex module
COPY --from=builder /usr/local/php-zts /usr/local/php-zts
COPY --from=builder /usr/src/mod_apex/.libs/mod_apex.so /usr/lib/apache2/modules/mod_apex.so

# Apache module wiring: LoadFile libphp.so before LoadModule apex_module
# (packaging/deb/apex.load is the same file used by the .deb package).
COPY packaging/deb/apex.load /etc/apache2/mods-available/apex.load
COPY docker/apex.conf /etc/apache2/mods-available/apex.conf
RUN a2enmod apex

# mpm_event / KeepAlive tuning, ServerName, and the default vhost.
COPY docker/mpm_event.conf /etc/apache2/mods-available/mpm_event.conf
COPY docker/keepalive-tuning.conf /etc/apache2/conf-available/keepalive-tuning.conf
COPY docker/servername.conf /etc/apache2/conf-available/servername.conf
RUN a2enconf keepalive-tuning servername

COPY docker/000-mod-apex.conf /etc/apache2/sites-available/000-mod-apex.conf
RUN a2dissite 000-default >/dev/null 2>&1 || true \
    && a2ensite 000-mod-apex

# Smoke-test endpoint (see README.md "Quick Validation").
RUN mkdir -p /var/www/html
COPY test.php /var/www/html/test.php
RUN chown -R www-data:www-data /var/www/html

EXPOSE 80

# Apache's own foreground entrypoint; child processes drop privileges to
# www-data (mod_apex's child_init/php_embed_init runs inside those children).
CMD ["apache2ctl", "-D", "FOREGROUND"]
