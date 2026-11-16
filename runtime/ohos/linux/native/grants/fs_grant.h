#ifndef DSH_FS_GRANT_H
#define DSH_FS_GRANT_H
struct FSDevice;
/* Trusted owner consumes ticket, then maps ONLY a fixed mount tag to this
 * object. Neither guest aname nor a config filename is an authority source. */
struct FSDevice *fs_grant_init(const char *ticket);
int fs_grant_request_begin(struct FSDevice *,unsigned);
void fs_grant_request_end(struct FSDevice *);
int fs_grant_retire(struct FSDevice *);
int fs_grant_destroy(struct FSDevice *);
#endif
