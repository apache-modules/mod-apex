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
ARG APCU_VERSION=5.1.24
ARG REDIS_VERSION=6.1.0
ARG IMAGICK_VERSION=3.8.1
ARG DEBIAN_IMAGE=debian:bookworm-slim@sha256:88200866dfff7ea7f5cbcb6ec7c8a701889efe6fe859fe64d6990e4b07ea4171

########################################################################
# Stage 1: build PHP (ZTS + embed SAPI) and mod_apex from source
########################################################################
FROM ${DEBIAN_IMAGE} AS builder
ARG PHP_VERSION
ARG APCU_VERSION
ARG REDIS_VERSION
ARG IMAGICK_VERSION
ENV DEBIAN_FRONTEND=noninteractive

# Build toolchain + dev headers for the PHP extensions enabled below.
# (mysqli/pdo_mysql use PHP's bundled mysqlnd driver -- no external MySQL
# client dev package is needed.) autoconf/automake/libtool are required by
# phpize when building the APCu/Redis/Imagick PECL extensions. libsodium-dev/
# libgmp-dev/libmagickwand-dev cover the sodium/gmp/imagick additions needed
# for WordPress/Drupal/Symfony (see packaging/build-php-zts.sh).
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
        libsodium-dev \
        libgmp-dev \
        libmagickwand-dev \
    && rm -rf /var/lib/apt/lists/*

# Shared build script (also used by tools/build_php_zts_deb.sh and the
# Fedora RPM spec) so the configure flags and extension set stay in one
# place across all packaging paths.
WORKDIR /usr/src/mod_apex
COPY packaging/build-php-zts.sh packaging/build-php-zts.sh
COPY packaging/php-ini/ packaging/php-ini/
RUN chmod +x packaging/build-php-zts.sh \
    && PHP_VERSION="$PHP_VERSION" \
       APCU_VERSION="$APCU_VERSION" \
       REDIS_VERSION="$REDIS_VERSION" \
       IMAGICK_VERSION="$IMAGICK_VERSION" \
       ./packaging/build-php-zts.sh

# Build mod_apex against the PHP ZTS/embed library just built, reusing the
# repo's own build script so the apxs flags stay in one place (build-install.sh
# already applies compiler/linker hardening -- see README.md#security-hardening).
COPY mod_apex.c build-install.sh ./
RUN chmod +x build-install.sh \
    && PHP_PREFIX=/usr/local/php-zts \
       PHP_CONFIG=/usr/local/php-zts/bin/php-config \
       INSTALL_MODE=never \
       ./build-install.sh

########################################################################
# Stage 2: runtime image
########################################################################
FROM ${DEBIAN_IMAGE}
ENV DEBIAN_FRONTEND=noninteractive

# Runtime libraries for the extensions enabled above. Keep compiler tools and
# development headers in the builder stage so the published image contains
# only what Apache, PHP, and the enabled extensions need to run.
RUN apt-get update && apt-get install -y --no-install-recommends \
        apache2 \
        ca-certificates \
        curl \
        libcurl4 \
        libfreetype6 \
        libgmp10 \
        libicu72 \
        libjpeg62-turbo \
        libmagickwand-6.q16-6 \
        libonig5 \
        libpng16-16 \
        libsodium23 \
        libsqlite3-0 \
        libssl3 \
        libwebp7 \
        libxml2 \
        libxslt1.1 \
        libzip4 \
        zlib1g \
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

# The entrypoint writes the MPM worker count for the container's available
# CPUs. Keep this installed configuration as a clear marker that sizing is
# generated at container start.
COPY docker/mpm_event.conf /etc/apache2/mods-available/mpm_event.conf
COPY docker/keepalive-tuning.conf /etc/apache2/conf-available/keepalive-tuning.conf
COPY docker/servername.conf /etc/apache2/conf-available/servername.conf
COPY docker/security-hardening.conf /etc/apache2/conf-available/security-hardening.conf
RUN touch /etc/apache2/conf-available/apex-runtime.conf \
    && a2enconf apex-runtime keepalive-tuning servername security-hardening

COPY docker/000-mod-apex.conf /etc/apache2/sites-available/000-mod-apex.conf
RUN a2dissite 000-default >/dev/null 2>&1 || true \
    && a2ensite 000-mod-apex

# Smoke-test endpoint and a static health endpoint. The health endpoint does
# not invoke PHP, so a load balancer can distinguish web-server availability
# from an application-level issue.
RUN mkdir -p /var/www/html
COPY test.php /var/www/html/test.php
RUN printf 'ok\n' > /var/www/html/healthz \
    && chown -R www-data:www-data /var/www/html

COPY --chmod=0755 docker/docker-entrypoint.sh /usr/local/bin/docker-entrypoint

LABEL org.opencontainers.image.title="PHP Apex" \
      org.opencontainers.image.description="Apache, PHP 8.4 ZTS, and mod_apex in one container"

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=3s --start-period=15s --retries=3 \
    CMD curl --fail --silent http://127.0.0.1/healthz || exit 1

# Apache starts as root only to bind the port and manage workers; workers drop
# privileges to www-data. The entrypoint validates the generated config first.
ENTRYPOINT ["/usr/local/bin/docker-entrypoint"]
CMD ["apache2ctl", "-D", "FOREGROUND"]
