/*
 * mod_apex.c – Persistent per-thread PHP interpreter for Apache 2.4 + PHP 8.4 (ZTS)
 *
 * Build (example):
 *   APXS=apxs
 *   PHP_PREFIX=/usr/local/php-zts
 *   PHP_CONFIG="$PHP_PREFIX/bin/php-config"
 *   PHP_INC="$($PHP_CONFIG --includes) -I$($PHP_CONFIG --include-dir)/sapi/embed"
 *   $APXS -c -i -a -Wc,"$PHP_INC" -Wl,"-L$PHP_PREFIX/lib -lphp" mod_apex.c
 *
 * This module expects PHP to be built with --enable-embed --enable-maintainer-zts.
 * It uses the event MPM; each thread calls php_request_startup() before a request
 * and php_request_shutdown() afterwards, keeping the Zend engine alive.
 */

#include "httpd.h"
#include "http_config.h"
#include "http_log.h"
#include "http_request.h"
#include "http_protocol.h"
#include "http_core.h"
#include "ap_mpm.h"
#include "ap_config.h"
#include "util_script.h"
#include "apr_strings.h"
#include "apr_time.h"
#include "apr_tables.h"
#include "apr_base64.h"
#include <string.h>
#include <strings.h>
#include <ctype.h>
#include <pthread.h>
#include <unistd.h>

/* PHP embed SAPI */
#include "php_embed.h"
#include "php_variables.h"
#include "TSRM/TSRM.h"
#include "main/php_globals.h"
#include "Zend/zend_globals.h"

#if !defined(PHP_VERSION_ID) || PHP_VERSION_ID < 80400
# error "mod_apex requires PHP 8.4+ with ZTS and embed SAPI"
#endif

#define APEX_REQUEST_SHUTDOWN() php_request_shutdown(NULL)

/* Per-process flag; each Apache child process initializes its own embed engine. */
static int apex_engine_started = 0;

/* Forward declaration; the module record is defined at the end of this file. */
extern module AP_MODULE_DECLARE_DATA apex_module;

/* --------------------------------------------------------------------- */
/* Per‑server configuration                                                */
/* --------------------------------------------------------------------- */
typedef struct {
    int debug_errors;      /* ApexVerboseErrors: include diagnostic detail in error responses */
    int debug_errors_set;  /* whether debug_errors was explicitly configured (for vhost merge) */
} apex_config;

static const apex_config *apex_get_config(const request_rec *r)
{
    if (!r || !r->server) {
        return NULL;
    }
    return (const apex_config *) ap_get_module_config(r->server->module_config, &apex_module);
}

/* --------------------------------------------------------------------- */
/* Per‑request context – stored in SG(server_context) (thread‑local)      */
/* --------------------------------------------------------------------- */
typedef struct {
    request_rec *r;               /* Apache request pointer                */
    apr_off_t    request_body_len;/* Content-Length when known, else -1    */
    int          body_ready;      /* ap_setup_client_block completed        */
    int          body_eof;        /* client body fully consumed             */
    apr_off_t    read_post_bytes; /* bytes read from client body via SAPI   */
    apr_off_t    ub_write_bytes;  /* bytes written to Apache output filters */
    apr_off_t    ub_write_calls;  /* total ub_write callback invocations     */
    apr_off_t    ub_write_failures; /* failed ub_write attempts              */
    apr_off_t    ub_write_skipped_aborted; /* skipped due to aborted conn   */
    apr_off_t    flush_calls;     /* total flush callback invocations        */
    apr_off_t    flush_failures;  /* failed flush attempts                   */
    apr_off_t    flush_skipped_aborted; /* skipped flush on aborted conn    */
    apr_off_t    last_flushed_ub_write_bytes; /* last successful flush mark   */
} apex_ctx_t;

static int apex_connection_is_aborted(const apex_ctx_t *ctx)
{
    return (ctx && ctx->r && ctx->r->connection && ctx->r->connection->aborted);
}

static int apex_parse_header_line(request_rec *r,
                                  const char *header_line,
                                  const char **name_out,
                                  const char **value_out)
{
    char *line;
    char *colon;
    char *name_end;
    char *value;
    char *value_end;

    if (!r || !header_line) {
        return 0;
    }

    line = apr_pstrdup(r->pool, header_line);
    if (!line) {
        return 0;
    }

    colon = strchr(line, ':');
    if (!colon) {
        return 0;
    }

    *colon = '\0';
    value = colon + 1;
    while (*value && isspace((unsigned char) *value)) {
        value++;
    }

    name_end = line + strlen(line);
    while (name_end > line && isspace((unsigned char) name_end[-1])) {
        *--name_end = '\0';
    }

    value_end = value + strlen(value);
    while (value_end > value && isspace((unsigned char) value_end[-1])) {
        *--value_end = '\0';
    }

    if (*line == '\0') {
        return 0;
    }

    *name_out = line;
    *value_out = value;
    return 1;
}

static void apex_clear_php_request_info(void)
{
    SG(request_info).request_uri = NULL;
    SG(request_info).request_method = NULL;
    SG(request_info).query_string = NULL;
    SG(request_info).path_translated = NULL;
    SG(request_info).content_type = NULL;
    SG(request_info).content_length = 0;
    SG(read_post_bytes) = 0;
}

static void apex_set_response_status(request_rec *r, int status_code)
{
    if (!r || status_code < 100 || status_code > 599) {
        return;
    }

    r->status = status_code;
    r->status_line = ap_get_status_line(status_code);
}

