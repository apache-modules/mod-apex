#include <stdio.h>
#include "php_embed.h"

static int run_request_cycle(const char *label)
{
#ifdef ZEND_ENABLE_STATIC_TSRMLS_CACHE
    ZEND_TSRMLS_CACHE_UPDATE();
#endif

    if (php_request_startup() == FAILURE) {
        fprintf(stderr, "php_request_startup failed in %s\n", label);
        return 1;
    }

    php_request_shutdown(NULL);
    return 0;
}

int main(void)
{
    char *argv[] = {"php_embed_smoke", NULL};

    if (php_embed_init(1, argv) == FAILURE) {
        fprintf(stderr, "php_embed_init failed\n");
        return 2;
    }

    if (run_request_cycle("cycle1") != 0) {
        php_embed_shutdown();
        return 3;
    }

    if (run_request_cycle("cycle2") != 0) {
        php_embed_shutdown();
        return 4;
    }

    php_embed_shutdown();
    puts("php_embed_smoke: success");
    return 0;
}
