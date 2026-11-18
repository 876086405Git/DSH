/* Test-only private-state setup. The product translation unit stays exact;
 * clock and select are declared boundaries. This adds no production API. */
#include "temu.c"
static int probe_not_stopping(void *p) { (void)p; return 0; }
void probe_begin_wake(int fd)
{
    embed_controlled = 1; embed_wake_fd = fd; embed_should_stop = probe_not_stopping;
    embed_control_opaque = NULL; dsh_temu_wait_error = 0;
}
void probe_end_wake(void)
{
    embed_wake_fd = -1; embed_controlled = 0; embed_should_stop = NULL;
}
EthernetDevice *probe_slirp_open(void) { return slirp_open(); }
