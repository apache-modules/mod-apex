<?php
if (isset($_GET['status'])) {
    http_response_code((int) $_GET['status']);
}

$keys = [
    'REQUEST_METHOD',
    'REQUEST_URI',
    'QUERY_STRING',
    'SCRIPT_FILENAME',
    'SCRIPT_NAME',
    'PATH_INFO',
    'DOCUMENT_ROOT',
    'SERVER_PROTOCOL',
    'REQUEST_SCHEME',
    'HTTPS',
    'SERVER_NAME',
    'HTTP_HOST',
    'CONTENT_TYPE',
    'CONTENT_LENGTH',
    'HTTP_AUTHORIZATION',
    'AUTH_TYPE',
    'PHP_AUTH_USER',
    'PHP_AUTH_PW',
    'HTTP_X_FORWARDED_PROTO',
    'HTTP_X_FORWARDED_HOST',
    'HTTP_X_FORWARDED_FOR',
    'HTTP_X_REAL_IP',
    'HTTP_X_CUSTOM_APEX',
    'REMOTE_ADDR',
    'REMOTE_PORT',
    'SERVER_ADDR',
    'SERVER_PORT',
];

foreach ($keys as $k) {
    echo $k . '=' . ($_SERVER[$k] ?? '<missing>') . "\n";
}

echo 'RAW_BODY=' . file_get_contents('php://input') . "\n";

echo "\n";
echo "APP_COMPAT_CHECKS\n";
echo 'HAS_FRONT_CONTROLLER_META=' . ((isset($_SERVER['SCRIPT_FILENAME']) && isset($_SERVER['SCRIPT_NAME'])) ? 'yes' : 'no') . "\n";
echo 'HAS_AUTH_BASIC=' . ((isset($_SERVER['PHP_AUTH_USER']) && isset($_SERVER['PHP_AUTH_PW'])) ? 'yes' : 'no') . "\n";
echo 'HAS_PROXY_META=' . ((isset($_SERVER['HTTP_X_FORWARDED_PROTO']) || isset($_SERVER['HTTP_X_FORWARDED_HOST']) || isset($_SERVER['HTTP_X_FORWARDED_FOR'])) ? 'yes' : 'no') . "\n";
echo 'HAS_PATH_INFO=' . (isset($_SERVER['PATH_INFO']) ? 'yes' : 'no') . "\n";
