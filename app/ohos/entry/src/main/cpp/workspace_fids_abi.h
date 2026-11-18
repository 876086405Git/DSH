#ifndef DSH_WORKSPACE_FIDS_ABI_H
#define DSH_WORKSPACE_FIDS_ABI_H
#include "workspace_grants_abi.h"
#ifdef __cplusplus
extern "C" {
#endif
// Trusted adapter only: attach consumes parent-issued one-use task ticket.
// These handles are never numbers/pointers sent to the guest. A VM-side bounded
// FID table owns them. All calls on a handle must serialize against its clunk.
// Each handle pins the admission lease. retire(ticket) must precede dispatch
// stop, request join/drain and final clunk; false is retained resource debt.
DSH_WORKSPACE_API void* dsh_workspace_fid_attach(const char* ticket);
DSH_WORKSPACE_API void* dsh_workspace_fid_clone(void* fid);
DSH_WORKSPACE_API void* dsh_workspace_fid_walk(void* fid,const char* name);
DSH_WORKSPACE_API void dsh_workspace_fid_clunk(void* fid);
DSH_WORKSPACE_API int dsh_workspace_fid_open(void* fid,int write,int truncate);
DSH_WORKSPACE_API int dsh_workspace_fid_stat(void* fid,struct DshWorkspaceStat*);
DSH_WORKSPACE_API int64_t dsh_workspace_fid_read(void*,uint64_t,void*,size_t);
DSH_WORKSPACE_API int64_t dsh_workspace_fid_write(void*,uint64_t,const void*,size_t);
DSH_WORKSPACE_API void* dsh_workspace_fid_create(void*,const char*);
DSH_WORKSPACE_API int dsh_workspace_fid_mkdir(void*,const char*);
DSH_WORKSPACE_API int dsh_workspace_fid_remove(void*,const char*,int directory);
DSH_WORKSPACE_API int dsh_workspace_fid_rename(void*,const char*,void*,const char*);
DSH_WORKSPACE_API int dsh_workspace_fid_list(void*,DshWorkspaceEntry,void*);
#ifdef __cplusplus
}
#endif
#endif
