#include "lib.h"
#include "soc.h"

void sys_putc(char c)
{
  SYS_CONSOLE = (uint8_t)c;
}

void sys_puts(const char *s)
{
  while (*s) sys_putc(*s++);
}

void sys_puthex(uint32_t v)
{
  sys_puts("0x");
  for (int i = 7; i >= 0; i--) {
    uint32_t d = (v >> (i * 4)) & 0xFu;
    sys_putc((char)(d < 10 ? '0' + d : 'a' + d - 10));
  }
}

void sys_putdec(uint32_t v)
{
  char buf[11];
  int n = 0;
  do {
    buf[n++] = (char)('0' + v % 10);
    v /= 10;
  } while (v != 0);
  while (n > 0) sys_putc(buf[--n]);
}

void sys_exit(int code)
{
  SYS_EXIT = (uint32_t)code;
  for (;;) {
  }
}

/* Default: any trap is unexpected; report it and stop with 0x100 + cause. */
__attribute__((weak)) uint32_t trap_handler(uint32_t *frame)
{
  (void)frame;
  sys_puts("unexpected trap: mcause ");
  sys_puthex(read_csr(mcause));
  sys_puts(" mepc ");
  sys_puthex(read_csr(mepc));
  sys_puts(" mtval ");
  sys_puthex(read_csr(mtval));
  sys_putc('\n');
  sys_exit(0x100 | (int)(read_csr(mcause) & 0xFFu));
}
