/*
 * DMA from firmware (rtl/dma/dma.sv, docs/06_dma.md):
 *   1. 4 KiB SRAM to SRAM, timed with the DMA's CYCLES register
 *   2. a chain through both NAND page buffers, A -> NAND0 -> NAND1 -> C; each
 *      step reads what the step before wrote, so steps 2 and 3 carry FENCE
 *   3. four unaligned pieces scattered into one buffer, finished by the DONE
 *      interrupt (INTC source 1); every byte of the buffer is checked
 *   4. two bus errors: a write to the ROM and a read of the APB window, which
 *      M2 has no path to; both end with the ERR interrupt (source 2) and the
 *      cause, response and address in ERR_INFO and ERR_ADDR
 * The buffers are M2's quarter of SRAM, 0x1000_8000 to 0x1000_BFFF.
 */
#include "lib.h"
#include "soc.h"

#define BUF_A (SRAM_BASE + 0x8000u)
#define BUF_B (SRAM_BASE + 0x9000u)
#define BUF_C (SRAM_BASE + 0xA000u)
#define BUF_D (SRAM_BASE + 0xB000u)
#define BUF_LEN 4096u

#define barrier() __asm__ volatile("" ::: "memory")

static dma_desc_t desc[8];
static volatile uint32_t n_irq;
static volatile uint32_t irq_id;
static volatile uint32_t irq_status;

static inline uint8_t *b8(uint32_t a) { return (uint8_t *)(uintptr_t)a; }
static inline uint32_t *w32(uint32_t a) { return (uint32_t *)(uintptr_t)a; }
static inline uint32_t addr(const dma_desc_t *d) { return (uint32_t)(uintptr_t)d; }

uint32_t trap_handler(uint32_t *frame)
{
  (void)frame;
  uint32_t cause = read_csr(mcause);
  uint32_t epc = read_csr(mepc);

  if (cause == MCAUSE_EXT_IRQ) {
    irq_id = INTC_CLAIM;
    irq_status = DMA_STATUS;
    /* The sources are levels: clear them at the DMA. */
    DMA_STATUS = DMA_DONE | DMA_ERR;
    n_irq++;
  } else {
    sys_puts("unexpected trap ");
    sys_puthex(cause);
    sys_putc('\n');
    sys_exit(0x100 | (int)(cause & 0xFFu));
  }
  return epc;
}

static void fill(uint32_t a, uint32_t n, uint32_t seed)
{
  for (uint32_t i = 0; i < n / 4; i++) {
    seed = seed * 1664525u + 1013904223u;
    w32(a)[i] = seed;
  }
}

static int same_words(uint32_t a, uint32_t b, uint32_t n)
{
  for (uint32_t i = 0; i < n / 4; i++) {
    if (w32(a)[i] != w32(b)[i]) return 0;
  }
  return 1;
}

static void set_desc(int i, uint32_t src, uint32_t dst, uint32_t len, uint32_t next)
{
  desc[i].src = src;
  desc[i].dst = dst;
  desc[i].len = len;
  desc[i].next = next;
}

static void dma_start(const dma_desc_t *d)
{
  barrier(); /* descriptors and buffers are written before START */
  DMA_DESC_PTR = addr(d);
  DMA_CTRL = DMA_START;
}

/* Run a chain to its end by polling; returns STATUS and clears it. */
static uint32_t dma_run(const dma_desc_t *d)
{
  uint32_t st;
  dma_start(d);
  do {
    st = DMA_STATUS;
  } while (st & DMA_BUSY);
  DMA_STATUS = DMA_DONE | DMA_ERR;
  barrier();
  return st;
}

/* Run a chain and wait for its interrupt. */
static void dma_run_irq(const dma_desc_t *d)
{
  n_irq = 0;
  dma_start(d);
  while (n_irq == 0) __asm__ volatile("wfi");
  barrier();
}

