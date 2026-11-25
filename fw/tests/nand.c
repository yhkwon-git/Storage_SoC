/*
 * NAND channels from firmware (rtl/nand/nand_ctrl.sv, docs/15_nand_channel.md),
 * on the nand_model behind each channel in tb_soc:
 *   1. both channels: write protect off, 40 ns bus cycles, RESET, READ_ID;
 *   2. channel 0: erase a block; a whole page, main and spare area, written
 *      into the page buffer by the CPU and programmed; the buffer cleared, the
 *      page read back and every byte compared; CHANGE READ COLUMN for the
 *      spare area;
 *   3. both channels at once, a page each, with the done interrupts (INTC
 *      sources 6 and 8) seen pending until the completions are taken;
 *   4. write protect on: a program ends with code 3 and the page stays erased.
 * The clock counts come from each channel's CYCLES and BUSY_TIME registers.
 */
#include "lib.h"
#include "soc.h"

#define TIMEOUT 2000000u

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

/* The data byte i of a channel's test page. */
static uint32_t pat(uint32_t ch, uint32_t i)
{
  return (i * 7u + ch * 13u + (i >> 8)) & 0xFFu;
}

static void fill(uint32_t ch, uint32_t off, uint32_t len)
{
  for (uint32_t i = 0; i < len; i += 4u)
    *w32(NAND_PBUF(ch) + off + i) = pat(ch, i) | (pat(ch, i + 1u) << 8) | (pat(ch, i + 2u) << 16) |
                                    (pat(ch, i + 3u) << 24);
}

static void clear(uint32_t ch, uint32_t off, uint32_t len)
{
  for (uint32_t i = 0; i < len; i += 4u) *w32(NAND_PBUF(ch) + off + i) = 0u;
}

/* Bytes of the buffer at off that differ from the page pattern from column col. */
static uint32_t compare(uint32_t ch, uint32_t off, uint32_t col, uint32_t len)
{
  uint32_t bad = 0;
  for (uint32_t i = 0; i < len; i++)
    if (*b8(NAND_PBUF(ch) + off + i) != pat(ch, col + i)) bad++;
  return bad;
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
    if (++n > TIMEOUT) return 0u;
  } while (!(c & NAND_CPL_VALID));
  return c;
}

static int check(uint32_t ch, uint32_t c, uint32_t tag, uint32_t code)
{
  if (!(c & NAND_CPL_VALID) || NAND_CPL_TAG(c) != tag || NAND_CPL_CODE(c) != code) {
    sys_puts("nand: channel ");
    sys_putdec(ch);
    sys_puts(" completion ");
    sys_puthex(c);
    sys_puts(", expected tag ");
    sys_puthex(tag);
    sys_puts(" code ");
    sys_putdec(code);
    sys_putc('\n');
    return 1;
  }
  return 0;
}

static int run(uint32_t ch, uint32_t op, uint32_t row, uint32_t col, uint32_t len, uint32_t off, uint32_t code)
{
  submit(ch, op, row, col, len, off, 0x20u + op);
  return check(ch, take(ch), 0x20u + op, code);
}

static void stat(const char *what, uint32_t v)
{
  sys_puts(what);
  sys_putdec(v);
}

