// Freestanding Linux/aarch64 regression fixture; no Python or libc required.
// Build with LLVM clang --target=aarch64-linux-musl -nostdlib -static -fuse-ld=lld.
// Modes r/w/p must terminate with SIGBUS (135); f checks it in a fork child.
// Mode x tests MAP_FIXED and partial-page EOF/private-copy semantics.
typedef unsigned long word;
static long call(long nr, word a, word b, word c, word d, word e, word f) {
  register word x0 __asm__("x0") = a, x1 __asm__("x1") = b;
  register word x2 __asm__("x2") = c, x3 __asm__("x3") = d;
  register word x4 __asm__("x4") = e, x5 __asm__("x5") = f;
  register word x8 __asm__("x8") = nr;
  __asm__ volatile("svc 0" : "+r"(x0) : "r"(x1), "r"(x2), "r"(x3), "r"(x4), "r"(x5), "r"(x8) : "memory", "cc");
  return x0;
}
static void end(int code) {
  call(93, code, 0, 0, 0, 0, 0);
  __builtin_unreachable();
}
static int run(char mode) {
  long fd = call(56, -100, (word)"/workspace/mmap-file", 2 | 64 | 512,
                 mode == 'c' ? 0100600 : 0600, 0, 0);
  if (fd < 0 || call(46, fd, 4097, 0, 0, 0, 0)) return 1;
  if (mode == 'c') return 0;
  char mark = 83;
  if (call(68, fd, (word)&mark, 1, 4096, 0, 0) != 1) return 2;
  if (mode == 'e' || mode == 'z') {
    if (mode == 'z' && call(46, fd, 0, 0, 0, 0, 0)) return 14;
    long empty = call(222, 0, 4096, 3, 2, fd, mode == 'e' ? 8192 : 0);
    if (empty < 0) return 15;
    volatile char value = *(volatile char *)empty;
    (void)value;
    return 99;
  }
  long address = call(222, 0, 12288, 3, 2, fd, 0);
  if (address < 0) return 3;
  volatile char *p = (volatile char *)address;
  if (p[0] || p[4096] != mark || p[4097] || p[8191]) return 4;
  p[4096] = 12; // private writes never change the workspace file
  if (call(67, fd, (word)&mark, 1, 4096, 0, 0) != 1 || mark != 83) return 5;
  if (mode == 'p' && call(226, address, 12288, 7, 0, 0, 0)) return 6;
  if (mode == 'f') {
    long child = call(220, 17, 0, 0, 0, 0, 0);
    if (child < 0) return 7;
    if (child) {
      int status;
      if (call(260, child, (word)&status, 0, 0, 0, 0) != child) return 8;
      return (status & 127) == 7 ? 0 : 9;
    }
  }
  if (mode == 'x') {
    if (call(222, address + 8192, 4096, 3, 2 | 16 | 32, -1, 0) != address + 8192) return 10;
    if (p[8192]) return 11;
    p[8192] = 91;
    if (p[8192] != 91) return 12;
    // A map whose offset is entirely past EOF also succeeds; access faults.
    long empty = call(222, 0, 4096, 3, 2, fd, 8192);
    if (empty < 0) return 13;
    return 0;
  }
  if (mode == 'w') p[8192] = 1;
  else { volatile char value = p[8192]; (void)value; }
  return 99; // reaching this means a whole EOF page was exposed
}
// Preserve Linux's initial stack pointer before the C prologue.
__attribute__((naked)) void _start(void) {
  __asm__("mov x0, sp\n bl entry\n");
}
__attribute__((used)) void entry(word *stack) {
  word argc = stack[0];
  char **argv = (char **)(stack + 1);
  end(run(argc > 1 ? argv[1][0] : 'x'));
}