static void apex_send_fatal_error_page(request_rec *r, const char *message)
{
    const char *body;
    const apex_config *cfg;

    if (!r || !message) {
        return;
    }

    if (r->content_type || r->status >= 200 || r->status < 0) {
        return;
    }

    cfg = apex_get_config(r);

    /* Detailed diagnostics are opt-in (ApexVerboseErrors On) to avoid leaking
     * internal implementation details to clients by default (CWE-209). */
    if (cfg && cfg->debug_errors) {
        body = apr_psprintf(r->pool,
                            "mod_apex could not complete this request.\n\n"
                            "%s\n\n"
                            "This may indicate that PHP, a plugin, or an extension is not compatible with apex or ZTS.\n",
                            message);
    } else {
        body = "The server encountered an error processing this request.\n";
    }

    apex_set_response_status(r, HTTP_INTERNAL_SERVER_ERROR);
    ap_set_content_type(r, "text/plain; charset=UTF-8");
    ap_rputs(body, r);
}

/* --------------------------------------------------------------------- */
/* PHP SAPI callbacks                                                     */
/* --------------------------------------------------------------------- */

/* Write output to the client */
static size_t apex_ub_write(const char *str, size_t str_length)
{
    apex_ctx_t *ctx = (apex_ctx_t *) SG(server_context);
    size_t total_written = 0;

    if (!ctx || !ctx->r || !str || str_length == 0) {
        return 0;
    }

    ctx->ub_write_calls++;

    if (apex_connection_is_aborted(ctx)) {
        ctx->ub_write_skipped_aborted++;
        return 0;
    }

    while (total_written < str_length) {
        size_t remaining = str_length - total_written;
        int chunk = (remaining > (size_t) INT_MAX) ? INT_MAX : (int) remaining;
        int written = ap_rwrite(str + total_written, chunk, ctx->r);

        if (written <= 0) {
            ctx->ub_write_failures++;
            break;
        }

        total_written += (size_t) written;
        ctx->ub_write_bytes += (apr_off_t) written;

        if (written < chunk) {
            break;
        }
    }

    return total_written;
}

/* Flush output to the client */
static void apex_flush(void *server_context)
{
    apex_ctx_t *ctx = (apex_ctx_t *) server_context;
    if (ctx && ctx->r) {
        ctx->flush_calls++;

        if (apex_connection_is_aborted(ctx)) {
            ctx->flush_skipped_aborted++;
            return;
        }

        /* Skip flushes when no new bytes were written since the last flush. */
        if (ctx->ub_write_bytes == ctx->last_flushed_ub_write_bytes) {
            return;
        }

        if (ap_rflush(ctx->r) != APR_SUCCESS) {
            ctx->flush_failures++;
            return;
        }

        ctx->last_flushed_ub_write_bytes = ctx->ub_write_bytes;
    }
}

static char *apex_read_cookies(void)
{
    apex_ctx_t *ctx = (apex_ctx_t *) SG(server_context);
    const char *cookie;

    if (!ctx || !ctx->r) {
        return NULL;
    }

    cookie = apr_table_get(ctx->r->headers_in, "Cookie");
    return (char *) cookie;
}

/* Feed the POST body to PHP (called when script reads php://input) */
static size_t apex_read_post(char *buffer, size_t count_bytes)
{
    apex_ctx_t *ctx = (apex_ctx_t *) SG(server_context);
    long bytes_read;

    if (!ctx || !ctx->r || !ctx->body_ready || ctx->body_eof || !buffer || count_bytes == 0) {
        return 0;
    }

    bytes_read = ap_get_client_block(ctx->r, buffer, (apr_size_t) count_bytes);
    if (bytes_read <= 0) {
        ctx->body_eof = 1;
        return 0;
    }

    ctx->read_post_bytes += (apr_off_t) bytes_read;

    return (size_t) bytes_read;
}

/* Add/modify response headers */
static int apex_header_handler(sapi_header_struct *sapi_header,
                               sapi_header_op_enum op,
                               sapi_headers_struct *sapi_headers)
{
    (void) sapi_headers;

    apex_ctx_t *ctx = (apex_ctx_t *) SG(server_context);
    if (!ctx || !ctx->r) return 0;

    switch (op) {
    case SAPI_HEADER_DELETE_ALL:
        apr_table_clear(ctx->r->headers_out);
        ctx->r->content_type = NULL;
        return 0;

    case SAPI_HEADER_DELETE:
        if (!strcasecmp(sapi_header->header, "content-type")) {
            ctx->r->content_type = NULL;
        }
        apr_table_unset(ctx->r->headers_out, sapi_header->header);
        return 0;

    case SAPI_HEADER_ADD:
    case SAPI_HEADER_REPLACE: {
        const char *name;
        const char *value;
        long status_code;
        char *status_end;

        if (!apex_parse_header_line(ctx->r, sapi_header->header, &name, &value)) {
            return 0;
        }

        if (!strcasecmp(name, "content-type")) {
            ap_set_content_type(ctx->r, value);
        } else if (!strcasecmp(name, "status")) {
            status_code = strtol(value, &status_end, 10);
            if (status_end != value && status_code >= 100 && status_code <= 599) {
                  apex_set_response_status(ctx->r, (int) status_code);
            }
        } else if (!strcasecmp(name, "set-cookie")) {
            apr_table_add(ctx->r->headers_out, name, value);
        } else if (op == SAPI_HEADER_REPLACE) {
            apr_table_set(ctx->r->headers_out, name, value);
        } else {
            apr_table_add(ctx->r->headers_out, name, value);
        }

        return SAPI_HEADER_ADD;
    }

    case SAPI_HEADER_SET_STATUS:
        if (ctx->r && sapi_headers->http_response_code >= 100 &&
            sapi_headers->http_response_code <= 599) {
            apex_set_response_status(ctx->r, sapi_headers->http_response_code);
        }
        return 0;

    default:
        return 0;
    }
}

