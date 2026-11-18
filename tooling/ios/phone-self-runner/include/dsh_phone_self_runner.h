#ifndef DSH_PHONE_SELF_RUNNER_H
#define DSH_PHONE_SELF_RUNNER_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* The four start exports and core_request contain Rust panics that unwind.
 * Before admission: zero XCTest handle / nonzero Core status, no callback or
 * action. After admission: the accepted return is preserved and the worker
 * retains terminal ownership. Owner and request locks are never unwound through
 * during the admission decision. Builds require panic=unwind.
 * This is not protection from invalid pointers, process/OOM abort, panic hooks
 * that abort, or foreign exceptions. Foreign callbacks must never unwind.
 */

/* All callback strings are borrowed and valid only until the callback returns.
 * Callbacks run on the native worker thread. Copy before dispatching elsewhere.
 * No callback contains a plaintext RPC credential or pairing record.
 * kind: 0 starting, 1 ready (base64 RSA ciphertext), 2 stopped, 3 failed,
 * 4 faulted (ERR_PHONE_STOP_UNCONFIRMED; poisoned until app restart).
 * 2/3 follow resource release and confirmed device exit (or no device launch).
 * 4 follows native resource release but does NOT confirm device process exit.
 * Callbacks may precede start's return.
 */
typedef void (*dsh_phone_xctest_callback)(const char *run_id, int32_t kind,
                                          const char *payload);

/* The JSON string is copied during this call. Returns zero for invalid input,
 * another live/stopping owner, or failure to create the native worker thread.
 * Accepted keys: runId, pairingBase64 (or legacy pairingFile), host, port,
 * runnerBundleId, targetBundleId, publicKeyBase64, ddiCache, allowDDIMount.
 * Public key is 2048-bit RSA PKCS#1 DER. New callers keep pairing in memory.
 */
uint64_t dsh_phone_xctest_start(const char *config_json,
                               dsh_phone_xctest_callback callback);

/* Preferred in-memory input. Both buffers are borrowed read-only until return,
 * must describe valid readable memory, and are never retained or mutated.
 * config_json is UTF-8 JSON of 1..96 KiB without pairingBase64 or pairingFile;
 * either key, even null, is rejected. pairing_plist is 1..65536 raw plist bytes.
 * Validation completes synchronously into an owned native record. It is not a
 * promise to erase caller/Swift/Keychain/parser copies. Return/callback semantics
 * match dsh_phone_xctest_start; zero means not accepted and no callback.
 * The original JSON ABI remains available for existing callers.
 */
uint64_t dsh_phone_xctest_start_bytes(const uint8_t *config_json, size_t config_len,
    const uint8_t *pairing_plist, size_t pairing_len, dsh_phone_xctest_callback callback);

/* Idempotent and nonblocking. A stale handle cannot stop a newer session.
 * A stopping session still owns the singleton slot until terminal delivery.
 * A faulted/unconfirmed session keeps the slot poisoned until app restart.
 */
void dsh_phone_xctest_stop(uint64_t handle);

/* CoreDevice shares the SAME singleton owner with XCTest. Configuration and
 * requests are length-delimited UTF-8 JSON, copied/parsed before return.
 * Configuration <= 96 KiB; request <= 16 KiB; callback JSON <= 8192 bytes.
 * Callback strings/bytes are borrowed only until callback return and must be
 * copied before dispatching to another thread. Callbacks use the worker thread,
 * outside the owner mutex, and may precede start's return.
 *
 * Event kinds: 0 starting; 1 ready; 2 stopped and released; 3 failed and
 * released; 4 cleanup unconfirmed, owner poisoned until process restart;
 * 5 DDI progress. Only terminal kinds 2/3 confirm complete owner release.
 * Request status: 0 success/read or DISPATCHED; 1 failed before any side effect;
 * 2 cancelled before any side effect; 3 uncertain after a possible side effect.
 * Media start and virtual-keyboard registration already count as side effects.
 * HID is one-way: DISPATCHED never proves that an app consumed input/paste.
 * result.cleanupConfirmed applies to that request; terminal 2/3 confirms owner
 * cleanup. Uncertain actions must never be automatically retried/fallen back.
 * Screenshot PNG <= 16 MiB; apps JSON bytes <= 1 MiB; error bytes are null/zero.
 */
typedef void (*dsh_phone_core_event_callback)(uint64_t handle,
    const char *run_id, int32_t kind, const char *event_json);
typedef void (*dsh_phone_core_result_callback)(uint64_t handle,
    uint64_t request_id, int32_t status, const char *result_json,
    const uint8_t *bytes, size_t bytes_len);

/* Permanent read-only NUL string. Does not acquire an owner or perform I/O.
 * Caller must not modify/free it. Exact v1 value:
 * dsh-phone-core:1;idevice=3854a5df4a5a6dee71ffce4d8befc2ea356a8065
 */
const char *dsh_phone_core_build_identity(void);

/* Synchronous code: 0 accepted; 1 invalid; 2 busy; 3 stale; 4 not ready;
 * 5 stopping; 6 faulted; 7 size limit; 8 internal failure.
 * A nonzero request return guarantees no callback or action for that request.
 * A nonzero start return guarantees no callbacks and no live owner handle.
 * Accepted request IDs are nonzero and strictly increase within one owner.
 * Only one request is in flight. Every accepted request gets exactly one result
 * before the owner terminal event (except process termination).
 * handle_out is set to zero on failure; invalid memory remains caller UB.
 */
int32_t dsh_phone_core_start(const uint8_t *config_json, size_t config_len,
    dsh_phone_core_event_callback callback, uint64_t *handle_out);
/* Same independent-buffer contract as dsh_phone_xctest_start_bytes and the
 * same status/handle/callback contract as dsh_phone_core_start. A length above
 * either limit returns 7; invalid/null/empty inputs return 1. Rejected starts
 * leave handle_out zero and have no callback. The old JSON ABI is unchanged.
 */
int32_t dsh_phone_core_start_bytes(const uint8_t *config_json, size_t config_len,
    const uint8_t *pairing_plist, size_t pairing_len,
    dsh_phone_core_event_callback callback, uint64_t *handle_out);
int32_t dsh_phone_core_request(uint64_t handle, uint64_t request_id,
    const uint8_t *request_json, size_t request_len,
    dsh_phone_core_result_callback callback);

/* Idempotent, nonblocking, and confined to the matching owner/request.
 * A stale handle or request ID cannot cancel a newer operation.
 * stop atomically rejects further requests before signalling the worker.
 */
void dsh_phone_core_cancel(uint64_t handle, uint64_t request_id);
void dsh_phone_core_stop(uint64_t handle);

#ifdef __cplusplus
}
#endif
#endif
