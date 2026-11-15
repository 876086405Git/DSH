#include "bound_ish_mapping.h"
#include "kernel/calls.h"
#include "kernel/errno.h"
#include "kernel/memory.h"
#include <errno.h>
#include <stdint.h>
#include <sys/mman.h>
void *dsh_private_backing(dsh_file *f, size_t length, off_t offset,
                          size_t *file_bytes) {
  if (!length || offset < 0 || length > INT64_MAX ||
      (uint64_t)offset > INT64_MAX - length) {
    errno = EINVAL;
    return MAP_FAILED;
  }
  char unused;
  // Recheck the immutable file policy even for an empty EOF segment.
  if (dsh_file_pread(f, &unused, 0, offset) < 0)
    return MAP_FAILED;
  struct stat s;
  if (dsh_file_stat(f, &s) < 0)
    return MAP_FAILED;
  if (s.st_size < 0) {
    errno = EINVAL;
    return MAP_FAILED;
  }
  uint64_t remaining = offset < s.st_size ? (uint64_t)(s.st_size - offset) : 0;
  // Anonymous backing has no file writeback, even after guest mprotect.
  void *memory = mmap(NULL, length, PROT_READ | PROT_WRITE,
                      MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  if (memory == MAP_FAILED)
    return memory;
  size_t bytes = remaining < length ? (size_t)remaining : length;
  size_t done = 0;
  while (done < bytes) {
    ssize_t n =
        dsh_file_pread(f, (char *)memory + done, bytes - done, offset + done);
    if (n < 0 && errno == EINTR)
      continue;
    if (n <= 0) {
      int e = n < 0 ? errno : EIO;
      munmap(memory, length);
      errno = e;
      return MAP_FAILED;
    }
    done += n;
  }
  // mmap zeroes the partial EOF tail used by an ELF load segment.
  *file_bytes = bytes;
  return memory;
}
int dsh_bound_mmap(struct fd *f, struct mem *mem, page_t start, pages_t pages,
                   off_t offset, int prot, int flags) {
  if ((flags & (MMAP_SHARED | MMAP_PRIVATE)) != MMAP_PRIVATE)
    return _ENOTSUP;
  if (flags & ~(MMAP_PRIVATE | MMAP_FIXED | MMAP_NORESERVE))
    return _ENOTSUP;
  if (prot & ~P_RWX)
    return _ENOTSUP;
  if (!pages || pages > SIZE_MAX / PAGE_SIZE || start + pages < start ||
      offset < 0 || offset % PAGE_SIZE)
    return _EINVAL;
  size_t length = (size_t)pages * PAGE_SIZE;
  size_t file_bytes;
  void *memory = dsh_private_backing(f->data, length, offset, &file_bytes);
  if (memory == MAP_FAILED)
    return errno_map();
  // P_EXEC describes emulated guest permissions, never host PROT_EXEC.
  int result = pt_map(mem, start, pages, memory, 0, prot);
  if (result < 0)
    munmap(memory, length);
  else {
    // musl reserves the full ELF virtual span before remapping individual
    // segments, including anonymous BSS. Accept that reservation, but never
    // expose whole pages beyond EOF as zero-filled file data. The kernel's
    // translator rejects these pages and delivers guest SIGBUS. mprotect
    // preserves the guard; MAP_FIXED replacement removes it with the old map.
    pages_t readable = (file_bytes + PAGE_SIZE - 1) / PAGE_SIZE;
    for (pages_t page = readable; page < pages; page++)
      mem_pt(mem, start + page)->flags |= P_FILE_EOF;
  }
  return result;
}
