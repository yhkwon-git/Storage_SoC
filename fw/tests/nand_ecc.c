/*
 * NAND ECC from firmware (step 3-3, docs/17_bch.md), on the nand_model behind
 * NAND0 in tb_soc, which runs this test with raw bit errors at 500 per
 * million bits and block 6 at its rated endurance (ten times the rate):
 *   1. RESET and 40 ns bus cycles; four pages of block 5 programmed with ECC
 *      from an image the CPU writes into the page buffer: 4096 bytes of data
 *      and 4 bytes of metadata a codeword (the row and the codeword number);
 *   2. page 3 read without ECC, as the bus has it, then with ECC: the clocks
 *      of both;
 *   3. pages 0 to 2 read with ECC; every page compared with its image and
 *      every bit error corrected. The total is printed for the testbench,
 *      which checks it against the bits the model flipped;
 *   4. an erased page read with ECC: FFh, every codeword erased;
 *   5. a page of the worn block, programmed and read with ECC: code 4, and
 *      the codewords past correcting (printed for the testbench) as read
 *      while every other one is corrected.
 */
#include "lib.h"
#include "soc.h"

#define POLL_MAX 2000000u
#define FRESH    5u
#define WORN     6u

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

static inline volatile uint32_t *w32(uint32_t a) { return (volatile uint32_t *)(uintptr_t)a; }

/* Word i of the image of a row: data words from xorshift32, metadata words
 * the row and the codeword number. */
static uint32_t rng;
static uint32_t xs(void)
{
  rng ^= rng << 13;
  rng ^= rng >> 17;
  rng ^= rng << 5;
  return rng;
}

static void image(uint32_t row, uint32_t i, uint32_t *w)
{
  if (i == 0u) rng = 0x2545F491u ^ (row * 0x9E3779B9u);
  if (i < NAND_ECC_META / 4u) *w = xs();
  else *w = (row << 8) | (i - NAND_ECC_META / 4u);
}

static void fill(uint32_t row)
{
  uint32_t w;
  for (uint32_t i = 0; i < NAND_ECC_IMAGE / 4u; i++) {
    image(row, i, &w);
    *w32(NAND_PBUF(0) + 4u * i) = w;
  }
}

/* Words of the buffer that differ from the row's image; with cw set, only in
 * the codewords whose bit is clear in skip. */
static uint32_t compare(uint32_t row, uint32_t skip)
{
  uint32_t w, bad = 0;
  for (uint32_t i = 0; i < NAND_ECC_IMAGE / 4u; i++) {
    uint32_t cw = (i < NAND_ECC_META / 4u) ? i / 128u : i - NAND_ECC_META / 4u;
    image(row, i, &w);
    if (!(skip & (1u << cw)) && *w32(NAND_PBUF(0) + 4u * i) != w) bad++;
  }
  return bad;
}

static uint32_t run(uint32_t op, uint32_t row, uint32_t len, uint32_t ecc)
{
  uint32_t c, n = 0;
  NAND_REG(0, CMD_ROW) = row;
  NAND_REG(0, CMD_COL) = 0u;
  NAND_REG(0, CMD_LEN) = len;
  NAND_REG(0, CMD_BUF) = 0u;
  NAND_REG(0, CMD_GO) = NAND_GO(op, 0x60u + op) | (ecc ? NAND_GO_ECC : 0u);
  do {
    c = NAND_REG(0, CPL);
    if (++n > POLL_MAX) return 0u;
  } while (!(c & NAND_CPL_VALID));
  return c;
}

static int expect(uint32_t c, uint32_t op, uint32_t code, const char *what)
{
  if (!(c & NAND_CPL_VALID) || NAND_CPL_TAG(c) != 0x60u + op || NAND_CPL_CODE(c) != code) {
    sys_puts("nand_ecc: ");
    sys_puts(what);
    sys_puts(": completion ");
    sys_puthex(c);
    sys_putc('\n');
    return 1;
  }
  return 0;
}

static void put(const char *s, uint32_t v)
{
  sys_puts(s);
  sys_putdec(v);
}