static int apex_send_headers(sapi_headers_struct *sapi_headers)
{
    apex_ctx_t *ctx = (apex_ctx_t *) SG(server_context);
    if (ctx && ctx->r && sapi_headers->http_response_code > 0) {
        apex_set_response_status(ctx->r, sapi_headers->http_response_code);
    }
    return SAPI_HEADER_SENT_SUCCESSFULLY;
}

static void apex_register_server_variable(zval *track_vars_array,
                                          const char *name,
                                          const char *value)
{
    if (!track_vars_array || !name || !value) {
        return;
    }

    php_register_variable_safe((char *) name,
                               (char *) value,
                               strlen(value),
                               track_vars_array);
}

static void apex_register_authorization_variables(request_rec *r, zval *track_vars_array)
{
    const char *auth;

    if (!r || !track_vars_array) {
        return;
    }

    auth = apr_table_get(r->headers_in, "Authorization");
    if (!auth || !*auth) {
        return;
    }

    apex_register_server_variable(track_vars_array, "HTTP_AUTHORIZATION", auth);

    if (!strncasecmp(auth, "Basic ", 6)) {
        const char *payload = auth + 6;
        int decoded_len = apr_base64_decode_len(payload);
        char *decoded;
        char *sep;

        if (decoded_len <= 0) {
            return;
        }

        decoded = (char *) apr_palloc(r->pool, (apr_size_t) decoded_len + 1);
        if (!decoded) {
            return;
        }

        decoded_len = apr_base64_decode(decoded, payload);
        if (decoded_len <= 0) {
            return;
        }

        decoded[decoded_len] = '\0';
        sep = strchr(decoded, ':');

        apex_register_server_variable(track_vars_array, "AUTH_TYPE", "Basic");

        if (sep) {
            *sep = '\0';
            apex_register_server_variable(track_vars_array, "PHP_AUTH_USER", decoded);
            apex_register_server_variable(track_vars_array, "PHP_AUTH_PW", sep + 1);
        }
    } else if (!strncasecmp(auth, "Bearer ", 7)) {
        apex_register_server_variable(track_vars_array, "AUTH_TYPE", "Bearer");
    }
}

static int apex_header_name_char(char c)
{
    return ((c >= 'a' && c <= 'z') ||
            (c >= 'A' && c <= 'Z') ||
            (c >= '0' && c <= '9') ||
            c == '-');
}

static void apex_register_http_header_variables(request_rec *r, zval *track_vars_array)
{
    const apr_array_header_t *hdr_arr;
    const apr_table_entry_t *hdr_elts;
    int i;

    if (!r || !track_vars_array) {
        return;
    }

    hdr_arr = apr_table_elts(r->headers_in);
    hdr_elts = (const apr_table_entry_t *) hdr_arr->elts;

    for (i = 0; i < hdr_arr->nelts; i++) {
        const char *key = hdr_elts[i].key;
        const char *val = hdr_elts[i].val;
        char *var;
        size_t klen;
        size_t j;

        if (!key || !*key || !val) {
            continue;
        }

        if (!strcasecmp(key, "Content-Type") || !strcasecmp(key, "Content-Length")) {
            continue;
        }

        klen = strlen(key);
        var = apr_palloc(r->pool, klen + sizeof("HTTP_"));
        if (!var) {
            continue;
        }

        memcpy(var, "HTTP_", 5);
        for (j = 0; j < klen; j++) {
            char c = key[j];

            if (!apex_header_name_char(c)) {
                break;
            }

            if (c == '-') {
                var[5 + j] = '_';
            } else if (c >= 'a' && c <= 'z') {
                var[5 + j] = (char) (c - ('a' - 'A'));
            } else {
                var[5 + j] = c;
            }
        }

        if (j != klen) {
            continue;
        }

        var[5 + klen] = '\0';

        apex_register_server_variable(track_vars_array, var, val);
    }
}

