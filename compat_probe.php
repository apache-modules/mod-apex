<?php
declare(strict_types=1);

header('Content-Type: application/json; charset=UTF-8');

$keys = [
    'REQUEST_METHOD',
    'REQUEST_URI',
    'QUERY_STRING',
    'HTTP_HOST',
    'HTTP_AUTHORIZATION',
    'HTTP_X_WP_NONCE',
    'HTTP_X_CSRF_TOKEN',
    'HTTP_X_REQUESTED_WITH',
    'HTTP_X_FORWARDED_PROTO',
    'HTTP_X_FORWARDED_FOR',
    'HTTP_COOKIE',
];

$out = [];
foreach ($keys as $k) {
    $out[$k] = $_SERVER[$k] ?? null;
}

$out['sapi'] = php_sapi_name();

echo json_encode($out, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES), "\n";