int main(void)
{
  int err = 0;
  uint32_t st, cyc;

  fill(BUF_A, BUF_LEN, 1);
  fill(BUF_B, BUF_LEN, 2);
  fill(BUF_C, BUF_LEN, 3);
  fill(BUF_D, BUF_LEN, 4);

  /* 1. SRAM to SRAM. */
  set_desc(0, BUF_A, BUF_B, BUF_LEN, 0);
  st = dma_run(&desc[0]);
  cyc = DMA_CYCLES;
  sys_puts("copy: 4096 B SRAM to SRAM in ");
  sys_putdec(cyc);
  sys_puts(" DMA cycles\n");
  if (st != DMA_DONE || !same_words(BUF_B, BUF_A, BUF_LEN)) err |= 1;

  /* 2. Through both page buffers. */
  set_desc(0, BUF_A, NAND0_BASE, BUF_LEN, addr(&desc[1]));
  set_desc(1, NAND0_BASE, NAND1_BASE, BUF_LEN | DMA_FENCE, addr(&desc[2]));
  set_desc(2, NAND1_BASE, BUF_C, BUF_LEN | DMA_FENCE, 0);
  st = dma_run(&desc[0]);
  cyc = DMA_CYCLES;
  sys_puts("page buffers: SRAM, NAND0, NAND1, SRAM, 3 x 4096 B with FENCE in ");
  sys_putdec(cyc);
  sys_puts(" DMA cycles\n");
  if (st != DMA_DONE || DMA_DESC_DONE != 3 || !same_words(BUF_C, BUF_A, BUF_LEN)) err |= 2;

  /* 3. Scatter four unaligned pieces of A into D, finished by DONE. A copy of
   *    D in B gives the bytes the pieces must leave alone. */
  static const uint32_t so[4]  = {1, 700, 1500, 3001};
  static const uint32_t dof[4] = {6, 1000, 2003, 3100};
  static const uint32_t ln[4]  = {600, 777, 1000, 995};
  for (uint32_t i = 0; i < BUF_LEN / 4; i++) w32(BUF_B)[i] = w32(BUF_D)[i];
  for (int i = 0; i < 4; i++) {
    set_desc(i, BUF_A + so[i], BUF_D + dof[i], ln[i], (i < 3) ? addr(&desc[i + 1]) : 0);
  }
  INTC_ENABLE = (1u << IRQ_DMA_DONE) | (1u << IRQ_DMA_ERR);
  set_csr(mie, 1u << 11);
  set_csr(mstatus, 1u << 3);
  dma_run_irq(&desc[0]);
  uint32_t bad = 0;
  for (uint32_t j = 0; j < BUF_LEN; j++) {
    uint8_t want = b8(BUF_B)[j];
    for (int i = 0; i < 4; i++) {
      if (j >= dof[i] && j < dof[i] + ln[i]) want = b8(BUF_A)[so[i] + (j - dof[i])];
    }
    if (b8(BUF_D)[j] != want) bad++;
  }
  sys_puts("scatter: 4 unaligned pieces, interrupt ID ");
  sys_putdec(irq_id);
  sys_puts(", DESC_DONE ");
  sys_putdec(DMA_DESC_DONE);
  sys_puts(", bytes wrong ");
  sys_putdec(bad);
  sys_putc('\n');
  if (irq_id != IRQ_DMA_DONE || irq_status != DMA_DONE || DMA_DESC_DONE != 4 || bad != 0) err |= 4;

  /* 4. Bus errors: no M2 path to the ROM or the APB window. */
  set_desc(4, BUF_A, ROM_BASE + 0x1000u, 64, 0);
  dma_run_irq(&desc[4]);
  uint32_t info = DMA_ERR_INFO, ea = DMA_ERR_ADDR;
  sys_puts("write to ROM: interrupt ID ");
  sys_putdec(irq_id);
  sys_puts(", ERR_INFO ");
  sys_puthex(info);
  sys_puts(", ERR_ADDR ");
  sys_puthex(ea);
  sys_putc('\n');
  if (irq_id != IRQ_DMA_ERR || irq_status != DMA_ERR || info != 0x33u || ea != ROM_BASE + 0x1000u) err |= 8;

  set_desc(5, APB_BASE, BUF_B, 64, 0);
  dma_run_irq(&desc[5]);
  info = DMA_ERR_INFO;
  ea = DMA_ERR_ADDR;
  sys_puts("read of APB: interrupt ID ");
  sys_putdec(irq_id);
  sys_puts(", ERR_INFO ");
  sys_puthex(info);
  sys_puts(", ERR_ADDR ");
  sys_puthex(ea);
  sys_putc('\n');
  if (irq_id != IRQ_DMA_ERR || irq_status != DMA_ERR || info != 0x32u || ea != APB_BASE) err |= 16;

  return err;
}
