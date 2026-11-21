/*
 * Resets and the CPU clock gate from firmware (docs/07_clock_reset_power.md).
 * The test runs over two boots:
 *   first boot (RST_CAUSE.POR)
 *     1. SYS SOFT_RESET.DMA: a DMA register written before the soft reset
 *        reads its reset value after it
 *     2. a 2000-tick timer wait in WFI: the CPU clock gate removes most of
 *        its clocks (SLEEP_CYCLES); with CLK_GATE.CPU 0 it removes none
 *     3. a marker in AON_SCRATCH, then PMU CHIP_RESET
 *   second boot (RST_CAUSE.CHIP)
 *     4. the marker survived, PD_HOST is still on and its logic was reset
 *        (SEQ 0), and the first boot's result is in the marker; exit with it
 */
#include "lib.h"
#include "soc.h"

#define MARKER 0xB0070000u
#define TICKS  2000u

static volatile uint32_t ticked;

uint32_t trap_handler(uint32_t *frame)
{
  (void)frame;
  uint32_t cause = read_csr(mcause);
  uint32_t epc = read_csr(mepc);

  if (cause == MCAUSE_TIMER_IRQ) {
    timer_set_cmp(~0ull);
    ticked = 1;
  } else {
    sys_puts("unexpected trap ");
    sys_puthex(cause);
    sys_putc('\n');
    sys_exit(0x100 | (int)(cause & 0xFFu));
  }
  return epc;
}

/* Sleep TICKS timer ticks in WFI; returns the clocks the gate removed. */
static uint32_t timer_sleep(void)
{
  uint32_t s0 = SYS_SLEEP_CYCLES;
  ticked = 0;
  timer_set_cmp(timer_now() + TICKS);
  while (!ticked) __asm__ volatile("wfi");
  return SYS_SLEEP_CYCLES - s0;
}

static uint32_t host_cmd(uint32_t cmd)
{
  HOST_TX = cmd;
  while (!(HOST_STATUS & HOST_RX_VALID)) {
  }
  return HOST_RX;
}

int main(void)
{
  uint32_t cause = PMU_RST_CAUSE;
  int err = 0;

  if (cause & PMU_REGS__RST_CAUSE__POR_bm) {
    sys_puts("first boot: RST_CAUSE ");
    sys_puthex(cause);
    sys_putc('\n');
    PMU_RST_CAUSE = PMU_REGS__RST_CAUSE__POR_bm | PMU_REGS__RST_CAUSE__CHIP_bm;

    /* 1. DMA soft reset. */
    DMA_DESC_PTR = 0x10008000u;
    uint32_t before = DMA_DESC_PTR;
    SYS_SOFT_RESET = SYS_REGS__SOFT_RESET__DMA_bm;
    SYS_SOFT_RESET = 0;
    uint32_t after = DMA_DESC_PTR;
    sys_puts("DMA soft reset: DESC_PTR ");
    sys_puthex(before);
    sys_puts(" before, ");
    sys_puthex(after);
    sys_puts(" after\n");
    if (before != 0x10008000u || after != 0) err |= 1;

    /* 2. CPU clock gate. */
    set_csr(mie, 1u << 7);
    set_csr(mstatus, 1u << 3);
    uint32_t gated = timer_sleep();
    SYS_CLK_GATE = 0;
    uint32_t ungated = timer_sleep();
    SYS_CLK_GATE = 1;
    sys_puts("2000-tick WFI: clock gated for ");
    sys_putdec(gated);
    sys_puts(" clocks; with CLK_GATE.CPU 0: ");
    sys_putdec(ungated);
    sys_putc('\n');
    if (gated < TICKS - 200u || ungated != 0) err |= 2;

    /* 3. Chip reset. */
    PMU_AON_SCRATCH = MARKER | (uint32_t)err;
    sys_puts("chip reset\n");
    PMU_CHIP_RESET = PMU_CHIP_KEY;
    for (;;) {
    }
  }

  /* 4. Second boot. */
  uint32_t mark = PMU_AON_SCRATCH;
  uint32_t st = PMU_PWR_STATUS;
  uint32_t seq = host_cmd(0x30000000u);
  sys_puts("second boot: RST_CAUSE ");
  sys_puthex(cause);
  sys_puts(", AON_SCRATCH ");
  sys_puthex(mark);
  sys_puts(", PD_HOST state ");
  sys_putdec(PMU_STATE(st));
  sys_puts(", SEQ ");
  sys_putdec(seq);
  sys_putc('\n');
  if (cause != PMU_REGS__RST_CAUSE__CHIP_bm) err |= 4;
  if ((mark & 0xFFFF0000u) != MARKER) err |= 4;
  if (PMU_STATE(st) != PMU_STATE_ON || seq != 0) err |= 8;
  return err | (int)(mark & 0xFFu);
}
