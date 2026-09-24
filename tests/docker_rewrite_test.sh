#!/usr/bin/env bash
set -euo pipefail

image=${1:-practicalwebuser/mod_apex-apache:php8.4}
fixture=$(mktemp -d)
container="mod-apex-rewrite-test-$$"
cleanup() {
    docker rm -f "$container" >/dev/null 2>&1 || true
    rm -rf "$fixture"
}
trap cleanup EXIT

cat > "$fixture/.htaccess" <<'RULES'
RewriteEngine On
RewriteRule ^rewrite-check$ /index.php [L]
RULES
cat > "$fixture/index.php" <<'PHP'
<?php header('Content-Type: text/plain'); echo "rewrite-ok\n";
PHP
printf 'ok\n' > "$fixture/healthz"
chmod -R a+rX "$fixture"

docker run --rm -d --name "$container" -p 127.0.0.1::80 \
    -v "$fixture:/var/www/html:ro" "$image" >/dev/null
port=$(docker port "$container" 80/tcp)
base="http://$port"
ready=0
for attempt in {1..30}; do
    if [[ "$(curl -fsS "$base/healthz" 2>/dev/null || true)" == ok ]]; then
        ready=1
        break
    fi
    sleep 0.2
done
[[ "$ready" == 1 ]] || { docker logs "$container" >&2; exit 1; }
actual=$(curl -fsS "$base/index.php")
[[ "$actual" == rewrite-ok ]] || { echo "direct PHP request failed: $actual" >&2; exit 1; }
actual=$(curl -fsS "$base/rewrite-check")
[[ "$actual" == rewrite-ok ]] || { echo "rewritten PHP request failed: $actual" >&2; exit 1; }
printf 'direct and rewritten PHP requests passed\n'
