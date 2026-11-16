/* HOST TEST ONLY. The fatal/SIGPIPE baseline omits the event-wait patch.
 * Keep the current NAPI binding linked to the actual legacy controlled entry,
 * so a missing symbol cannot masquerade as an expected process-fatal result.
 * No event-wait behavior or production resource contract is inferred here. */
#include "temu_embed.h"

_Thread_local int dsh_temu_wait_error;

int temu_embed_run_controlled_wake(const char *path, int in_fd, int out_fd,
                                  int wake_read_fd, TemuInitialized initialized,
                                  TemuShouldStop stop, void *opaque)
{
    (void)wake_read_fd;
    dsh_temu_wait_error = 0;
    return temu_embed_run_controlled(path, in_fd, out_fd, initialized, stop, opaque);
}
