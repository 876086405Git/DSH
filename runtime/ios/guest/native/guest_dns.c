/* Apple resolver configuration; no claim of system split-DNS equivalence.
 * API source: Apple OSS libresolv/resolv.h. Apple SDK execution unverified. */
#include "guest_dns.h"
#include "kernel/fs.h"
#include "kernel/errno.h"
#include "kernel/task.h"
#include "fs/fd.h"
#include "fs/path.h"
#include <arpa/inet.h>
#include <errno.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <sys/stat.h>
#ifdef __APPLE__
#include <resolv.h>
#endif

int dsh_dns_format(const char *const *servers, size_t count, char *out, size_t capacity) {
  if (!out || !capacity || !servers || !count || count > 16) return EINVAL;
  out[0] = 0;
  size_t used = 0;
  for (size_t i = 0; i < count; ++i) {
    unsigned char address[16];
    if (!servers[i] || (inet_pton(AF_INET, servers[i], address) != 1 &&
                       inet_pton(AF_INET6, servers[i], address) != 1)) return EINVAL;
    int n = snprintf(out + used, capacity - used, "nameserver %s\n", servers[i]);
    if (n < 0 || (size_t)n >= capacity - used) return ENOSPC;
    used += (size_t)n;
  }
  return 0;
}

#if defined(__APPLE__) || defined(DSH_GUEST_DNS_TEST)
#ifdef DSH_GUEST_DNS_TEST
/* Defined only by the separate test fixture; absent from production builds. */
extern int dsh_dns_test_config(char *out, size_t capacity);
#define host_config dsh_dns_test_config
#else
static int host_config(char *out, size_t capacity) {
  struct __res_state state = {0};
  if (res_ninit(&state) != 0) return EHOSTUNREACH;
  union res_sockaddr_union addresses[16];
  int count = res_getservers(&state, addresses, 16);
  char text[16][INET6_ADDRSTRLEN];
  const char *servers[16];
  size_t used = 0;
  for (int i = 0; i < count && i < 16; ++i) {
    const void *bytes = NULL;
    int family = addresses[i].sin.sin_family;
    if (family == AF_INET && ntohs(addresses[i].sin.sin_port) == 53)
      bytes = &addresses[i].sin.sin_addr;
    else if (family == AF_INET6 && ntohs(addresses[i].sin6.sin6_port) == 53 &&
             addresses[i].sin6.sin6_scope_id == 0)
      bytes = &addresses[i].sin6.sin6_addr;
    // Scoped IPv6 and non-standard ports cannot be faithfully represented by
    // this guest resolv.conf. Never substitute a guessed/public DNS server.
    if (bytes && inet_ntop(family, bytes, text[used], sizeof text[used])) {
      servers[used] = text[used];
      ++used;
    }
  }
  res_ndestroy(&state);
  return used ? dsh_dns_format(servers, used, out, capacity) : EHOSTUNREACH;
}
#endif

static int root_path_only(const char *path) {
  char normalized[MAX_PATH];
  int e = path_normalize(AT_PWD, path, normalized, N_SYMLINK_NOFOLLOW);
  if (e < 0 || strcmp(normalized, path)) return EPERM;
  struct mount *mount = mount_find(normalized);
  int safe = mount == current->fs->root->mount && mount->fs == &fakefs;
  mount_release(mount);
  return safe ? 0 : EPERM;
}

static int write_config(const char *config) {
  const char *target = "/etc/resolv.conf";
  char pending[80];
  // Serialized by the backend gate. Restarted processes begin at zero and
  // skip existing names; neither pid uniqueness nor cleanup of old files is
  // required for ordinary crash recovery.
  static uint64_t sequence;
  // No guest threads run here. Reject both the parent and terminal symlinks,
  // mount redirection and non-regular targets before any write/create.
  struct statbuf st;
  if (generic_statat(AT_PWD, "/etc", &st, false) < 0 || !S_ISDIR(st.mode)) return EPERM;
  if (root_path_only("/etc") || root_path_only(target)) return EPERM;
  int e = generic_statat(AT_PWD, target, &st, false);
  if (e != _ENOENT && (e < 0 || !S_ISREG(st.mode))) return EPERM;
  struct fd *fd = NULL;
  for (unsigned attempt = 0; attempt < 64; ++attempt) {
    if (sequence == UINT64_MAX) return EOVERFLOW;
    snprintf(pending, sizeof pending, "/etc/.dsh-resolv.conf.%llu",
             (unsigned long long)++sequence);
    if (root_path_only(pending)) return EPERM;
    fd = generic_open(pending, O_WRONLY_ | O_CREAT_ | O_EXCL_ | O_NOFOLLOW_, 0644);
    if (!IS_ERR(fd)) break;
    if (PTR_ERR(fd) != _EEXIST) return EIO;
    fd = NULL;
  }
  if (!fd) return EEXIST; // Bounded work; old/unknown entries stay untouched.
  int error = 0;
  if (fd->mount != current->fs->root->mount || fd->mount->fs != &fakefs || !S_ISREG(fd->type)) error = EPERM;
  size_t length = strlen(config), written = 0;
  while (!error && written < length) {
    ssize_t n = fd->ops->write(fd, config + written, length - written);
    if (n == _EINTR) continue;
    if (n <= 0 || (size_t)n > length - written) error = EIO;
    else written += (size_t)n;
  }
  if (fd_close(fd) < 0 && !error) error = EIO;
  if (!error && generic_renameat(AT_PWD, pending, AT_PWD, target) < 0) error = EIO;
  if (error) generic_unlinkat(AT_PWD, pending);
  return error;
}
#endif

int dsh_dns_sync(void) {
#if defined(__APPLE__) || defined(DSH_GUEST_DNS_TEST)
  char config[1024];
  int e = host_config(config, sizeof config);
  if (e == EHOSTUNREACH) {
    // Preserve offline execution, but never retain a previous network's DNS.
    // This is configuration only: no network-ready capability is reported.
    strcpy(config, "# No usable system DNS servers; name resolution is unavailable.\n");
    e = 0;
  }
  return e ? e : write_config(config);
#else
  // Linux is a portability/verification target; it has no Apple resolver API.
  return 0;
#endif
}
