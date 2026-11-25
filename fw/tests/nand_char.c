/*
 * NAND characterization from firmware (step 3-2, docs/16_nand_model.md), on
 * the nand_model behind each channel in tb_soc, which runs this test with busy
 * times drawn per operation, raw bit errors at 200 per million bits, factory
 * bad blocks 7 and 40 on NAND0 and 13 on NAND1, and block 3 of NAND0 at its
 * rated endurance of 3,000 P/E cycles:
 *   1. both channels: write protect off, 40 ns bus cycles, a busy timeout of
 *      40 x 256 clocks (204.8 us, above the longest erase, 150 us), RESET;
 *   2. bad-block scan of both channels at once: the first spare byte of the
 *      first and the last page of each of the 64 blocks; a block is bad when
 *      either byte has fewer than four 1 bits, so that a raw bit error or two
 *      in an erased byte does not make a good block look bad;
 *   3. NAND0 block 2 (fresh) and block 3 (worn): each erased, four pages
 *      programmed with pseudo-random data and read back, the busy time of
 *      every operation from BUSY_TIME; the worn block must erase slower and
 *      program faster;
 *   4. the raw bit errors of those eight reads, counted against the data
 *      programmed: more on the worn block. The total is printed for the
 *      testbench, which checks it against the bits the model flipped.
 */
#include "lib.h"
#include "soc.h"

#define POLL_MAX 2000000u
#define NBLK    64u
#define FRESH   2u
#define WORN    3u
#define NPG     4u
#define SCAN    0x1000u     /* scan bytes in the page buffer */

uint32_t trap_handler(uint32_t *frame)
{
  (void)frame;
  uint32_t cause = read_csr(mcause);
  sys_puts("unexpected trap ");
  sys_puthex(cause);
  sys_putc('\n');
  sys_exit(0x100 | (int)(cause & 0xFFu));
  return read_csr(mepc);
}

static inline volatile uint8_t *b8(uint32_t a) { return (volatile uint8_t *)(uintptr_t)a; }
static inline volatile uint32_t *w32(uint32_t a) { return (volatile uint32_t *)(uintptr_t)a; }

static uint32_t pop32(uint32_t x)
{
  x = x - ((x >> 1) & 0x55555555u);
  x = (x & 0x33333333u) + ((x >> 2) & 0x33333333u);
  x = (x + (x >> 4)) & 0x0F0F0F0Fu;
  return (x * 0x01010101u) >> 24;
}

/* The data of a page: xorshift32 from a seed made of block and page. */
static uint32_t rng;
static void seed(uint32_t blk, uint32_t pg)
{
  rng = 0x9E3779B9u ^ (blk * 0x85EBCA6Bu) ^ (pg * 0xC2B2AE35u);
  if (rng == 0u) rng = 1u;
}
static uint32_t xs(void)
{
  rng ^= rng << 13;
  rng ^= rng >> 17;
  rng ^= rng << 5;
  return rng;
}

static void fill_page(uint32_t blk, uint32_t pg)
{
  seed(blk, pg);
  for (uint32_t i = 0; i < NAND_PAGE_BYTES; i += 4u) *w32(NAND_PBUF(0) + i) = xs();
}

/* Bits of the page read into the buffer that differ from the data programmed. */
static uint32_t flips_page(uint32_t blk, uint32_t pg)
{
  uint32_t n = 0;
  seed(blk, pg);
  for (uint32_t i = 0; i < NAND_PAGE_BYTES; i += 4u) n += pop32(*w32(NAND_PBUF(0) + i) ^ xs());
  return n;
}

static void submit(uint32_t ch, uint32_t op, uint32_t row, uint32_t col, uint32_t len, uint32_t off, uint32_t tag)
{
  NAND_REG(ch, CMD_ROW) = row;
  NAND_REG(ch, CMD_COL) = col;
  NAND_REG(ch, CMD_LEN) = len;
  NAND_REG(ch, CMD_BUF) = off;
  NAND_REG(ch, CMD_GO) = NAND_GO(op, tag);
}

static uint32_t take(uint32_t ch)
{
  uint32_t c, n = 0;
  do {
    c = NAND_REG(ch, CPL);
    if (++n > POLL_MAX) return 0u;
  } while (!(c & NAND_CPL_VALID));
  return c;
}

static int check(uint32_t ch, uint32_t c, uint32_t tag)
{
  if (!(c & NAND_CPL_VALID) || NAND_CPL_TAG(c) != tag || NAND_CPL_CODE(c) != 0u) {
    sys_puts("nand_char: channel ");
    sys_putdec(ch);
    sys_puts(" completion ");
    sys_puthex(c);
    sys_puts(", expected tag ");
    sys_puthex(tag);
    sys_putc('\n');
    return 1;
  }
  return 0;
}

/* One command on NAND0, waited for; its busy time in clk_nand clocks. */
static int run0(uint32_t op, uint32_t row, uint32_t len, uint32_t *busy)
{
  submit(0, op, row, 0, len, 0, 0x40u + op);
  int e = check(0, take(0), 0x40u + op);
  *busy = NAND_REG(0, BUSY_TIME);
  return e;
}

static void put(const char *s, uint32_t v)
{
  sys_puts(s);
  sys_putdec(v);
}

