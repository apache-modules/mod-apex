# PHP Apex Docker image

`practicalwebuser/mod_apex-apache:php8.4` puts Apache, PHP 8.4 ZTS, and
PHP Apex (`mod_apex`) in one container. You run one web container; there is
no PHP-FPM container to configure or keep in sync.

It serves PHP directly through Apache's event MPM and includes the extensions
most WordPress, Drupal, Symfony, and custom PHP applications commonly need.

## What's in the image

- **Apache 2.4 with event MPM** for modern threaded request handling.
- **PHP 8.4.25 ZTS** with the embed SAPI used by PHP Apex.
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
mkdir -p "$(pwd)/app"
test -e "$(pwd)/app/healthz" || printf 'ok\n' > "$(pwd)/app/healthz"
docker pull practicalwebuser/mod_apex-apache:php8.4
docker run -d --name my-php-app \
  --cpus=2 --memory=2g \
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

The image contains a static `/healthz` file, but a bind mount on
`/var/www/html` replaces that entire directory. The example therefore creates
the same static file in the mounted application before starting the container.
Keep that file in the deployed document root, or bake the application into a
derived image with `COPY app/ /var/www/html/`; copying preserves the image's
existing health file unless the application supplies a replacement. Without a
reachable `/healthz`, Docker correctly reports the container as unhealthy even
when Apache itself is running.

## Resource limits and worker sizing

Set CPU and memory limits in Docker, Compose, or Kubernetes. PHP Apex detects
those limits and sizes its worker pool automatically. It uses two workers per
effective CPU, then caps that result to the memory available after reserving
25% (at least 256 MiB) at 128 MiB per PHP worker. Keep-alive is disabled and
the first Apache child remains persistent.

> **Important:** the container entrypoint must remain responsible for the
> event-MPM settings. Do not manually replace `ServerLimit`, `ThreadLimit`,
> `ThreadsPerChild`, or `MaxRequestWorkers` in Apache configuration. A
> mismatched set can cause Apache to silently change the effective worker
> count, which can increase memory use or reduce throughput. Set container CPU
> and memory limits, then let automatic tuning calculate the matching layout.
> Use the documented `APEX_*` variables for deliberate, measured overrides.

```yaml
services:
  php:
    image: practicalwebuser/mod_apex-apache:php8.4
    ports:
      - "8080:80"
    volumes:
      - ./app:/var/www/html:ro
    cpus: 2
    mem_limit: 2g
```

This Compose example assumes `./app/healthz` exists for the same reason as the
bind-mount example above.

A 2-CPU, 2-GiB container selects four workers. For a measured high-traffic
deployment, enable short keep-alive connections and override the worker limit
deliberately:

```bash
docker run -d --name my-php-app \
  --cpus=2 --memory=2g \
  -e APEX_KEEP_ALIVE=1 \
  -e APEX_MAX_REQUEST_WORKERS=8 \
  -p 8080:80 \
  practicalwebuser/mod_apex-apache:php8.4
```

`APEX_MAX_REQUEST_WORKERS` accepts whole numbers from 1 through 512 and takes
precedence over automatic sizing. `APEX_CPU_COUNT`, `APEX_MEMORY_MB`, and
`APEX_MEMORY_PER_WORKER_MB` can override the detected sizing inputs.
`APEX_KEEP_ALIVE` accepts `0` or `1` and defaults to `0`. Enable it only after
measuring a representative high-traffic workload. The entrypoint chooses a
valid event-MPM layout of up to eight children and 64 threads per child. If an
unfactorable worker value needs a small downward adjustment, startup reports
both the requested and effective limits.

`MaxConnectionsPerChild` defaults to `0`, which keeps the single baseline
child persistent. It counts TCP connections, not PHP requests; one keep-alive
connection can carry many requests. Multi-child deployments can test recycling
without rebuilding:

```bash
docker run -d --name my-php-app \
  -e APEX_MAX_CONNECTIONS_PER_CHILD=10000 \
  -p 8080:80 \
  practicalwebuser/mod_apex-apache:php8.4
```

`APEX_MAX_CONNECTIONS_PER_CHILD` accepts values from `0` through `1000000`;
`0` disables connection-count recycling. Measure memory, child restart rate,
latency, and throughput before enabling recycling in production.

## OPcache and writable application code

The image assumes application code is baked into the image or mounted
read-only, so OPcache timestamp validation is off by default. This avoids a
filesystem check on every request and is the best setting for immutable
deployments.

If PHP files can change while the container is running—for example, WordPress
updates a plugin or theme on a writable volume—enable timestamp validation:

