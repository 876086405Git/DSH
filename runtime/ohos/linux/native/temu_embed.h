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
    TEMU_EMBED_INPUT_UNRELEASED = -7,
    TEMU_EMBED_RETIRE_FAILED_UNRELEASED = -8,
    TEMU_EMBED_FATAL_UNRELEASED = -9,
    /* Dedicated wake/wait failure; distinct from drive retirement failure. */
    TEMU_EMBED_WAIT_UNRELEASED = -10
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

/* Opt-in event wait ABI. wake_read_fd is a distinct, connected AF_UNIX stream
 * socket, below FD_SETSIZE. The caller keeps it open throughout this call.
 * After publishing stop, its unique peer writer is shutdown(SHUT_WR) once;
 * persistent EOF wakes both the machine select and blocked console output.
 * This function borrows every fd: it never closes or changes its OFD flags.
 * It does not fall back to the legacy 10 ms entry when wake validation fails.
 * Return/join does not authorize VM reuse. Blocking disk IO and OS scheduling
 * have no wall-clock completion guarantee. */
int temu_embed_run_controlled_wake(const char *path, int in_fd, int out_fd,
                                  int wake_read_fd, TemuInitialized initialized,
                                  TemuShouldStop stop, void *opaque);
/* Machine-thread detail, reset on entry. Read on that same thread after return
 * and publish only after real join. EPROTO denotes unexpected wake data/EOF
 * without stop; actual syscall failures retain errno. This is not close debt. */
extern _Thread_local int dsh_temu_wait_error;
#endif
