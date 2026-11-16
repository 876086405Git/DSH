#ifndef DSH_WORKSPACE_GRANTS_ABI_H
#define DSH_WORKSPACE_GRANTS_ABI_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
// Trusted in-process consumers only; never expose acquire to guest/Dart as an
// unchecked method. Caller already consumed its engine task policy. write=0
// gives a read-only lease even when the OS grant permits writes.
#define DSH_WORKSPACE_API __attribute__((visibility("default")))
DSH_WORKSPACE_API void* dsh_workspace_acquire(const char* id,uint64_t generation,int write);
DSH_WORKSPACE_API void dsh_workspace_release(void* lease);
DSH_WORKSPACE_API const char* dsh_workspace_error(void);
DSH_WORKSPACE_API int64_t dsh_workspace_read(void* lease,const char* relative,uint64_t offset,void* buffer,size_t length);
DSH_WORKSPACE_API int64_t dsh_workspace_write(void* lease,const char* relative,uint64_t offset,const void* buffer,size_t length,int create,int truncate);
DSH_WORKSPACE_API int dsh_workspace_rename(void* lease,const char* source,const char* destination);
DSH_WORKSPACE_API int dsh_workspace_remove(void* lease,const char* relative,int directory);
DSH_WORKSPACE_API int dsh_workspace_mkdir(void* lease,const char* relative);
#ifdef __cplusplus
}
#endif
#endif

#ifndef DSH_WORKSPACE_GRANTS_ABI_913
#define DSH_WORKSPACE_GRANTS_ABI_913
#ifdef __cplusplus
extern "C" {
#endif
struct DshWorkspaceStat {uint64_t size;uint64_t ino;uint64_t dev;uint32_t mode;uint32_t type;double mtime_ms;};
typedef int (*DshWorkspaceEntry)(const char*,size_t,void*);
// Discovery only. No path/URI/FD is returned. Issue revalidates active generation.
 typedef int (*DshWorkspaceSnapshotEntry)(const char*,size_t,uint64_t,int,void*);
 DSH_WORKSPACE_API int dsh_workspace_snapshot(DshWorkspaceSnapshotEntry,void*);
DSH_WORKSPACE_API int dsh_workspace_errno(void);
DSH_WORKSPACE_API int dsh_workspace_stat(void*,const char*,struct DshWorkspaceStat*);
DSH_WORKSPACE_API int dsh_workspace_readdir(void*,const char*,DshWorkspaceEntry,void*);
DSH_WORKSPACE_API int64_t dsh_workspace_write_flags(void*,const char*,uint64_t,const void*,size_t,int);
// Ticket token: parent generates 32 random bytes encoded as exactly 64 hex chars.
// Issue/revoke are trusted owner-only. Worker sees only consume + ordinary IO.
DSH_WORKSPACE_API int dsh_workspace_ticket_issue(const char* token,const char* id,uint64_t generation,int write);
DSH_WORKSPACE_API void* dsh_workspace_ticket_consume(const char* token);
DSH_WORKSPACE_API int dsh_workspace_ticket_retire(const char* token);
#ifdef __cplusplus
}
#endif
#endif

#ifndef DSH_WORKSPACE_GRANTS_EDIT_ABI_V1
#define DSH_WORKSPACE_GRANTS_EDIT_ABI_V1
#ifdef __cplusplus
extern "C" {
#endif
// Additive ABI. DshWorkspaceStat and all legacy symbols above are unchanged.
// Integral fields are from one stat; consumers must not round through double.
struct DshWorkspaceStatExactV1 {
 uint32_t version;uint32_t reserved;
 uint64_t dev;uint64_t ino;uint64_t size;
 int64_t mtime_sec;int64_t ctime_sec;
 uint32_t mtime_nsec;uint32_t ctime_nsec;uint32_t mode;uint32_t type;
};
DSH_WORKSPACE_API int dsh_workspace_stat_exact_v1(void* lease,const char* relative,struct DshWorkspaceStatExactV1* out,size_t out_size);
// One private read-only input slot per lease. Open returns the fstat size of
// that same descriptor. Read advances by its actual result, at most 1 MiB per
// call; there is no total cap or imposed EOF/initial-size stopping policy.
DSH_WORKSPACE_API int dsh_workspace_edit_input_open_v1(void* lease,const char* relative,uint64_t* size);
DSH_WORKSPACE_API int64_t dsh_workspace_edit_input_read_v1(void* lease,void* buffer,size_t length);
DSH_WORKSPACE_API int dsh_workspace_edit_input_close_v1(void* lease);
// Existing-file edit only. prior_mode is the trusted provider's FIRST probe
// mode & 0777. The caller retains its original guard/read/edit ordering.
DSH_WORKSPACE_API int dsh_workspace_edit_begin_v1(void* lease,const char* relative,uint32_t prior_mode);
DSH_WORKSPACE_API int64_t dsh_workspace_edit_write_v1(void* lease,const void* buffer,size_t length);
// fsync -> prior mode -> checked file close. Does not publish.
DSH_WORKSPACE_API int dsh_workspace_edit_close_v1(void* lease);
// A nonnegative result ALWAYS confirms rename committed: 1 means our staging
// directory was removed, 0 means only its best-effort removal failed. This call
// never closes auxiliary descriptors after commit. The caller must record the
// committed fact before subsequent resource cleanup and lease retirement.
DSH_WORKSPACE_API int dsh_workspace_edit_publish_v1(void* lease);
// Explicit output cleanup. After publish it closes only auxiliary descriptors;
// it never removes the target and does not turn a directory-removal diagnostic
// into an error. Descriptor close failure is an error and makes existing retire
// remain unconfirmed. No output slot is an idempotent success. Input is separate.
DSH_WORKSPACE_API int dsh_workspace_edit_abort_v1(void* lease);
#ifdef __cplusplus
}
#endif
#endif

