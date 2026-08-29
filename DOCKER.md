# PHP Apex Docker image

`practicalwebuser/mod_apex-apache:php8.4` puts Apache, PHP 8.4 ZTS, and
PHP Apex (`mod_apex`) in one container. You run one web container; there is
no PHP-FPM container to configure or keep in sync.

It serves PHP directly through Apache's event MPM and includes the extensions
most WordPress, Drupal, Symfony, and custom PHP applications commonly need.

## What's in the image

- **Apache 2.4 with event MPM** for modern threaded request handling.
- **PHP 8.4.21 ZTS** with the embed SAPI used by PHP Apex.
- **PHP Apex (`mod_apex`)** already loaded and mapped to `.php` files.
- **Performance tools:** OPcache with JIT support and APCu object caching.
- **Cache and session support:** the native Redis PHP extension.
- **Databases:** MySQL through `mysqli` and PDO MySQL, plus PDO SQLite.
- **Application extensions:** curl, mbstring, intl, fileinfo, EXIF, BCMath,
  GMP, sodium, SOAP, XML, SimpleXML, XMLReader, XMLWriter, XSL, and ZIP.
- **Image handling:** GD with JPEG, PNG, WebP, and FreeType, plus Imagick.
- **Container setup:** balanced Apache sizing, hardened Apache defaults,
  a static `/healthz` check, and logs sent to the container output.
- **Base system:** a small Debian Bookworm Slim runtime containing only the
  libraries required by Apache, PHP, and the bundled extensions.

The build tools and compiler stay outside the runtime image. Apache starts as
root so it can bind port 80, then its request workers run as `www-data`.

## Start an application

Put your PHP application in an `app` folder, then run:

```bash
docker pull practicalwebuser/mod_apex-apache:php8.4
docker run -d --name my-php-app \
  --cpus=4 --memory=2g \
  -p 8080:80 \
  -v "$(pwd)/app:/var/www/html:ro" \
  practicalwebuser/mod_apex-apache:php8.4
```

Open `http://your-server:8080`. The container listens on plain HTTP port 80.
Put HTTPS, certificates, and public internet traffic at your reverse proxy or
load balancer. Do not put private keys or application secrets in the image.

The application mount is read-only above. That is a good default. If your
application needs uploads, cache files, or generated media, mount only those
specific writable directories as named volumes or writable bind mounts.

## Resource limits and worker sizing

Set CPU and memory limits in Docker, Compose, or Kubernetes. PHP Apex starts
with a balanced 128-worker profile and recycles Apache children after
1,000 connections so memory remains controlled during sustained traffic.

```yaml
services:
  php:
    image: practicalwebuser/mod_apex-apache:php8.4
    ports:
      - "8080:80"
    volumes:
      - ./app:/var/www/html:ro
    cpus: 4
    mem_limit: 2g
```

The default is 128 workers. To override it deliberately:

```bash
docker run -d --name my-php-app \
  --cpus=4 --memory=2g \
  -e APEX_MAX_REQUEST_WORKERS=256 \
  -p 8080:80 \
  practicalwebuser/mod_apex-apache:php8.4
```

`APEX_MAX_REQUEST_WORKERS` accepts whole numbers from 64 through 512.

## Health checks and logs

The image includes a Docker health check at `/healthz`. It returns `ok` from a
small static file and does not run PHP. Use it for container and load-balancer
health checks:

```bash
curl -fsS http://127.0.0.1:8080/healthz
docker ps
docker logs my-php-app
```

Apache access and diagnostic logs go to the container log stream, so `docker
logs` and your platform's log collector receive them automatically.

The image also contains `/test.php` as a quick PHP check. Remove or replace it
when mounting your application directory, or block it in your public routing
if you do not mount over `/var/www/html`.

## Apache and PHP settings

The image starts with safe Apache defaults. Add your own Apache settings as a
separate file, so image upgrades stay easy:

```apache
# app.conf
php_admin_value memory_limit 256M
php_admin_value upload_max_filesize 32M
php_admin_value post_max_size 32M
```

```bash
docker run -d --name my-php-app \
  --cpus=4 --memory=2g \
  -p 8080:80 \
  -v "$(pwd)/app:/var/www/html:ro" \
  -v "$(pwd)/app.conf:/etc/apache2/conf-enabled/zzz-app.conf:ro" \
  practicalwebuser/mod_apex-apache:php8.4
```

Use your framework's normal configuration for database connections, sessions,
and trusted proxies. If a proxy supplies the real visitor IP address, configure
Apache's `mod_remoteip` at the proxy boundary; PHP Apex intentionally passes
incoming HTTP headers through like mod_php and PHP-FPM.

## Updating safely

The `php8.4` tag moves as fixes are published. For repeatable deployments,
pin the image digest after testing a release:

```bash
docker pull practicalwebuser/mod_apex-apache:php8.4
docker image inspect practicalwebuser/mod_apex-apache:php8.4 \
  --format '{{index .RepoDigests 0}}'
```

Deploy that digest to production, then test a new digest in staging before
changing it. Keep the CPU and memory limits with the deployment definition,
not baked into the image.
