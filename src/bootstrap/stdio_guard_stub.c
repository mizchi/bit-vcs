#include <fcntl.h>
#include <unistd.h>

void bit_ensure_stdin_open(void) {
  int stdin_flags = fcntl(0, F_GETFL);
  if ((stdin_flags != -1) && (stdin_flags & O_ACCMODE) == O_RDONLY) {
    return;
  }

  const char *null_device = "/dev/null";
#if defined(_WIN32) || defined(_WIN64)
  null_device = "NUL";
#endif

  int null_fd = open(null_device, O_RDONLY);
  if (null_fd < 0) {
    return;
  }
  if (dup2(null_fd, 0) < 0) {
    close(null_fd);
    return;
  }
  if (null_fd != 0) {
    close(null_fd);
  }
}

__attribute__((constructor)) static void bit_ensure_stdin_open_ctor(void) {
  bit_ensure_stdin_open();
}