static void apex_register_server_variables(zval *track_vars_array)
{
    apex_ctx_t *ctx = (apex_ctx_t *) SG(server_context);
    request_rec *r;
    const char *content_type;
    const char *content_length;
    const apr_array_header_t *env_arr;
    apr_table_entry_t *env_elts;
    int i;

    if (!ctx || !ctx->r || !track_vars_array) {
        return;
    }

    r = ctx->r;

    /* Reuse Apache's CGI/common var generation for broad app compatibility. */
    ap_add_common_vars(r);
    ap_add_cgi_vars(r);

    env_arr = apr_table_elts(r->subprocess_env);
    env_elts = (apr_table_entry_t *) env_arr->elts;

    for (i = 0; i < env_arr->nelts; i++) {
        if (!env_elts[i].key || !env_elts[i].val) {
            continue;
        }

        apex_register_server_variable(track_vars_array,
                                      env_elts[i].key,
                                      env_elts[i].val);
    }

    apex_register_server_variable(track_vars_array, "REQUEST_SCHEME", ap_http_scheme(r));
    apex_register_server_variable(track_vars_array,
                                  "HTTPS",
                                  !strcasecmp(ap_http_scheme(r), "https") ? "on" : "off");
    apex_register_server_variable(track_vars_array, "SERVER_NAME", ap_get_server_name(r));
    if (r->uri && *r->uri) {
        apex_register_server_variable(track_vars_array, "PHP_SELF", r->uri);
    }

    content_type = apr_table_get(r->headers_in, "Content-Type");
    if (content_type && *content_type) {
        apex_register_server_variable(track_vars_array, "CONTENT_TYPE", content_type);
    }

    content_length = apr_table_get(r->headers_in, "Content-Length");
    if (content_length && *content_length) {
        apex_register_server_variable(track_vars_array, "CONTENT_LENGTH", content_length);
    } else if (ctx->request_body_len >= 0) {
        apex_register_server_variable(track_vars_array,
                                      "CONTENT_LENGTH",
                                      apr_psprintf(r->pool, "%" APR_OFF_T_FMT,
                                                   ctx->request_body_len));
    }

    if (r->path_info && *r->path_info) {
        apex_register_server_variable(track_vars_array, "PATH_INFO", r->path_info);
    }

    if (r->user && *r->user) {
        apex_register_server_variable(track_vars_array, "REMOTE_USER", r->user);
    }

    /* X-Forwarded-* and X-Real-IP arrive via the generic header loop above like
     * any other client header (matching mod_php/PHP-FPM behavior). Do not treat
     * them as trusted here: use Apache's mod_remoteip for REMOTE_ADDR
     * correctness, and validate at the application/framework layer instead. */
    apex_register_authorization_variables(r, track_vars_array);
    apex_register_http_header_variables(r, track_vars_array);
}

/* --------------------------------------------------------------------- */
/* Internal helpers (Phase 1: structure only, no behavior change)        */
/* --------------------------------------------------------------------- */
static int apex_is_supported_handler(const request_rec *r)
{
    if (!r || !r->handler) {
        return 0;
    }

    if (!strcmp(r->handler, "php-script") ||
        !strcmp(r->handler, "application/x-httpd-php")) {
        return 1;
    }

    return 0;
}

static int apex_is_php_filename(const char *filename)
{
    size_t len;

    if (!filename) {
        return 0;
    }

    len = strlen(filename);
    return (len >= 4 && !strcasecmp(filename + len - 4, ".php"));
}

static void apex_ensure_worker_tsrm_context(void)
{
#ifdef ZTS
    /* Bind this worker thread's TSRM resources once. After the first request
     * on a thread, the resources and the TSRMLS cache pointer persist for the
     * life of the thread, so repeating ts_resource_ex() every request is
     * wasted work under high concurrency. */
    static __thread int apex_tsrm_bound = 0;
    if (apex_tsrm_bound) {
        return;
    }
    (void) ts_resource_ex(core_globals_id, NULL);
    (void) ts_resource_ex(sapi_globals_id, NULL);
    (void) ts_resource_ex(executor_globals_id, NULL);
    (void) ts_resource_ex(compiler_globals_id, NULL);
# ifdef ZEND_ENABLE_STATIC_TSRMLS_CACHE
    ZEND_TSRMLS_CACHE_UPDATE();
# endif
    apex_tsrm_bound = 1;
#endif
}

static int apex_prepare_request_context(request_rec *r, apex_ctx_t *ctx)
{
    int setup_rc;

    memset(ctx, 0, sizeof(*ctx));
    ctx->r = r;
    ctx->request_body_len = (r->remaining >= 0) ? r->remaining : -1;

    if (r->method_number != M_POST && r->method_number != M_PUT) {
        return OK;
    }

    setup_rc = ap_setup_client_block(r, REQUEST_CHUNKED_DECHUNK);
    if (setup_rc != OK) {
        return setup_rc;
    }
    ctx->body_ready = 1;

    if (!ap_should_client_block(r)) {
        ctx->body_eof = 1;
        return OK;
    }

    return OK;
}

static void apex_populate_php_request_info(request_rec *r, apex_ctx_t *ctx)
{
    SG(server_context) = (void *) ctx;

    memset(&SG(request_info), 0, sizeof(SG(request_info)));

    SG(request_info).request_uri     = r->unparsed_uri ? r->unparsed_uri : r->uri;
    SG(request_info).request_method  = r->method;
    SG(request_info).query_string    = r->args;
    SG(request_info).path_translated = r->filename;
    SG(request_info).content_type    = apr_table_get(r->headers_in, "Content-Type");
    SG(request_info).content_length  = ctx->request_body_len;
    SG(request_info).proto_num       = r->proto_num;
    SG(read_post_bytes)              = 0;
}

static int apex_execute_php_file(const char *filename)
{
    zend_file_handle file_handle;
    zend_stream_init_filename(&file_handle, filename);
    file_handle.type = ZEND_HANDLE_FILENAME;
    file_handle.primary_script = 1;

    int status = php_execute_script(&file_handle);

    zend_destroy_file_handle(&file_handle);
    return status;
}

