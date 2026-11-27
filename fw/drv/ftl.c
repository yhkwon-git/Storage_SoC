/*
 * Flash translation layer of ssd_app (step 3-4, docs/18_nvme_nand.md).
 *
 * Logical pages (LPN) of 4 KiB, eight 512-byte blocks of the namespace, are
 * kept on the two NAND channels through the BCH path of step 3-3: an ECC
 * page holds 4096 bytes of data and 8 x 4 bytes of metadata (the LPN and a
 * sequence number).
 *   - Even LPNs go to NAND0, odd ones to NAND1.
 *   - Each channel writes its pages in order into one open block at a time;
 *     a block is erased when it is opened. A write always goes to a new
 *     page, and l2p[] points at the last one written; the old one is not
 *     reclaimed (no garbage collection).
 *   - Factory bad blocks (scanned at init: the first spare byte of the first
 *     and last page, bad with fewer than four 1 bits) are never opened; a
 *     block whose erase or program fails is marked bad and left.
 *   - A page never written reads as zeros.
 * Data moves between SRAM and the channel's page buffer by DMA; the channel
 * commands are polled.
 */
#include "drv.h"
#include "lib.h"

#define NBLK      64u
#define NPG       64u
#define NONE      0xFFFFu
#define META_TAG  0x4C500000u    /* "LP" and the LPN in the first metadata word */
#define SCAN_OFF  0x1F00u        /* scan bytes in the page buffer */

ftl_stats_t ftl_stats;

static uint16_t l2p[FTL_LPNS];
static uint8_t  bad[2][NBLK];
static uint32_t cur_blk[2], cur_pg[2];
static uint32_t seq;

static inline volatile uint32_t *w32(uint32_t a) { return (volatile uint32_t *)(uintptr_t)a; }
static inline volatile uint8_t *b8(uint32_t a) { return (volatile uint8_t *)(uintptr_t)a; }

static uint32_t pop8(uint32_t x)
{
  uint32_t n = 0;
  for (; x; x >>= 1) n += x & 1u;
  return n;
}

/* One channel command, waited for; its completion code. */
static uint32_t nand_cmd(uint32_t ch, uint32_t op, uint32_t row, uint32_t col, uint32_t len, uint32_t off, uint32_t ecc)
{
  uint32_t c;
  NAND_REG(ch, CMD_ROW) = row;
  NAND_REG(ch, CMD_COL) = col;
  NAND_REG(ch, CMD_LEN) = len;
  NAND_REG(ch, CMD_BUF) = off;
  NAND_REG(ch, CMD_GO) = NAND_GO(op, 0x70u) | (ecc ? NAND_GO_ECC : 0u);
  do {
    c = NAND_REG(ch, CPL);
  } while (!(c & NAND_CPL_VALID));
  return NAND_CPL_CODE(c);
}

int ftl_init(void)
{
  for (uint32_t ch = 0; ch < 2u; ch++) {
    NAND_REG(ch, CTRL) = 0u;                                          /* write protect off */
    NAND_REG(ch, TIMING0) = 0x1111u;                                  /* 40 ns bus cycles */
    NAND_REG(ch, TIMING1) = (1u << 24) | (4u << 16) | (5u << 8) | 8u;
    NAND_REG(ch, TIMEOUT) = 40u;                                      /* 204.8 us */
    if (nand_cmd(ch, NAND_OP_RESET, 0, 0, 0, 0, 0) != 0u) return -1;
    cur_blk[ch] = NBLK;                                               /* none open yet */
    cur_pg[ch] = NPG;
  }
  for (uint32_t blk = 0; blk < NBLK; blk++)
    for (uint32_t ch = 0; ch < 2u; ch++) {
      uint32_t v0, v1;
      nand_cmd(ch, NAND_OP_READ, blk * NPG, NAND_MAIN_BYTES, 1u, SCAN_OFF, 0);
      v0 = *b8(NAND_PBUF(ch) + SCAN_OFF);
      nand_cmd(ch, NAND_OP_READ, blk * NPG + NPG - 1u, NAND_MAIN_BYTES, 1u, SCAN_OFF, 0);
      v1 = *b8(NAND_PBUF(ch) + SCAN_OFF);
      bad[ch][blk] = (pop8(v0) < 4u || pop8(v1) < 4u) ? 1u : 0u;
      ftl_stats.bad_blocks += bad[ch][blk];
    }
  for (uint32_t l = 0; l < FTL_LPNS; l++) l2p[l] = NONE;
  return 0;
}

