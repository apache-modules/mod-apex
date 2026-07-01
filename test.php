<?php
header('Content-Type: text/plain');

// Stable smoke endpoint for benchmarks and basic module checks.
echo "OK\n";
echo "sapi=" . php_sapi_name() . "\n";