/* --------------------------------------------------------------------- */
/* Apache handler – run the PHP script                                    */
/* --------------------------------------------------------------------- */
static int apex_handler(request_rec *r)
{
    apr_time_t startup_begin = 0;
    apr_time_t startup_end = 0;
    apr_time_t execute_end = 0;
    apr_time_t shutdown_end = 0;

    /* Fail fast on .php files with incorrect handler mapping. */
    if (r && apex_is_php_filename(r->filename) && !apex_is_supported_handler(r)) {
        ap_log_rerror(APLOG_MARK, APLOG_ERR, 0, r,
                      "mod_apex: .php request rejected due to invalid handler mapping (handler=%s)",
                      r->handler ? r->handler : "(null)");
        return HTTP_INTERNAL_SERVER_ERROR;
    }

    /* We only handle files that are mapped to supported PHP handlers. */
    if (!apex_is_supported_handler(r))
        return DECLINED;

    if (!r->filename || !ap_is_initial_req(r))
        return DECLINED;

    /* Only execute regular files. If Apache already stat'd the target and it
     * is a known non-regular type (e.g. a directory), return 404 rather than
     * handing a non-file path to PHP. APR_NOFILE means "not stat'd/unknown",
     * so leave that case to the normal execution path (preserves front-
     * controller PATH_INFO behavior like /index.php/foo). */
    if (r->finfo.filetype != APR_NOFILE && r->finfo.filetype != APR_REG) {
        return HTTP_NOT_FOUND;
    }

    if (!apex_engine_started) {
        ap_log_rerror(APLOG_MARK, APLOG_CRIT, 0, r,
                      "mod_apex: PHP engine not initialized in child process");
        return HTTP_INTERNAL_SERVER_ERROR;
    }

    /* Binds this thread's TSRM resources and updates the TSRMLS cache pointer
     * on first call per worker thread (see apex_ensure_worker_tsrm_context). */
    apex_ensure_worker_tsrm_context();

    /* ===== 1. Prepare request context ===== */
    apex_ctx_t ctx;
    int prep_status = apex_prepare_request_context(r, &ctx);
    if (prep_status != OK) {
        ap_log_rerror(APLOG_MARK, APLOG_ERR, 0, r,
                      "mod_apex: request body preparation failed (%d)", prep_status);
        apex_send_fatal_error_page(r, "request preparation failed");
        return prep_status;
    }
    apex_populate_php_request_info(r, &ctx);

    /* ===== 2. Start a fresh request and execute the script, guarded against
     * Zend bailouts (E_ERROR, memory exhaustion, exit()). php_execute_script()
     * catches bailouts raised *inside* script execution itself, but a bailout
     * during php_request_startup() or file-handle setup would otherwise
     * longjmp with no matching setjmp on this thread and crash the shared
     * child process -- taking down every worker thread's in-flight request.
     * volatile: these are read after the setjmp target, so they must survive
     * a longjmp. ===== */
    volatile int startup_ok = 0;
    volatile int status = SUCCESS;

    startup_begin = apr_time_now();
    zend_first_try {
        if (php_request_startup() == FAILURE) {
            ap_log_rerror(APLOG_MARK, APLOG_CRIT, 0, r,
                          "mod_apex: php_request_startup() failed");
        } else {
            startup_ok = 1;
            startup_end = apr_time_now();

            /* Threaded MPM safety: php_execute_script() would otherwise
             * chdir() the *process* working directory to the script's dir on
             * every request. CWD is process-global, so under mpm_event's many
             * worker threads that is a data race that corrupts relative path
             * resolution (includes, fopen, file_get_contents) across
             * concurrent requests. SAPI_OPTION_NO_CHDIR disables it. */
            SG(options) |= SAPI_OPTION_NO_CHDIR;

            status = apex_execute_php_file(r->filename);
            execute_end = apr_time_now();
        }
    } zend_end_try();

    if (!startup_ok) {
        /* Startup failed or bailed: unwind the request (guarded so a second
         * bailout cannot escape either) and return a controlled 500. */
        zend_try {
            apex_clear_php_request_info();
            APEX_REQUEST_SHUTDOWN();
        } zend_end_try();
        SG(server_context) = NULL;
        apex_send_fatal_error_page(r, "PHP request startup failed");
        return HTTP_INTERNAL_SERVER_ERROR;
    }

    /* ===== 3. Finish the request ===== */
    if (!r->content_type) {
        ap_set_content_type(r, "text/html; charset=UTF-8");
    }

    /* ===== 4. Reset per-request Zend state for the next request. Guarded
     * because user shutdown functions and object destructors run here and can
     * bail. Note: process-global state reachable from PHP (putenv/setlocale/
     * umask and non-thread-safe extension globals) is NOT and cannot be reset
     * per thread -- see README compatibility notes. ===== */
    zend_try {
        apex_clear_php_request_info();
        APEX_REQUEST_SHUTDOWN();
    } zend_end_try();
    shutdown_end = apr_time_now();
    SG(server_context) = NULL;

    ap_log_rerror(APLOG_MARK, APLOG_TRACE1, 0, r,
                  "mod_apex: timing_us startup=%" APR_TIME_T_FMT " execute=%" APR_TIME_T_FMT " shutdown=%" APR_TIME_T_FMT
                  " read_post_bytes=%" APR_OFF_T_FMT " ub_write_bytes=%" APR_OFF_T_FMT
                  " ub_write_calls=%" APR_OFF_T_FMT " ub_write_failures=%" APR_OFF_T_FMT " ub_write_skipped_aborted=%" APR_OFF_T_FMT
                  " flush_calls=%" APR_OFF_T_FMT " flush_failures=%" APR_OFF_T_FMT " flush_skipped_aborted=%" APR_OFF_T_FMT,
                  startup_end - startup_begin,
                  execute_end - startup_end,
                  shutdown_end - execute_end,
                  ctx.read_post_bytes,
                  ctx.ub_write_bytes,
                  ctx.ub_write_calls,
                  ctx.ub_write_failures,
                  ctx.ub_write_skipped_aborted,
                  ctx.flush_calls,
                  ctx.flush_failures,
                  ctx.flush_skipped_aborted);

    if (status == FAILURE) {
        ap_log_rerror(APLOG_MARK, APLOG_ERR, 0, r,
                      "mod_apex: script execution failed for %s", r->filename);
        apex_send_fatal_error_page(r, "PHP script execution failed");
        return HTTP_INTERNAL_SERVER_ERROR;
    }

    return OK;
}

