/*
 * Cycles per instruction with code in the boot ROM, measured with mcycle and
 * minstret: a loop of register-only instructions, and a bitwise CRC-32 over a
 * 4 KiB buffer in SRAM. Both results are checked against values computed on
 * the host.
 */
#include "lib.h"
#include "soc.h"

static uint8_t buf[4096];

static uint32_t crc32(const uint8_t *p, uint32_t n)
{
  uint32_t c = 0xFFFFFFFFu;
  for (uint32_t i = 0; i < n; i++) {
    c ^= p[i];
    for (int k = 0; k < 8; k++) c = (c >> 1) ^ (0xEDB88320u & (0u - (c & 1u)));
  }
  return ~c;
}

static void report(const char *what, uint32_t cyc, uint32_t ins)
{
  sys_puts(what);
  sys_puts(": ");
  sys_putdec(cyc);
  sys_puts(" cycles, ");
  sys_putdec(ins);
  sys_puts(" instructions, CPI x100 = ");
  sys_putdec(cyc * 100u / ins);
  sys_putc('\n');
}

int main(void)
{
  uint32_t c0, c1, i0, i1;

  for (uint32_t i = 0; i < sizeof(buf); i++) buf[i] = (uint8_t)(i * 13 + 7);

  uint32_t x = 1;
  c0 = read_csr(mcycle);
  i0 = read_csr(minstret);
  for (uint32_t i = 0; i < 2000; i++) {
    x = x * 3 + i;
    x ^= x >> 5;
  }
  c1 = read_csr(mcycle);
  i1 = read_csr(minstret);
  report("ALU loop", c1 - c0, i1 - i0);

  c0 = read_csr(mcycle);
  i0 = read_csr(minstret);
  uint32_t crc = crc32(buf, sizeof(buf));
  c1 = read_csr(mcycle);
  i1 = read_csr(minstret);
  report("CRC-32 of 4 KiB", c1 - c0, i1 - i0);

  /* Expected values computed on the host: zlib.crc32 of the same buffer, and
   * the same loop in Python. */
  sys_puts("crc ");
  sys_puthex(crc);
  sys_puts(" x ");
  sys_puthex(x);
  sys_putc('\n');
  return (crc != 0xD5CE2A32u) + (x != 0xD953BEC8u);
}
