/*
 * SRAM test through the data port: words, inverted words, bytes, halfwords,
 * and misaligned words, which Ibex splits into two bus transfers that may sit
 * in different 64-bit words.
 */
#include "lib.h"
#include "soc.h"

extern char _bss_end[];
extern char _stack_top[];

static uint32_t errors;

static void check(uint32_t got, uint32_t exp, const char *what)
{
  if (got != exp) {
    if (errors < 5) {
      sys_puts(what);
      sys_puts(": ");
      sys_puthex(got);
      sys_puts(" expected ");
      sys_puthex(exp);
      sys_putc('\n');
    }
    errors++;
  }
}

int main(void)
{
  volatile uint32_t *w = (volatile uint32_t *)(((uintptr_t)_bss_end + 63) & ~(uintptr_t)63);
  uint32_t n = (uint32_t)(((uintptr_t)_stack_top - 2048 - (uintptr_t)w) / 4);

  for (uint32_t i = 0; i < n; i++) w[i] = (uint32_t)(uintptr_t)&w[i] ^ 0x5A5A5A5Au;
  for (uint32_t i = 0; i < n; i++) check(w[i], (uint32_t)(uintptr_t)&w[i] ^ 0x5A5A5A5Au, "word");
  for (uint32_t i = 0; i < n; i++) w[i] = ~w[i];
  for (uint32_t i = 0; i < n; i++) check(w[i], ~((uint32_t)(uintptr_t)&w[i] ^ 0x5A5A5A5Au), "inverse");

  volatile uint8_t *b = (volatile uint8_t *)w;
  for (uint32_t i = 0; i < 256; i++) b[i] = (uint8_t)(i * 7 + 1);
  for (uint32_t i = 0; i < 256; i++) check(b[i], (uint8_t)(i * 7 + 1), "byte");
  for (uint32_t i = 0; i < 64; i++) {
    uint32_t e = (uint32_t)(uint8_t)(i * 28 + 1) | (uint32_t)(uint8_t)(i * 28 + 8) << 8 |
                 (uint32_t)(uint8_t)(i * 28 + 15) << 16 | (uint32_t)(uint8_t)(i * 28 + 22) << 24;
    check(w[i], e, "bytes as word");
  }

  volatile uint16_t *h = (volatile uint16_t *)w;
  for (uint32_t i = 0; i < 128; i++) h[i] = (uint16_t)(0xC000u + i * 3);
  for (uint32_t i = 0; i < 128; i++) check(h[i], (uint16_t)(0xC000u + i * 3), "halfword");

  /* Misaligned words, including ones that straddle a 64-bit word. */
  volatile uint8_t *base = (volatile uint8_t *)w + 512;
  for (uint32_t off = 1; off < 16; off++) {
    volatile uint32_t *m = (volatile uint32_t *)(base + off * 16);
    uint32_t v = 0x11223344u + off;
    *m = v;
    check(*m, v, "misaligned word");
    check(base[off * 16], v & 0xFFu, "misaligned byte 0");
    check(base[off * 16 + 3], v >> 24, "misaligned byte 3");
  }

  sys_puts("memtest: ");
  sys_putdec(n);
  sys_puts(" words, ");
  sys_putdec(errors);
  sys_puts(" errors\n");
  return (int)errors;
}