/* --------------------------------------------------------------------- */
/* apache2handler compatibility shim                                       */
/*                                                                         */
/* Because mod_apex reports the SAPI name as "apache2handler" (to unlock    */
/* OPcache), application code and frameworks may call the apache_* family   */
/* and getallheaders() -- functions the stock embed SAPI does not provide,  */
/* which would otherwise be an "undefined function" fatal. We register      */
/* compatible implementations through the SAPI additional_functions table   */
/* (the same mechanism the CLI/CGI SAPIs use to add SAPI-specific           */
/* functions). php_module_startup(), reached via php_embed_init(),          */
/* registers these against the "standard" module for every child process.   */
/* --------------------------------------------------------------------- */

static request_rec *apex_current_request(void)
{
    apex_ctx_t *ctx = (apex_ctx_t *) SG(server_context);
    return ctx ? ctx->r : NULL;
}

static void apex_add_table_to_array(zval *arr, const apr_table_t *tbl)
{
    const apr_array_header_t *hdr;
    const apr_table_entry_t *elts;
    int i;

    if (!tbl) {
        return;
    }

    hdr  = apr_table_elts(tbl);
    elts = (const apr_table_entry_t *) hdr->elts;
    for (i = 0; i < hdr->nelts; i++) {
        if (!elts[i].key || !elts[i].val) {
            continue;
        }
        add_assoc_string(arr, elts[i].key, (char *) elts[i].val);
    }
}

/* getallheaders() / apache_request_headers(): request headers as an array */
PHP_FUNCTION(apex_getallheaders)
{
    request_rec *r;

    ZEND_PARSE_PARAMETERS_NONE();

    array_init(return_value);
    r = apex_current_request();
    if (r) {
        apex_add_table_to_array(return_value, r->headers_in);
    }
}

/* apache_response_headers(): response headers as an array */
PHP_FUNCTION(apex_apache_response_headers)
{
    request_rec *r;

    ZEND_PARSE_PARAMETERS_NONE();

    array_init(return_value);
    r = apex_current_request();
    if (!r) {
        return;
    }

    if (r->content_type) {
        add_assoc_string(return_value, "Content-Type", (char *) r->content_type);
    }
    apex_add_table_to_array(return_value, r->headers_out);
    apex_add_table_to_array(return_value, r->err_headers_out);
}

/* apache_setenv(string $variable, string $value, bool $walk_to_top = false) */
PHP_FUNCTION(apex_apache_setenv)
{
    char *name, *value;
    size_t name_len, value_len;
    bool walk_to_top = 0;
    request_rec *r, *target;

    ZEND_PARSE_PARAMETERS_START(2, 3)
        Z_PARAM_STRING(name, name_len)
        Z_PARAM_STRING(value, value_len)
        Z_PARAM_OPTIONAL
        Z_PARAM_BOOL(walk_to_top)
    ZEND_PARSE_PARAMETERS_END();

    r = apex_current_request();
    if (!r) {
        RETURN_FALSE;
    }

    target = r;
    if (walk_to_top) {
        while (target->main) {
            target = target->main;
        }
    }

    apr_table_set(target->subprocess_env, name, value);
    RETURN_TRUE;
}

/* apache_getenv(string $variable, bool $walk_to_top = false): string|false */
PHP_FUNCTION(apex_apache_getenv)
{
    char *name;
    size_t name_len;
    bool walk_to_top = 0;
    request_rec *r, *target;
    const char *value;

    ZEND_PARSE_PARAMETERS_START(1, 2)
        Z_PARAM_STRING(name, name_len)
        Z_PARAM_OPTIONAL
        Z_PARAM_BOOL(walk_to_top)
    ZEND_PARSE_PARAMETERS_END();

    r = apex_current_request();
    if (!r) {
        RETURN_FALSE;
    }

    target = r;
    if (walk_to_top) {
        while (target->main) {
            target = target->main;
        }
    }

    value = apr_table_get(target->subprocess_env, name);
    if (!value) {
        RETURN_FALSE;
    }
    RETURN_STRING(value);
}

/* apache_note(string $note_name, ?string $note_value = null): string|false */
PHP_FUNCTION(apex_apache_note)
{
    char *name, *value = NULL;
    size_t name_len, value_len = 0;
    request_rec *r;
    const char *old_value;

    ZEND_PARSE_PARAMETERS_START(1, 2)
        Z_PARAM_STRING(name, name_len)
        Z_PARAM_OPTIONAL
        Z_PARAM_STRING_OR_NULL(value, value_len)
    ZEND_PARSE_PARAMETERS_END();

    r = apex_current_request();
    if (!r) {
        RETURN_FALSE;
    }

    old_value = apr_table_get(r->notes, name);
    if (value) {
        apr_table_set(r->notes, name, value);
    }

    if (!old_value) {
        RETURN_EMPTY_STRING();
    }
    RETURN_STRING(old_value);
}