int main(void)
{
  int err = 0;
  uint32_t e, bits = 0, worst = 0, plain_cyc, ecc_cyc, bad;

  /* 1. Four pages with ECC */
  NAND_REG(0, CTRL) = 0u;
  NAND_REG(0, TIMING0) = 0x1111u;
  NAND_REG(0, TIMING1) = (1u << 24) | (4u << 16) | (5u << 8) | 8u;
  err |= expect(run(NAND_OP_RESET, 0, 0, 0), NAND_OP_RESET, 0, "reset");
  err |= expect(run(NAND_OP_ERASE, FRESH * NAND_BLOCK_PAGES, 0, 0), NAND_OP_ERASE, 0, "erase");
  for (uint32_t pg = 0; pg < 4u; pg++) {
    fill(FRESH * NAND_BLOCK_PAGES + pg);
    err |= expect(run(NAND_OP_PROG, FRESH * NAND_BLOCK_PAGES + pg, 0, 1), NAND_OP_PROG, 0, "ECC program");
  }

  /* 2. Page 3 without ECC, then with it */
  err |= expect(run(NAND_OP_READ, FRESH * NAND_BLOCK_PAGES + 3u, 4233u, 0), NAND_OP_READ, 0, "plain read");
  plain_cyc = NAND_REG(0, CYCLES);
  err |= expect(run(NAND_OP_READ, FRESH * NAND_BLOCK_PAGES + 3u, 0, 1), NAND_OP_READ, 0, "ECC read");
  ecc_cyc = NAND_REG(0, CYCLES);
  e = NAND_REG(0, CPL_ECC);
  bits += NAND_ECC_BITS(e);
  if (NAND_ECC_MAX(e) > worst) worst = NAND_ECC_MAX(e);
  if (compare(FRESH * NAND_BLOCK_PAGES + 3u, 0) != 0u) {
    sys_puts("nand_ecc: page 3 wrong after correction\n");
    err |= 2;
  }

  /* 3. Pages 0 to 2 */
  for (uint32_t pg = 0; pg < 3u; pg++) {
    err |= expect(run(NAND_OP_READ, FRESH * NAND_BLOCK_PAGES + pg, 0, 1), NAND_OP_READ, 0, "ECC read");
    e = NAND_REG(0, CPL_ECC);
    bits += NAND_ECC_BITS(e);
    if (NAND_ECC_MAX(e) > worst) worst = NAND_ECC_MAX(e);
    if (NAND_ECC_UNC(e) != 0u || compare(FRESH * NAND_BLOCK_PAGES + pg, 0) != 0u) {
      sys_puts("nand_ecc: page wrong after correction\n");
      err |= 2;
    }
  }

  /* 4. An erased page */
  err |= expect(run(NAND_OP_READ, FRESH * NAND_BLOCK_PAGES + 10u, 0, 1), NAND_OP_READ, 0, "ECC read of an erased page");
  e = NAND_REG(0, CPL_ECC);
  bad = 0;
  for (uint32_t i = 0; i < NAND_ECC_IMAGE / 4u; i++)
    if (*w32(NAND_PBUF(0) + 4u * i) != 0xFFFFFFFFu) bad++;
  if (NAND_ECC_ERASED(e) != 0xFFu || bad != 0u) {
    sys_puts("nand_ecc: erased page not read as FFh\n");
    err |= 4;
  }

  /* 5. The worn block */
  err |= expect(run(NAND_OP_ERASE, WORN * NAND_BLOCK_PAGES, 0, 0), NAND_OP_ERASE, 0, "erase");
  fill(WORN * NAND_BLOCK_PAGES);
  err |= expect(run(NAND_OP_PROG, WORN * NAND_BLOCK_PAGES, 0, 1), NAND_OP_PROG, 0, "ECC program, worn block");
  {
    uint32_t c = run(NAND_OP_READ, WORN * NAND_BLOCK_PAGES, 0, 1);
    uint32_t code = NAND_CPL_CODE(c);
    e = NAND_REG(0, CPL_ECC);
    if (!(c & NAND_CPL_VALID) || (code != 0u && code != NAND_CODE_UNC) || ((code == NAND_CODE_UNC) != (NAND_ECC_UNC(e) != 0u)) ||
        compare(WORN * NAND_BLOCK_PAGES, NAND_ECC_UNC(e)) != 0u) {
      sys_puts("nand_ecc: worn page\n");
      err |= 8;
    }
    put("nand_ecc: worn page code ", code);
    sys_puts(", past correcting mask ");
    sys_puthex(NAND_ECC_UNC(e));
    put(", bits corrected in the others ", NAND_ECC_BITS(e));
    sys_putc('\n');
  }

  put("nand_ecc: page read in ", plain_cyc);
  put(" clocks without ECC, ", ecc_cyc);
  put(" with it; corrected bits total ", bits);
  put(", at most ", worst);
  put(" in a codeword; ECC_COUNT bits ", NAND_REG(0, ECC_COUNT) & 0xFFFFu);
  put(", codewords past correcting ", NAND_REG(0, ECC_COUNT) >> 16);
  sys_putc('\n');
  return err;
}
