# PHP Apex Docker image

`practicalwebuser/mod_apex-apache:php8.4` puts Apache, PHP 8.4 ZTS, and
PHP Apex (`mod_apex`) in one container. You run one web container; there is
no PHP-FPM container to configure or keep in sync.

The image includes OPcache, APCu, Redis, Imagick, and the PHP extensions
listed in the main [README](README.md). It serves PHP directly through
Apache's event MPM.

## Start an application

Put your PHP application in an `app` folder, then run:

```bash
docker pull practicalwebuser/mod_apex-apache:php8.4
docker run -d --name my-php-app \
  --cpus=4 --memory=1g \
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

## Resource limits and automatic sizing

Set CPU and memory limits in Docker, Compose, or Kubernetes. PHP Apex reads
the CPU limit at startup and chooses a matching Apache worker count. This
keeps a small container from starting with settings intended for a large host.

```yaml
services:
  php:
    image: practicalwebuser/mod_apex-apache:php8.4
    ports:
      - "8080:80"
    volumes:
      - ./app:/var/www/html:ro
    cpus: 4
    mem_limit: 1g
```

The default is 64 workers per available CPU, with a safe range of 128 to
2,048 workers. To override it deliberately:

```bash
docker run -d --name my-php-app \
  --cpus=4 --memory=1g \
  -e APEX_MAX_REQUEST_WORKERS=256 \
  -p 8080:80 \
  practicalwebuser/mod_apex-apache:php8.4
```

`APEX_MAX_REQUEST_WORKERS` accepts whole numbers from 64 through 2,048.
`APEX_CPUS` is an optional whole-number override for unusual runtimes that do
not expose their CPU limit to the container.

## Health checks and logs

The image includes a Docker health check at `/healthz`. It returns `ok` from a
small static file and does not run PHP. Use it for container and load-balancer
health checks:

```bash
curl -fsS http://127.0.0.1:8080/healthz
docker ps
docker logs my-php-app
```

Apache access logs go to standard output and error logs go to standard error,
so `docker logs` and your platform's log collector receive them automatically.

## Apache and PHP settings

The image starts with safe Apache defaults and PHP Apex error detail disabled.
Add your own Apache settings as a separate file, so image upgrades stay easy:

```apache
# app.conf
php_admin_value memory_limit 256M
php_admin_value upload_max_filesize 32M
php_admin_value post_max_size 32M
```

```bash
docker run -d --name my-php-app \
  --cpus=4 --memory=1g \
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
