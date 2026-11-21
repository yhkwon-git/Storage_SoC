/* CRC-32 (reflected, polynomial 0xEDB88320, init and final XOR all ones),
 * one table lookup per byte. The 1 KiB table is built once in SRAM. */
#include "drv.h"

static uint32_t table[256];
static int table_ready;

static void build(void)
{
  for (uint32_t i = 0; i < 256; i++) {
    uint32_t c = i;
    for (int k = 0; k < 8; k++) c = (c & 1u) ? (c >> 1) ^ 0xEDB88320u : c >> 1;
    table[i] = c;
  }
  table_ready = 1;
}

uint32_t crc32(const void *p, uint32_t len)
{
  const uint8_t *b = (const uint8_t *)p;
  uint32_t c = 0xFFFFFFFFu;
  if (!table_ready) build();
  for (uint32_t i = 0; i < len; i++) c = table[(c ^ b[i]) & 0xFFu] ^ (c >> 8);
  return ~c;
}
