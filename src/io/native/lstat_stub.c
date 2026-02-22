#include <sys/stat.h>
#include <stdint.h>
#include <string.h>

/*
 * bit_lstat: single-syscall file metadata for worktree scanning.
 *
 * Calls lstat() and packs results into a 32-byte buffer:
 *   bytes 0-3:   st_mode   (uint32, little-endian) — includes file type + perms
 *   bytes 4-11:  st_size   (int64, little-endian)
 *   bytes 12-19: mtime_sec (int64, little-endian)
 *   bytes 20-27: mtime_nsec (int64, little-endian)
 *
 * Returns 0 on success, -1 on failure.
 */
int bit_lstat(const char *path, uint8_t *buf) {
  struct stat st;
  if (lstat(path, &st) != 0) {
    return -1;
  }

  uint32_t mode = (uint32_t)st.st_mode;
  int64_t size = (int64_t)st.st_size;

#ifdef __APPLE__
  int64_t mtime_sec = (int64_t)st.st_mtimespec.tv_sec;
  int64_t mtime_nsec = (int64_t)st.st_mtimespec.tv_nsec;
#else
  int64_t mtime_sec = (int64_t)st.st_mtim.tv_sec;
  int64_t mtime_nsec = (int64_t)st.st_mtim.tv_nsec;
#endif

  memcpy(buf + 0, &mode, 4);
  memcpy(buf + 4, &size, 8);
  memcpy(buf + 12, &mtime_sec, 8);
  memcpy(buf + 20, &mtime_nsec, 8);
  return 0;
}
