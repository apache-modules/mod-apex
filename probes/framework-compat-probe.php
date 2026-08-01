<?php
/**
 * framework-compat-probe.php -- mod_apex framework-compatibility probe.
 *
 * Emits KEY=VALUE lines consumed by tools/compat_matrix.sh. Covers the three
 * things the generic $_SERVER probe (common-app-probe.php) does not:
 *
 *   1. The apache2handler shim: because mod_apex reports SAPI name
 *      "apache2handler", frameworks may feature-detect and call the apache_*
 *      family and getallheaders(). These must exist and behave.
 *   2. NO_CHDIR behavior: mod_apex intentionally does not chdir() to the
 *      script directory (thread safety). Legacy relative-include code breaks
 *      by design; this reports the observable behavior so the matrix can
 *      record it per host.
 *   3. Cross-request state: persistent interpreters must still reset
 *      per-request Zend state. A marker set in one request must be absent in
 *      the next (the harness calls this probe twice to check).
 */

header('Content-Type: text/plain; charset=UTF-8');

function line(string $k, string $v): void {
    echo $k, '=', $v, "\n";
}

line('SAPI', php_sapi_name());
line('PHP_VERSION', PHP_VERSION);
line('ZTS', ZEND_THREAD_SAFE ? 'yes' : 'no');
line('OPCACHE_ACTIVE',
    (function_exists('opcache_get_status') && opcache_get_status(false) !== false)
        ? 'yes' : 'no');

/* ---- 1. apache2handler shim ------------------------------------------ */

$shimFns = [
    'getallheaders', 'apache_request_headers', 'apache_response_headers',
    'apache_setenv', 'apache_getenv', 'apache_note',
    'apache_get_version', 'apache_get_modules',
    'apache_lookup_uri', 'virtual',
];
$missing = [];
foreach ($shimFns as $fn) {
    if (!function_exists($fn)) {
        $missing[] = $fn;
    }
}
line('SHIM_FUNCTIONS_PRESENT', $missing === [] ? 'yes' : 'missing:' . implode(',', $missing));

if (function_exists('getallheaders')) {
    $h = getallheaders();
    line('SHIM_GETALLHEADERS_TYPE', is_array($h) ? 'array' : gettype($h));
    line('SHIM_GETALLHEADERS_HAS_HOST',
        (is_array($h) && (isset($h['Host']) || isset($h['host']))) ? 'yes' : 'no');
}

if (function_exists('apache_setenv') && function_exists('apache_getenv')) {
    $ok = apache_setenv('APEX_PROBE_ENV', 'probe-value-42');
    $rt = apache_getenv('APEX_PROBE_ENV');
    line('SHIM_SETENV_ROUNDTRIP',
        ($ok === true && $rt === 'probe-value-42') ? 'yes' : 'no');
}

if (function_exists('apache_note')) {
    apache_note('apex_probe_note', 'n1');
    $prev = apache_note('apex_probe_note', 'n2');
    line('SHIM_NOTE_ROUNDTRIP', $prev === 'n1' ? 'yes' : 'no');
}

if (function_exists('virtual')) {
    /* Expected mod_apex behavior: defined stub, warns, returns false. */
    $r = @virtual('/nonexistent-subrequest');
    line('SHIM_VIRTUAL_RETURNS_FALSE', $r === false ? 'yes' : 'no');
}

/* ---- 2. NO_CHDIR / relative-path behavior ---------------------------- */

$cwd = getcwd();
line('CWD_EQUALS_SCRIPT_DIR', ($cwd !== false && $cwd === __DIR__) ? 'yes' : 'no');

/* A relative fopen of this very file resolves only if cwd == script dir.
 * Under mod_apex (NO_CHDIR) the expected result is 'no' -- the matrix
 * records this as the documented legacy-app caveat, not a failure. */
$rel = @fopen(basename(__FILE__), 'r');
if ($rel !== false) {
    fclose($rel);
    line('RELATIVE_OPEN_RESOLVES', 'yes');
} else {
    line('RELATIVE_OPEN_RESOLVES', 'no');
}

/* ---- 3. Cross-request state isolation -------------------------------- */

/* If a previous request's marker survived into this request, per-request
 * reset is broken. Superglobal + static both checked. */
static $staticMarker = null;
line('PRIOR_GLOBAL_MARKER', isset($GLOBALS['__apex_probe_marker']) ? 'present' : 'absent');
line('PRIOR_STATIC_MARKER', $staticMarker !== null ? 'present' : 'absent');
$GLOBALS['__apex_probe_marker'] = getmypid() . '-' . microtime(true);
$staticMarker = 'set';

/* putenv is process-global by design under threads -- report, don't judge. */
$envProbe = getenv('APEX_PUTENV_PROBE');
line('PRIOR_PUTENV_MARKER', $envProbe !== false ? 'present' : 'absent');
putenv('APEX_PUTENV_PROBE=1');

line('PROBE_COMPLETE', 'yes');
