#ifndef DSH_TEMU_EMBED_RAM_H
#define DSH_TEMU_EMBED_RAM_H
#include <stddef.h>
#include <stdint.h>

typedef struct {
    uint64_t tracked_bytes, eligible_bytes, advised_bytes;
    int eligible, attempted, error_code;
} DshTemuRamRetirement;

/* Internal to the single quarantined VM. Capture/allow run on its pthread.
 * No fields are read across threads until a successful pthread_join. */
void dsh_temu_ram_capture(void *ram, size_t bytes);
void dsh_temu_ram_allow_retirement(void);
/* Only the native join worker may call this, AFTER pthread_join succeeds.
 * Advises complete interior guest-RAM pages once; never frees an allocation,
 * changes a mapping/address, destroys a device, or permits another VM. */
DshTemuRamRetirement dsh_temu_ram_retire_joined(void);
#endif