#ifndef DSH_WORKSPACE_GRANTS_MOVE_ABI_V1
#define DSH_WORKSPACE_GRANTS_MOVE_ABI_V1
#ifdef __cplusplus
extern "C" {
#endif
// Additive Move output only; legacy stat/edit layouts and symbols unchanged.
// Reuses edit write/close/abort on the same lease-owned output slot.
DSH_WORKSPACE_API int dsh_workspace_move_output_begin_v1(void*,const char*,uint32_t source_mode,int create_if_absent);
struct DshWorkspaceMovePublishV1 {uint32_t version;uint32_t reserved;uint32_t effect;uint32_t staging_removed;};
// out remains meaningful on -1: effect0=no final created by this call,
// effect1=wx final created but possibly incomplete, effect2=complete publication.
// Complete output does NOT imply descriptor closure or lease retirement.
// staging_removed concerns only best-effort removal of owned staging entries.
DSH_WORKSPACE_API int dsh_workspace_move_output_publish_v1(void*,struct DshWorkspaceMovePublishV1*,size_t);
#ifdef __cplusplus
}
#endif
#endif


#ifndef DSH_WORKSPACE_GRANTS_WHOLE_WRITE_ABI_V1
#define DSH_WORKSPACE_GRANTS_WHOLE_WRITE_ABI_V1
#ifdef __cplusplus
extern "C" {
#endif
// An independent optional group. All old stat/edit/move layouts and symbols
// are unchanged. policy0 preserves prior_mode (including zero); policy1 uses
// actual directory defaults from an O_CREAT request of 0666, prior_mode=0.
DSH_WORKSPACE_API int dsh_workspace_whole_output_begin_v1(void*,const char*,uint32_t policy,uint32_t prior_mode,int create_if_absent);
DSH_WORKSPACE_API int64_t dsh_workspace_whole_output_write_v1(void*,const void*,size_t);
// Sync/attributes/checked write-FD close only. A private duplicate of the same
// open object remains under this lease for possible copying and checked cleanup.
DSH_WORKSPACE_API int dsh_workspace_whole_output_close_v1(void*);
struct DshWorkspaceWholePublishV1 {
 uint32_t version,reserved,effect_known,effect,continuation,staging_removed;
};
// A step does not necessarily publish. continuation: 0=done, 1=exclusive open
// after a supported link failure, 2=bounded copy, 3=body complete; finish sync/
// mode/checked-close without another JS cancellation check. Caller checks its
// signal before 1/2. Copy has at most one <=64KiB read and one write per call.
// effect0=no final produced, 1=exclusive final may be incomplete, 2=committed.
// Valid out facts survive -1; effect_known=0 must not be interpreted as effect0.
// staging_removed is only a best-effort diagnostic, never FD/lease retirement.
DSH_WORKSPACE_API int dsh_workspace_whole_output_publish_step_v1(void*,struct DshWorkspaceWholePublishV1*,size_t);
// Cleanup is available after cancellation/retirement. Never unlink final.
DSH_WORKSPACE_API int dsh_workspace_whole_output_abort_v1(void*);
#ifdef __cplusplus
}
#endif
#endif