/* apache_get_version(): string */
PHP_FUNCTION(apex_apache_get_version)
{
    ZEND_PARSE_PARAMETERS_NONE();
    RETURN_STRING(ap_get_server_banner());
}

/* apache_get_modules(): array */
PHP_FUNCTION(apex_apache_get_modules)
{
    int i;

    ZEND_PARSE_PARAMETERS_NONE();

    array_init(return_value);
    for (i = 0; ap_loaded_modules[i] != NULL; i++) {
        add_next_index_string(return_value, ap_loaded_modules[i]->name);
    }
}

/* apache_lookup_uri() / virtual(): inline Apache subrequests are not
 * supported under the persistent-interpreter model (the handler declines
 * subrequests). Provide defined stubs that warn and return false rather
 * than fataling with an undefined function. */
PHP_FUNCTION(apex_apache_lookup_uri)
{
    char *uri;
    size_t uri_len;

    ZEND_PARSE_PARAMETERS_START(1, 1)
        Z_PARAM_STRING(uri, uri_len)
    ZEND_PARSE_PARAMETERS_END();

    php_error_docref(NULL, E_WARNING,
        "apache_lookup_uri() is not supported by mod_apex");
    RETURN_FALSE;
}

PHP_FUNCTION(apex_virtual)
{
    char *uri;
    size_t uri_len;

    ZEND_PARSE_PARAMETERS_START(1, 1)
        Z_PARAM_STRING(uri, uri_len)
    ZEND_PARSE_PARAMETERS_END();

    php_error_docref(NULL, E_WARNING,
        "virtual() is not supported by mod_apex; use an HTTP subrequest instead");
    RETURN_FALSE;
}

ZEND_BEGIN_ARG_INFO_EX(apex_arginfo_none, 0, 0, 0)
ZEND_END_ARG_INFO()

ZEND_BEGIN_ARG_INFO_EX(apex_arginfo_setenv, 0, 0, 2)
    ZEND_ARG_INFO(0, variable)
    ZEND_ARG_INFO(0, value)
    ZEND_ARG_INFO(0, walk_to_top)
ZEND_END_ARG_INFO()

ZEND_BEGIN_ARG_INFO_EX(apex_arginfo_getenv, 0, 0, 1)
    ZEND_ARG_INFO(0, variable)
    ZEND_ARG_INFO(0, walk_to_top)
ZEND_END_ARG_INFO()

ZEND_BEGIN_ARG_INFO_EX(apex_arginfo_note, 0, 0, 1)
    ZEND_ARG_INFO(0, note_name)
    ZEND_ARG_INFO(0, note_value)
ZEND_END_ARG_INFO()

ZEND_BEGIN_ARG_INFO_EX(apex_arginfo_uri, 0, 0, 1)
    ZEND_ARG_INFO(0, uri)
ZEND_END_ARG_INFO()

static const zend_function_entry apex_additional_functions[] = {
    ZEND_NAMED_FE(getallheaders,           ZEND_FN(apex_getallheaders),           apex_arginfo_none)
    ZEND_NAMED_FE(apache_request_headers,  ZEND_FN(apex_getallheaders),           apex_arginfo_none)
    ZEND_NAMED_FE(apache_response_headers, ZEND_FN(apex_apache_response_headers),  apex_arginfo_none)
    ZEND_NAMED_FE(apache_setenv,           ZEND_FN(apex_apache_setenv),           apex_arginfo_setenv)
    ZEND_NAMED_FE(apache_getenv,           ZEND_FN(apex_apache_getenv),           apex_arginfo_getenv)
    ZEND_NAMED_FE(apache_note,             ZEND_FN(apex_apache_note),             apex_arginfo_note)
    ZEND_NAMED_FE(apache_get_version,      ZEND_FN(apex_apache_get_version),      apex_arginfo_none)
    ZEND_NAMED_FE(apache_get_modules,      ZEND_FN(apex_apache_get_modules),      apex_arginfo_none)
    ZEND_NAMED_FE(apache_lookup_uri,       ZEND_FN(apex_apache_lookup_uri),       apex_arginfo_uri)
    ZEND_NAMED_FE(virtual,                 ZEND_FN(apex_virtual),                 apex_arginfo_uri)
    ZEND_FE_END
};

/* --------------------------------------------------------------------- */
/* Module initialisation                                                  */
/* --------------------------------------------------------------------- */

