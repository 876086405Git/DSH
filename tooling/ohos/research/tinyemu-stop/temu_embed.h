/* Host-only embedding research API. TinyEMU's upstream MIT notice remains in
 * COPYING and the source files. This adds no guest/tool READY guarantee. */
#ifndef TEMU_EMBED_H
#define TEMU_EMBED_H

typedef void (*TemuInitialized)(void *opaque);
typedef int (*TemuShouldStop)(void *opaque);
enum {
    /* Local config/drive failure: the fixed startup path released its devices. */
    TEMU_EMBED_RETRYABLE_START_FAILURE = -1,
    /* Control threads may end, but complete device cleanup is unproved. */
    TEMU_EMBED_UNRECOVERED_START_FAILURE = -2,
    /* Guest requested shutdown; devices remain owned and must not be reused. */
    TEMU_EMBED_STOPPED_UNRELEASED = -3,
    TEMU_EMBED_CANCELLED_UNRELEASED = -4,
    TEMU_EMBED_OUTPUT_UNRELEASED = -5,
    TEMU_EMBED_OWNER_UNRELEASED = -6,
    TEMU_EMBED_INPUT_UNRELEASED = -7
};

/* Callback runs synchronously on the machine thread after initialization and
 * before the CPU loop. Guest poweroff returns STOPPED_UNRELEASED after CPU dispatch ends.
 * This is not a device-release or safe-reinitialization guarantee. */
int temu_embed_run_initialized(const char *path, int in_fd, int out_fd,
                               TemuInitialized initialized, void *opaque);
/* Existing ABI: every setup failure remains -1. */
int temu_embed_run(const char *path, int in_fd, int out_fd);

/* Both callbacks execute synchronously on the VM thread and must not block.
 * stdin and stdout are caller-owned stream sockets; neither OFD is mutated. The caller joins its machine thread
 * after return, but MUST retain the unreleased VM owner/library thereafter. */
int temu_embed_run_controlled(const char *path, int in_fd, int out_fd,
                             TemuInitialized initialized, TemuShouldStop stop,
                             void *opaque);
#endif