```bash
docker run -d --name my-php-app \
  -e APEX_OPCACHE_VALIDATE=1 \
  -p 8080:80 \
  -v "$(pwd)/app:/var/www/html" \
  practicalwebuser/mod_apex-apache:php8.4
```

`APEX_OPCACHE_VALIDATE` accepts only `0` or `1`:

- `0` is the default for immutable code. Restart the container after deploying
  changed PHP files.
- `1` makes PHP periodically check for changed files. Use it when plugins,
  themes, templates, or other PHP code live on a writable volume.

## PHP security controls

The image does not advertise the PHP version in HTTP responses and starts
sessions with safer cookie defaults:

```ini
expose_php=Off
session.cookie_httponly=1
session.cookie_samesite=Lax
```

Applications can still set their own session cookie parameters when they need
a different SameSite policy.

Apache's `mod_headers` is enabled and the image sends
`X-Content-Type-Options: nosniff` and
`Referrer-Policy: strict-origin-when-cross-origin` on successful and error
responses. It also removes `X-Powered-By` at the Apache layer. Stricter policies
such as CSP, HSTS, framing restrictions, Permissions Policy, and CORS are
provided as disabled examples in
[`docker/security-hardening.conf`](docker/security-hardening.conf), because
their correct values depend on the application, HTTPS termination, and trusted
origins.

For a multi-tenant service that runs customer-supplied PHP, you can disable
operating-system command functions:

```bash
docker run -d --name my-php-app \
  -e APEX_DISABLE_FUNCTIONS=exec,passthru,shell_exec,system,proc_open,popen \
  -e APEX_ALLOW_URL_FOPEN=0 \
  -p 8080:80 \
  practicalwebuser/mod_apex-apache:php8.4
```

`APEX_DISABLE_FUNCTIONS` is empty by default because applications and build
tools may legitimately require `proc_open` or related functions. It accepts a
comma-separated list of PHP function names. `APEX_ALLOW_URL_FOPEN` accepts
only `0` or `1` and defaults to `1` for PHP application compatibility.

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

The image does not publish `/test.php` by default. For a short-lived private
smoke test, set `APEX_ENABLE_TEST_PAGE=1`. The variable accepts only `0` or
`1`. The entrypoint overwrites `/var/www/html/test.php`, so use this only when
that path is disposable and does not belong to the application. It also means
the option cannot be combined with a read-only bind mount over the document
root. If the document root is a writable host mount, the generated file
persists after the container stops: delete `test.php` from the mounted content,
remove the setting, and then expose the container publicly. With a read-only
application mount, provide your own private probe instead.

## Reverse proxies and real visitor addresses

The image includes `mod_remoteip`, but it does not trust any proxy by default.
Set the CIDR of the proxy network that connects directly to the container:

```bash
docker run -d --name my-php-app \
  -e APEX_TRUSTED_PROXY="10.89.0.0/16" \
  -p 8080:80 \
  practicalwebuser/mod_apex-apache:php8.4
```

The entrypoint then configures `X-Forwarded-For` as the client-IP header.
Multiple trusted addresses or CIDRs may be separated by spaces. Never trust
`0.0.0.0/0`; a client that can connect directly could forge its address.

For a Cloudflare → Traefik → PHP Apex chain, configure Traefik to validate
Cloudflare and replace or sanitize the forwarded chain. Otherwise include all
trusted hops, including Cloudflare's current published proxy ranges. Verify
the result in PHP with `$_SERVER['REMOTE_ADDR']` before relying on it for rate
limits or audit logs.

## Apache and PHP settings

The image starts with safe Apache defaults. Add your own Apache settings as a
separate file, so image upgrades stay easy:

```ini
; application.ini
memory_limit=256M
upload_max_filesize=32M
post_max_size=32M
```

```bash
docker run -d --name my-php-app \
  --cpus=2 --memory=2g \
  -p 8080:80 \
  -v "$(pwd)/app:/var/www/html:ro" \
  -v "$(pwd)/application.ini:/usr/local/php-zts/etc/conf.d/90-application.ini:ro" \
  practicalwebuser/mod_apex-apache:php8.4
```

The default virtual host uses `AllowOverride All` so the standard `.htaccess`
files shipped by WordPress, Drupal, and Symfony work without image-specific
rewrites. For a controlled production deployment, moving the application's
rules into the virtual-host configuration and changing this to
`AllowOverride None` provides tighter control and avoids per-request
`.htaccess` discovery. `mod_apex` does not register `php_value` or
`php_admin_value`; use a mounted INI file for PHP settings.

Use your framework's normal configuration for database connections and
sessions. PHP Apex intentionally passes incoming HTTP headers through like
mod_php and PHP-FPM; only the explicitly trusted `mod_remoteip` configuration
changes `REMOTE_ADDR`.

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