/* Called once after configuration – start the whole PHP engine */
static int apex_post_config(apr_pool_t *pconf, apr_pool_t *plog,
                            apr_pool_t *ptemp, server_rec *s)
{
    (void) pconf;
    (void) plog;
    (void) ptemp;

    /* OPcache's accelerator only activates for a hardcoded allowlist of SAPI
     * names (accel_find_sapi() in ext/opcache/ZendAccelerator.c: "apache",
     * "apache2handler", "fastcgi", "cgi-fcgi", "fpm-fcgi", "litespeed",
     * "uwsgi", "frankenphp", "ngx-php", "cli-server", or "cli"/"phpdbg" with
     * opcache.enable_cli). The stock "embed" SAPI name is not on that list,
     * so OPcache silently disables itself (opcache_get_status() returns
     * false) no matter what ini settings are used -- confirmed via a
     * standalone embed-SAPI probe outside of Apache/mod_apex entirely.
     * mod_apex's actual request lifecycle (one php_module_startup() at
     * child_init, per-request php_request_startup()/php_request_shutdown())
     * matches the same "single MINIT, many RINIT" model the allowlisted
     * SAPIs use, so it is safe to report a matching name here to unlock the
     * accelerator. This must run before php_embed_init() (called later in
     * apex_child_init()); post_config runs once in the parent before Apache
     * forks children, so the override is inherited by every child process. */
    php_embed_module.name        = "apache2handler";
    php_embed_module.pretty_name = "mod_apex (embedded PHP via Apache, OPcache-compatible SAPI name)";

    /* Link our SAPI callbacks into the shared embed module struct */
    php_embed_module.ub_write       = apex_ub_write;
    php_embed_module.flush          = apex_flush;
    php_embed_module.read_cookies   = apex_read_cookies;
    php_embed_module.read_post      = apex_read_post;
    php_embed_module.header_handler = apex_header_handler;
    php_embed_module.send_headers   = apex_send_headers;
    php_embed_module.register_server_variables = apex_register_server_variables;

    /* Register the apache2handler-compatibility functions (apache_* +
     * getallheaders). php_module_startup(), reached from php_embed_init() in
     * child_init, adds these to the "standard" module's function table so
     * they exist in every request -- consistent with the reported SAPI name. */
    php_embed_module.additional_functions = apex_additional_functions;

    ap_log_error(APLOG_MARK, APLOG_WARNING, 0, s,
                 "mod_apex: expected PHP handler mapping is 'php-script' or 'application/x-httpd-php'; "
                 "mis-mapped .php requests will return 500");

    ap_log_error(APLOG_MARK, APLOG_INFO, 0, s,
                 "mod_apex: callbacks wired; PHP engine will start in child_init");
    return OK;
}

/* Called in each child process – no special init needed */
static void apex_child_init(apr_pool_t *pchild, server_rec *s)
{
    (void) pchild;
    char *php_argv[] = {"mod_apex", NULL};
    int is_threaded = AP_MPMQ_NOT_SUPPORTED;

    if (ap_mpm_query(AP_MPMQ_IS_THREADED, &is_threaded) != APR_SUCCESS || !is_threaded) {
        ap_log_error(APLOG_MARK, APLOG_CRIT, 0, s,
                     "mod_apex: requires a threaded MPM; skipping PHP engine init in this process");
        return;
    }

    if (apex_engine_started) {
        return;
    }

    if (php_embed_init(1, php_argv) == FAILURE) {
        ap_log_error(APLOG_MARK, APLOG_CRIT, 0, s,
                     "mod_apex: php_embed_init() failed in child_init");
        return;
    }

#ifdef ZEND_ENABLE_STATIC_TSRMLS_CACHE
    ZEND_TSRMLS_CACHE_UPDATE();
#endif

    /* php_embed_init() runs php_module_startup() AND leaves an initial request
     * active (its matching php_request_shutdown() normally runs inside
     * php_embed_shutdown()). Our handler drives its own per-request
     * php_request_startup()/php_request_shutdown() cycle, so close that initial
     * request now to keep the cycle balanced. The previous code instead called
     * php_request_startup() a SECOND time here, nesting request state on top of
     * the one embed_init already opened. */
    APEX_REQUEST_SHUTDOWN();
    SG(server_context) = NULL;

    apex_engine_started = 1;
    ap_log_error(APLOG_MARK, APLOG_INFO, 0, s,
                 "mod_apex: PHP %s engine started in child (embed init complete)", PHP_VERSION);
}

/* --------------------------------------------------------------------- */
/* Configuration directives                                                */
/* --------------------------------------------------------------------- */
static void *apex_create_config(apr_pool_t *p, server_rec *s)
{
    apex_config *cfg = apr_pcalloc(p, sizeof(apex_config));

    (void) s;
    return cfg;
}

static void *apex_merge_config(apr_pool_t *p, void *basev, void *addv)
{
    apex_config *base = (apex_config *) basev;
    apex_config *add = (apex_config *) addv;
    apex_config *merged = apr_pcalloc(p, sizeof(apex_config));

    merged->debug_errors_set = add->debug_errors_set || base->debug_errors_set;
    merged->debug_errors = add->debug_errors_set ? add->debug_errors : base->debug_errors;

    return merged;
}

static const char *apex_set_verbose_errors(cmd_parms *cmd, void *dummy, int flag)
{
    apex_config *cfg = (apex_config *) ap_get_module_config(cmd->server->module_config, &apex_module);

    (void) dummy;
    cfg->debug_errors = flag;
    cfg->debug_errors_set = 1;
    return NULL;
}

static const command_rec apex_cmds[] = {
    AP_INIT_FLAG("ApexVerboseErrors", apex_set_verbose_errors, NULL, RSRC_CONF,
                 "On to include diagnostic detail in mod_apex error responses (default Off)"),
    { NULL }
};

/* Register hooks */
static void apex_register_hooks(apr_pool_t *p)
{
    ap_hook_post_config(apex_post_config, NULL, NULL, APR_HOOK_MIDDLE);
    ap_hook_child_init(apex_child_init, NULL, NULL, APR_HOOK_MIDDLE);
    ap_hook_handler(apex_handler, NULL, NULL, APR_HOOK_MIDDLE);
}

/* Module declaration */
module AP_MODULE_DECLARE_DATA apex_module = {
    STANDARD20_MODULE_STUFF,
    NULL,                       /* per‑dir config creator */
    NULL,                       /* per‑dir config merger  */
    apex_create_config,         /* server config creator  */
    apex_merge_config,          /* server config merger   */
    apex_cmds,                  /* command table           */
    apex_register_hooks         /* register hooks          */
};