int main(void)
{
  int err = 0;
  uint32_t prog_cyc, prog_busy, read_cyc, read_busy, pend = 0, c0, c1;

  /* 1. Both channels */
  for (uint32_t ch = 0; ch < 2u; ch++) {
    NAND_REG(ch, CTRL) = 0u;
    NAND_REG(ch, TIMING0) = 0x1111u;                                 /* 1 clock per phase */
    NAND_REG(ch, TIMING1) = (1u << 24) | (4u << 16) | (5u << 8) | 8u;  /* tRR, tADL, tWHR, tWB */
    err |= run(ch, NAND_OP_RESET, 0, 0, 0, 0, 0);
    err |= run(ch, NAND_OP_ID, 0, 0x00, 4, 0, 0);
    if (*b8(NAND_PBUF(ch)) != 0x00u || *b8(NAND_PBUF(ch) + 1u) != 'N' || *b8(NAND_PBUF(ch) + 2u) != 'S' ||
        *b8(NAND_PBUF(ch) + 3u) != '1') {
      sys_puts("nand: wrong ID\n");
      err |= 2;
    }
  }

  /* 2. A whole page on channel 0 (block 3, page 0) */
  err |= run(0, NAND_OP_ERASE, 192, 0, 0, 0, 0);
  fill(0, 0, NAND_PAGE_BYTES);
  err |= run(0, NAND_OP_PROG, 192, 0, NAND_PAGE_BYTES, 0, 0);
  prog_cyc = NAND_REG(0, CYCLES);
  prog_busy = NAND_REG(0, BUSY_TIME);
  clear(0, 0, NAND_PAGE_BYTES);
  err |= run(0, NAND_OP_READ, 192, 0, NAND_PAGE_BYTES, 0, 0);
  read_cyc = NAND_REG(0, CYCLES);
  read_busy = NAND_REG(0, BUSY_TIME);
  if (compare(0, 0, 0, NAND_PAGE_BYTES) != 0u) {
    sys_puts("nand: page read back wrong\n");
    err |= 4;
  }
  err |= run(0, NAND_OP_RDCOL, 0, NAND_MAIN_BYTES, NAND_PAGE_BYTES - NAND_MAIN_BYTES, 0x1800u, 0);
  if (compare(0, 0x1800u, NAND_MAIN_BYTES, NAND_PAGE_BYTES - NAND_MAIN_BYTES) != 0u) {
    sys_puts("nand: spare area read back wrong\n");
    err |= 4;
  }

  /* 3. Both channels at once: channel 0 block 3 page 1, channel 1 block 4 page 0 */
  err |= run(1, NAND_OP_ERASE, 256, 0, 0, 0, 0);
  fill(0, 0, NAND_PAGE_BYTES);
  fill(1, 0, NAND_PAGE_BYTES);
  NAND_REG(0, CTRL) = NAND_CTRL_IEN_DONE;
  NAND_REG(1, CTRL) = NAND_CTRL_IEN_DONE;
  submit(0, NAND_OP_PROG, 193, 0, NAND_PAGE_BYTES, 0, 0x31u);
  submit(1, NAND_OP_PROG, 256, 0, NAND_PAGE_BYTES, 0, 0x32u);
  for (uint32_t n = 0; n < TIMEOUT && pend != ((1u << IRQ_NAND0_DONE) | (1u << IRQ_NAND1_DONE)); n++)
    pend = INTC_PENDING & ((1u << IRQ_NAND0_DONE) | (1u << IRQ_NAND1_DONE));
  if (pend != ((1u << IRQ_NAND0_DONE) | (1u << IRQ_NAND1_DONE))) {
    sys_puts("nand: done interrupts not pending\n");
    err |= 8;
  }
  c0 = take(0);
  c1 = take(1);
  err |= check(0, c0, 0x31u, 0);
  err |= check(1, c1, 0x32u, 0);
  if (INTC_PENDING & ((1u << IRQ_NAND0_DONE) | (1u << IRQ_NAND1_DONE))) {
    sys_puts("nand: done interrupts still pending\n");
    err |= 8;
  }
  NAND_REG(0, CTRL) = 0u;
  NAND_REG(1, CTRL) = 0u;
  clear(0, 0, NAND_PAGE_BYTES);
  clear(1, 0, NAND_PAGE_BYTES);
  submit(0, NAND_OP_READ, 193, 0, NAND_PAGE_BYTES, 0, 0x33u);
  submit(1, NAND_OP_READ, 256, 0, NAND_PAGE_BYTES, 0, 0x34u);
  err |= check(0, take(0), 0x33u, 0);
  err |= check(1, take(1), 0x34u, 0);
  if (compare(0, 0, 0, NAND_PAGE_BYTES) != 0u || compare(1, 0, 0, NAND_PAGE_BYTES) != 0u) {
    sys_puts("nand: pages of the two channels read back wrong\n");
    err |= 4;
  }

  /* 4. Write protect */
  NAND_REG(0, CTRL) = NAND_CTRL_WP;
  fill(0, 0, 64u);
  err |= run(0, NAND_OP_PROG, 194, 0, 64u, 0, 3u);
  NAND_REG(0, CTRL) = 0u;
  err |= run(0, NAND_OP_READ, 194, 0, 64u, 0x100u, 0);
  for (uint32_t i = 0; i < 64u; i++)
    if (*b8(NAND_PBUF(0) + 0x100u + i) != 0xFFu) {
      sys_puts("nand: protected page changed\n");
      err |= 16;
      break;
    }

  stat("nand: page of ", NAND_PAGE_BYTES);
  stat(" bytes: program ", prog_cyc);
  stat(" clocks (busy ", prog_busy);
  stat("), read ", read_cyc);
  stat(" clocks (busy ", read_busy);
  stat("); commands on channel 0 ", NAND_REG(0, COUNT) & 0xFFFFu);
  stat(", channel 1 ", NAND_REG(1, COUNT) & 0xFFFFu);
  stat(", with an error code ", (NAND_REG(0, COUNT) >> 16) + (NAND_REG(1, COUNT) >> 16));
  sys_putc('\n');
  return err;
}
