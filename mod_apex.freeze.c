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

/* --------------------------------------------------------------------- */
/* Per‑request context – stored in SG(server_context) (thread‑local)      */
/* --------------------------------------------------------------------- */
typedef struct {
    request_rec *r;               /* Apache request pointer                */
    long         request_body_len;/* Content-Length when known, else -1    */
    int          body_ready;      /* ap_setup_client_block completed        */
    int          body_eof;        /* client body fully consumed             */
    apr_off_t    read_post_bytes; /* bytes read from client body via SAPI   */
    apr_off_t    ub_write_bytes;  /* bytes written to Apache output filters */
} apex_ctx_t;

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

/* --------------------------------------------------------------------- */
/* PHP SAPI callbacks                                                     */
/* --------------------------------------------------------------------- */

/* Write output to the client */
static size_t apex_ub_write(const char *str, size_t str_length)
{
    apex_ctx_t *ctx = (apex_ctx_t *) SG(server_context);
    int written;

    if (!ctx || !ctx->r || !str || str_length == 0) {
        return 0;
    }

    written = ap_rwrite(str, (int) str_length, ctx->r);
    if (written <= 0) {
        return 0;
    }

    ctx->ub_write_bytes += (apr_off_t) written;

    return (size_t) written;
}

/* Flush output to the client */
static void apex_flush(void *server_context)
{
    apex_ctx_t *ctx = (apex_ctx_t *) server_context;
    if (ctx && ctx->r) {
        ap_rflush(ctx->r);
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

static void apex_register_proxy_header_variables(request_rec *r, zval *track_vars_array)
{
    const char *v;

    if (!r || !track_vars_array) {
        return;
    }

    v = apr_table_get(r->headers_in, "X-Forwarded-Proto");
    if (v && *v) {
        apex_register_server_variable(track_vars_array, "HTTP_X_FORWARDED_PROTO", v);
    }

    v = apr_table_get(r->headers_in, "X-Forwarded-Host");
    if (v && *v) {
        apex_register_server_variable(track_vars_array, "HTTP_X_FORWARDED_HOST", v);
    }

    v = apr_table_get(r->headers_in, "X-Forwarded-Port");
    if (v && *v) {
        apex_register_server_variable(track_vars_array, "HTTP_X_FORWARDED_PORT", v);
    }

    v = apr_table_get(r->headers_in, "X-Forwarded-For");
    if (v && *v) {
        apex_register_server_variable(track_vars_array, "HTTP_X_FORWARDED_FOR", v);
    }

    v = apr_table_get(r->headers_in, "X-Real-IP");
    if (v && *v) {
        apex_register_server_variable(track_vars_array, "HTTP_X_REAL_IP", v);
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
                                      apr_psprintf(r->pool, "%ld", ctx->request_body_len));
    }

    if (r->path_info && *r->path_info) {
        apex_register_server_variable(track_vars_array, "PATH_INFO", r->path_info);
    }

    if (r->user && *r->user) {
        apex_register_server_variable(track_vars_array, "REMOTE_USER", r->user);
    }

    apex_register_authorization_variables(r, track_vars_array);
    apex_register_proxy_header_variables(r, track_vars_array);
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

static void apex_ensure_worker_tsrm_context(void)
{
#ifdef ZTS
    (void) ts_resource_ex(core_globals_id, NULL);
    (void) ts_resource_ex(sapi_globals_id, NULL);
    (void) ts_resource_ex(executor_globals_id, NULL);
    (void) ts_resource_ex(compiler_globals_id, NULL);
# ifdef ZEND_ENABLE_STATIC_TSRMLS_CACHE
    ZEND_TSRMLS_CACHE_UPDATE();
# endif
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

    SG(request_info).request_uri     = r->uri;
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
    apr_time_t startup_begin;
    apr_time_t startup_end;
    apr_time_t execute_end;
    apr_time_t shutdown_end;

    /* We only handle files that actually exist and are set to PHP */
    if (!apex_is_supported_handler(r))
        return DECLINED;

    if (!r->filename || !ap_is_initial_req(r))
        return DECLINED;

    if (!apex_engine_started) {
        ap_log_rerror(APLOG_MARK, APLOG_CRIT, 0, r,
                      "mod_apex: PHP engine not initialized in child process");
        return HTTP_INTERNAL_SERVER_ERROR;
    }

#ifdef ZEND_ENABLE_STATIC_TSRMLS_CACHE
    ZEND_TSRMLS_CACHE_UPDATE();
#endif

    apex_ensure_worker_tsrm_context();

    /* ===== 1. Prepare request context ===== */
    apex_ctx_t ctx;
    int prep_status = apex_prepare_request_context(r, &ctx);
    if (prep_status != OK) {
        ap_log_rerror(APLOG_MARK, APLOG_ERR, 0, r,
                      "mod_apex: request body preparation failed (%d)", prep_status);
        return prep_status;
    }
    apex_populate_php_request_info(r, &ctx);

    /* ===== 2. Start a fresh request inside the persistent interpreter ===== */
    startup_begin = apr_time_now();
    if (php_request_startup() == FAILURE) {
        ap_log_rerror(APLOG_MARK, APLOG_CRIT, 0, r,
                      "mod_apex: php_request_startup() failed");
        return HTTP_INTERNAL_SERVER_ERROR;
    }
    startup_end = apr_time_now();

    /* ===== 3. Execute the PHP script ===== */
    int status = apex_execute_php_file(r->filename);
    execute_end = apr_time_now();

    /* ===== 4. Finish the request ===== */
    if (!r->content_type) {
        ap_set_content_type(r, "text/html; charset=UTF-8");
    }

    /* ===== 5. Completely reset the interpreter state for the next request ===== */
    apex_clear_php_request_info();
    APEX_REQUEST_SHUTDOWN();
    shutdown_end = apr_time_now();
    SG(server_context) = NULL;

    ap_log_rerror(APLOG_MARK, APLOG_TRACE1, 0, r,
                  "mod_apex: timing_us startup=%" APR_TIME_T_FMT " execute=%" APR_TIME_T_FMT " shutdown=%" APR_TIME_T_FMT
                  " read_post_bytes=%" APR_OFF_T_FMT " ub_write_bytes=%" APR_OFF_T_FMT,
                  startup_end - startup_begin,
                  execute_end - startup_end,
                  shutdown_end - execute_end,
                  ctx.read_post_bytes,
                  ctx.ub_write_bytes);

    if (status == FAILURE) {
        ap_log_rerror(APLOG_MARK, APLOG_ERR, 0, r,
                      "mod_apex: script execution failed for %s", r->filename);
        return HTTP_INTERNAL_SERVER_ERROR;
    }

    return OK;
}

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

    /* Link our SAPI callbacks into the shared embed module struct */
    php_embed_module.ub_write       = apex_ub_write;
    php_embed_module.flush          = apex_flush;
    php_embed_module.read_cookies   = apex_read_cookies;
    php_embed_module.read_post      = apex_read_post;
    php_embed_module.header_handler = apex_header_handler;
    php_embed_module.send_headers   = apex_send_headers;
    php_embed_module.register_server_variables = apex_register_server_variables;

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

    if (php_request_startup() == FAILURE) {
        ap_log_error(APLOG_MARK, APLOG_CRIT, 0, s,
                     "mod_apex: child warmup php_request_startup() failed");
        return;
    }

    APEX_REQUEST_SHUTDOWN();
    SG(server_context) = NULL;

    apex_engine_started = 1;
    ap_log_error(APLOG_MARK, APLOG_INFO, 0, s,
                 "mod_apex: PHP %s engine started in child (warmup complete)", PHP_VERSION);
}

/* --------------------------------------------------------------------- */
/* Configuration directives (for future expansion)                        */
/* --------------------------------------------------------------------- */
typedef struct {
    int dummy;   /* reserved */
} apex_config;

static void *apex_create_config(apr_pool_t *p, server_rec *s)
{
    return apr_pcalloc(p, sizeof(apex_config));
}

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
    NULL,                       /* server config merger   */
    NULL,                       /* command table           */
    apex_register_hooks         /* register hooks          */
};