/* The next good block of a channel, erased; -1 when there is none. */
static int open_block(uint32_t ch)
{
  for (;;) {
    uint32_t b = (cur_blk[ch] == NBLK) ? 0u : cur_blk[ch] + 1u;
    if (b >= NBLK) return -1;
    cur_blk[ch] = b;
    if (bad[ch][b]) continue;
    ftl_stats.erases++;
    if (nand_cmd(ch, NAND_OP_ERASE, b * NPG, 0, 0, 0, 0) != 0u) {
      bad[ch][b] = 1u;
      ftl_stats.bad_blocks++;
      continue;
    }
    cur_pg[ch] = 0u;
    return 0;
  }
}

int ftl_write(uint32_t lpn, uint32_t sram)
{
  uint32_t ch = lpn & 1u, t0 = timer_cycles();
  dma_result_t r;
  if (lpn >= FTL_LPNS || dma_copy(NAND_PBUF(ch), sram, NAND_MAIN_BYTES, &r) != 0) return -1;
  *w32(NAND_PBUF(ch) + NAND_ECC_META) = META_TAG | lpn;
  *w32(NAND_PBUF(ch) + NAND_ECC_META + 4u) = seq;
  for (uint32_t c = 2u; c < 8u; c++) *w32(NAND_PBUF(ch) + NAND_ECC_META + 4u * c) = 0u;
  for (int tries = 0; tries < 4; tries++) {
    uint32_t row, code;
    if (cur_pg[ch] == NPG && open_block(ch) != 0) return -1;
    row = cur_blk[ch] * NPG + cur_pg[ch];
    code = nand_cmd(ch, NAND_OP_PROG, row, 0, 0, 0, 1);
    cur_pg[ch]++;
    if (code == 0u) {
      l2p[lpn] = (uint16_t)((ch << 12) | row);
      seq++;
      ftl_stats.writes++;
      ftl_stats.write_clocks += timer_cycles() - t0;
      return 0;
    }
    /* The program failed: the block is bad from now on. */
    bad[ch][cur_blk[ch]] = 1u;
    ftl_stats.bad_blocks++;
    ftl_stats.prog_fails++;
    cur_pg[ch] = NPG;
  }
  return -1;
}

int ftl_read(uint32_t lpn, uint32_t sram)
{
  uint32_t t0 = timer_cycles(), ch, row, code, e;
  dma_result_t r;
  if (lpn >= FTL_LPNS) return -1;
  if (l2p[lpn] == NONE) {
    for (uint32_t i = 0; i < NAND_MAIN_BYTES; i += 4u) *w32(sram + i) = 0u;
    ftl_stats.unmapped++;
    return 0;
  }
  ch = l2p[lpn] >> 12;
  row = l2p[lpn] & 0xFFFu;
  code = nand_cmd(ch, NAND_OP_READ, row, 0, 0, 0, 1);
  e = NAND_REG(ch, CPL_ECC);
  ftl_stats.ecc_bits += NAND_ECC_BITS(e);
  ftl_stats.ecc_unc += pop8(NAND_ECC_UNC(e));
  if (code != 0u) return -1;
  if (*w32(NAND_PBUF(ch) + NAND_ECC_META) != (META_TAG | lpn)) {
    ftl_stats.meta_errors++;
    return -1;
  }
  if (dma_copy(sram, NAND_PBUF(ch), NAND_MAIN_BYTES, &r) != 0) return -1;
  ftl_stats.reads++;
  ftl_stats.read_clocks += timer_cycles() - t0;
  return 0;
}