int main(void)
{
  int err = 0;
  uint32_t bad[2][2] = {{0, 0}, {0, 0}}, want[2][2], nbad = 0;
  uint32_t t_erase[2], t_prog[2][NPG], t_read[2][NPG], flips[2] = {0, 0};

  /* 1. Both channels */
  for (uint32_t ch = 0; ch < 2u; ch++) {
    NAND_REG(ch, CTRL) = 0u;
    NAND_REG(ch, TIMING0) = 0x1111u;                                 /* 1 clock per phase */
    NAND_REG(ch, TIMING1) = (1u << 24) | (4u << 16) | (5u << 8) | 8u;  /* tRR, tADL, tWHR, tWB */
    NAND_REG(ch, TIMEOUT) = 40u;
    submit(ch, NAND_OP_RESET, 0, 0, 0, 0, 0x10u);
    err |= check(ch, take(ch), 0x10u);
  }

  /* 2. Bad-block scan: two bytes a block on each channel, the channels at once */
  for (uint32_t blk = 0; blk < NBLK; blk++) {
    for (uint32_t ch = 0; ch < 2u; ch++)
      for (uint32_t j = 0; j < 2u; j++)
        submit(ch, NAND_OP_READ, blk * NAND_BLOCK_PAGES + j * (NAND_BLOCK_PAGES - 1u), NAND_MAIN_BYTES, 1u,
               SCAN + 2u * blk + j, 0x20u + j);
    for (uint32_t ch = 0; ch < 2u; ch++)
      for (uint32_t j = 0; j < 2u; j++) err |= check(ch, take(ch), 0x20u + j);
  }
  for (uint32_t ch = 0; ch < 2u; ch++)
    for (uint32_t blk = 0; blk < NBLK; blk++)
      if (pop32(*b8(NAND_PBUF(ch) + SCAN + 2u * blk)) < 4u || pop32(*b8(NAND_PBUF(ch) + SCAN + 2u * blk + 1u)) < 4u)
        bad[ch][blk >> 5] |= 1u << (blk & 31u);
  want[0][0] = 1u << 7;
  want[0][1] = 1u << (40 - 32);
  want[1][0] = 1u << 13;
  want[1][1] = 0u;
  sys_puts("nand_char: bad blocks");
  for (uint32_t ch = 0; ch < 2u; ch++) {
    sys_puts(ch == 0u ? " NAND0" : ", NAND1");
    for (uint32_t blk = 0; blk < NBLK; blk++)
      if (bad[ch][blk >> 5] & (1u << (blk & 31u))) {
        put(" ", blk);
        nbad++;
      }
    if (bad[ch][0] != want[ch][0] || bad[ch][1] != want[ch][1]) err |= 2;
  }
  put("; ", nbad);
  sys_puts(" of 128 blocks\n");

  /* 3. A fresh and a worn block of NAND0 */
  for (uint32_t k = 0; k < 2u; k++) {
    uint32_t blk = FRESH + k, row = blk * NAND_BLOCK_PAGES;
    err |= run0(NAND_OP_ERASE, row, 0, &t_erase[k]);
    for (uint32_t pg = 0; pg < NPG; pg++) {
      fill_page(blk, pg);
      err |= run0(NAND_OP_PROG, row + pg, NAND_PAGE_BYTES, &t_prog[k][pg]);
    }
    for (uint32_t pg = 0; pg < NPG; pg++) {
      err |= run0(NAND_OP_READ, row + pg, NAND_PAGE_BYTES, &t_read[k][pg]);
      flips[k] += flips_page(blk, pg);
    }
  }
  for (uint32_t k = 0; k < 2u; k++) {
    uint32_t pmin = 0xFFFFFFFFu, pmax = 0, psum = 0, rmin = 0xFFFFFFFFu, rmax = 0;
    for (uint32_t pg = 0; pg < NPG; pg++) {
      psum += t_prog[k][pg];
      if (t_prog[k][pg] < pmin) pmin = t_prog[k][pg];
      if (t_prog[k][pg] > pmax) pmax = t_prog[k][pg];
      if (t_read[k][pg] < rmin) rmin = t_read[k][pg];
      if (t_read[k][pg] > rmax) rmax = t_read[k][pg];
    }
    put(k == 0u ? "nand_char: fresh block " : "nand_char: worn block ", FRESH + k);
    put(": busy clocks: erase ", t_erase[k]);
    put(", program ", pmin);
    put(" to ", pmax);
    put(" (sum ", psum);
    put("), read ", rmin);
    put(" to ", rmax);
    put("; raw bit errors ", flips[k]);
    put(" in ", NPG);
    sys_puts(" pages\n");
  }
  {
    uint32_t pf = 0, pw = 0;
    for (uint32_t pg = 0; pg < NPG; pg++) {
      pf += t_prog[0][pg];
      pw += t_prog[1][pg];
    }
    if (t_erase[1] <= t_erase[0]) err |= 4;    /* worn: more erase pulses */
    if (pw >= pf) err |= 4;                     /* worn: fewer program loops */
  }
  /* 4. Raw bit errors */
  if (flips[1] <= flips[0]) err |= 8;
  put("nand_char: raw bit errors total ", flips[0] + flips[1]);
  sys_putc('\n');
  return err;
}
