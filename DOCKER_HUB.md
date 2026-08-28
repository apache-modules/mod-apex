# PHP Apex for Apache

**Run PHP inside Apache. Skip FastCGI. Keep the event MPM.**

`practicalwebuser/mod_apex-apache:php8.4` puts Apache, PHP 8.4 ZTS, and PHP
Apex in one ready-to-run image. PHP executes directly in Apache's worker
threads, so you avoid a separate PHP-FPM container, FastCGI socket, and second
request queue.

It is a straightforward way to run modern PHP applications when you want the
simplicity of one web container without going back to legacy prefork mod_php.

## Start your PHP app

```bash
docker pull practicalwebuser/mod_apex-apache:php8.4
docker run -d --name my-php-app \
  --cpus=4 --memory=1g \
  -p 8080:80 \
  -v "$(pwd)/app:/var/www/html:ro" \
  practicalwebuser/mod_apex-apache:php8.4
```

Open `http://your-server:8080`. Your application belongs in `./app`.

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
- **Container-friendly by default.** The image sizes Apache workers from the
  container CPU limit, sends logs to `docker logs`, and includes `/healthz`.

## Run it confidently

Set CPU and memory limits with your container platform. PHP Apex reads the CPU
limit at startup and chooses a matching Apache worker count. For a 4-CPU,
1 GB container, start with:

```bash
docker run -d --name my-php-app \
  --cpus=4 --memory=1g \
  -p 8080:80 \
  practicalwebuser/mod_apex-apache:php8.4
```

Check availability without invoking PHP:

```bash
curl -fsS http://127.0.0.1:8080/healthz
docker logs my-php-app
```

The image serves HTTP on port 80. Put TLS certificates and public internet
traffic at your reverse proxy or load balancer.

## Image tag

| Tag | Use |
| --- | --- |
| `php8.4` | PHP 8.4, Apache, and PHP Apex |

For repeatable production deployments, pull and test the tag, then pin its
digest in your deployment configuration.

## Need more setup detail?

See the [Docker guide](https://github.com/practicalwebuser/mod_apex/blob/main/DOCKER.md)
for writable application directories, custom Apache/PHP settings, proxy setup,
and upgrade guidance.

## License

PHP Apex is released under the [PolyForm Internal Use License
1.0.0](https://polyformproject.org/licenses/internal-use/1.0.0).
