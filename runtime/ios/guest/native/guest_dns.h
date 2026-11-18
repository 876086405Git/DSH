#ifndef DSH_GUEST_DNS_H
#define DSH_GUEST_DNS_H
#include <stddef.h>
/* Internal APIs, not exposed to JavaScript. Positive host errno on failure. */
int dsh_dns_format(const char *const *servers, size_t count, char *out, size_t capacity);
/* Caller holds backend gate, current=supervisor, no active job or bound mounts. */
int dsh_dns_sync(void);
#endif
