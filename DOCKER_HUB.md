# PHP Apex for Apache

**One container. One request path. PHP ready inside Apache.**

`practicalwebuser/mod_apex-apache:php8.4` puts Apache, PHP 8.4 ZTS, and PHP
Apex in one ready-to-run image. PHP executes directly in Apache's worker
threads, so you avoid a separate PHP-FPM container, FastCGI socket, and second
request queue.

Run modern PHP applications with one web service and no separate PHP-FPM
process pool. Keep Apache's event MPM without going back to legacy prefork
mod_php.

The image starts with a balanced 128-worker profile and replaces each Apache
child after 1,000 connections to limit retained per-thread memory growth.
Set an external container memory limit for a firm boundary.

## Everything included

The image is ready with the web server, PHP runtime, module wiring, and common
extensions already together:

- Apache 2.4 using the event MPM
- PHP 8.4.21 ZTS with the embed SAPI
- PHP Apex (`mod_apex`) enabled for `.php` files
- OPcache with JIT support and APCu
- Redis for application caching and sessions
- MySQL support through `mysqli` and PDO MySQL
- SQLite through PDO SQLite
- Imagick and GD with JPEG, PNG, WebP, and FreeType support
- curl, mbstring, intl, fileinfo, EXIF, BCMath, GMP, sodium, SOAP, XML,
  SimpleXML, XMLReader, XMLWriter, XSL, and ZIP
- balanced Apache defaults with a 128-worker limit
- hardened Apache defaults, container-friendly logs, and `/healthz`

The runtime uses Debian Bookworm Slim. Compilers and build tools are not kept
in the published runtime image.

## Start your PHP app

```bash
docker pull practicalwebuser/mod_apex-apache:php8.4
docker run -d --name my-php-app \
  --cpus=4 --memory=2g \
  -p 8080:80 \
  -v "$(pwd)/app:/var/www/html:ro" \
  practicalwebuser/mod_apex-apache:php8.4
```

Open `http://your-server:8080`. Your application belongs in `./app`.

The example mounts application code read-only. If your application writes
uploads, cache files, or generated content, mount only those directories as
separate writable volumes.

## Why PHP Apex

- **One container, one request path.** Apache receives the request and runs
  PHP in the same worker. No PHP-FPM service to deploy, monitor, or tune.
- **Built for Apache event MPM.** Keep Apache's modern threaded request model
  while PHP uses its thread-safe ZTS runtime.
- **PHP stays ready.** Each Apache worker keeps its PHP runtime available for
  the next request instead of handing work across a FastCGI boundary.
- **Bring popular PHP applications.** The image includes OPcache, APCu,
  Redis, Imagick, curl, mbstring, intl, GD, PDO/MySQL, SQLite, zip, sodium,
  GMP, SOAP, XSL, and more.
- **Container-friendly by default.** The image starts with the balanced
  128-worker profile, sends logs to `docker logs`, and includes `/healthz`.

## Run it confidently

Set CPU and memory limits with your container platform. PHP Apex keeps its
balanced 128-worker default unless you explicitly set
`APEX_MAX_REQUEST_WORKERS`. For a 4-CPU, 2 GB container, start with:

```bash
docker run -d --name my-php-app \
  --cpus=4 --memory=2g \
  -p 8080:80 \
  practicalwebuser/mod_apex-apache:php8.4
```

To deliberately change the Apache worker limit, set a whole number from 64 to
512:

```bash
docker run -d --name my-php-app \
  --cpus=4 --memory=2g \
  -e APEX_MAX_REQUEST_WORKERS=256 \
  -p 8080:80 \
  -v "$(pwd)/app:/var/www/html:ro" \
  practicalwebuser/mod_apex-apache:php8.4
```

Start with 128 and raise it only after measuring your application's memory use
and latency under representative traffic.

Check availability without invoking PHP:

```bash
curl -fsS http://127.0.0.1:8080/healthz
docker logs my-php-app
```

`/healthz` is a small static check for container and load-balancer monitoring.
The image also includes `/test.php` for a quick PHP check; mounting your app at
`/var/www/html` replaces it. If you do not mount an application directory,
block or remove that test page before exposing the container publicly.

The image serves HTTP on port 80. Put TLS certificates and public internet
traffic at your reverse proxy or load balancer.

## Image tag

| Tag | Use |
| --- | --- |
| `php8.4` | PHP 8.4, Apache, and PHP Apex |

For repeatable production deployments, pull and test the tag, then pin its
digest in your deployment configuration.

## Need more setup detail?

See the [Docker guide](https://github.com/apache-modules/mod-apex/blob/main/DOCKER.md)
for writable application directories, custom Apache/PHP settings, proxy setup,
and upgrade guidance.

## License

PHP Apex is released under the [Apache License
2.0](https://github.com/apache-modules/mod-apex/blob/main/LICENSE). PHP,
Apache HTTP Server, and bundled extensions retain their respective licenses.
