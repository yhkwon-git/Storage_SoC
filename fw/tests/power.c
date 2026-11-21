/*
 * PD_HOST power from firmware (docs/07_clock_reset_power.md):
 *   1. after reset PD_HOST powers up by itself; commands to the placeholder
 *      logic in PD_HOST and their responses (CFG, three ECHO, STATE)
 *   2. a power-down while a response is unread is refused: PMU interrupt
 *      with ERR, result 2, PD_HOST stays on
 *   3. power-down and power-up, each waited for in WFI and ended by the PMU
 *      interrupt (INTC source 10); a command sent while PD_HOST is off is
 *      dropped; after power-up the retained CFG and SEQ are back and LAST is 0
 *   4. clocks per sequence, and how many of them the CPU's clock gate removed
 */
#include "lib.h"
#include "soc.h"

static volatile uint32_t n_irq;
static volatile uint32_t irq_status;

uint32_t trap_handler(uint32_t *frame)
{
  (void)frame;
  uint32_t cause = read_csr(mcause);
  uint32_t epc = read_csr(mepc);

  if (cause == MCAUSE_EXT_IRQ && INTC_CLAIM == IRQ_PMU) {
    irq_status = PMU_PWR_IRQ;
    PMU_PWR_IRQ = PMU_IRQ_DONE | PMU_IRQ_ERR;
    /* The source is a level that crosses from clk_aon: wait until it drops. */
    while (INTC_PENDING & (1u << IRQ_PMU)) {
    }
    n_irq++;
  } else {
    sys_puts("unexpected trap ");
    sys_puthex(cause);
    sys_putc('\n');
    sys_exit(0x100 | (int)(cause & 0xFFu));
  }
  return epc;
}

static uint32_t host_cmd(uint32_t cmd)
{
  HOST_TX = cmd;
  while (!(HOST_STATUS & HOST_RX_VALID)) {
  }
  return HOST_RX;
}

/* Start a sequence and sleep until the PMU interrupt; returns clk_sys
 * clocks, and the clocks the CPU's clock gate removed in *slept. */
static uint32_t pmu_seq(uint32_t ctrl, uint32_t *slept)
{
  uint32_t s0 = SYS_SLEEP_CYCLES;
  uint32_t t0 = TIMER_MTIME_LO;
  n_irq = 0;
  PMU_PWR_CTRL = ctrl;
  while (n_irq == 0) __asm__ volatile("wfi");
  *slept = SYS_SLEEP_CYCLES - s0;
  return TIMER_MTIME_LO - t0;
}

static void put_line(const char *what, uint32_t clocks, uint32_t slept)
{
  sys_puts(what);
  sys_putdec(clocks);
  sys_puts(" clocks, CPU clock gated for ");
  sys_putdec(slept);
  sys_putc('\n');
}

int main(void)
{
  int err = 0;
  uint32_t st, r, slept, t_dn, t_up;

  /* 1. Power-up after reset, then commands. */
  while (PMU_STATE(PMU_PWR_STATUS) != PMU_STATE_ON) {
  }
  PMU_PWR_IRQ = PMU_IRQ_DONE | PMU_IRQ_ERR;
  if (host_cmd(0x1000ABCDu) != 0x1000ABCDu) err |= 1;
  for (uint32_t i = 0; i < 3; i++) {
    uint32_t d = 0x11u * (i + 1);
    if (host_cmd(d) != ((i << 16) | d)) err |= 1;
  }
  r = host_cmd(0x20000000u);
  sys_puts("host: CFG, 3 ECHO, STATE ");
  sys_puthex(r);
  sys_putc('\n');
  if (r != 0xABCD0033u) err |= 1;

  INTC_ENABLE = 1u << IRQ_PMU;
  set_csr(mie, 1u << 11);
  set_csr(mstatus, 1u << 3);

  /* 2. Refused while a response is unread. */
  HOST_TX = 0x44u;
  while (!(HOST_STATUS & HOST_RX_VALID)) {
  }
  (void)pmu_seq(PMU_WAKE_EN | PMU_DOWN, &slept);
  st = PMU_PWR_STATUS;
  sys_puts("power-down with a response unread: result ");
  sys_putdec(PMU_RESULT(st));
  sys_puts(", state ");
  sys_putdec(PMU_STATE(st));
  sys_putc('\n');
  if (irq_status != PMU_IRQ_ERR || PMU_RESULT(st) != 2u || PMU_STATE(st) != PMU_STATE_ON) err |= 2;
  if (HOST_RX != 0x00030044u) err |= 2;

  /* 3. Power cycle. */
  t_dn = pmu_seq(PMU_WAKE_EN | PMU_DOWN, &slept);
  put_line("power-down: ", t_dn, slept);
  st = PMU_PWR_STATUS;
  if (irq_status != PMU_IRQ_DONE || PMU_STATE(st) != PMU_STATE_OFF || PMU_RESULT(st) != 1u) err |= 4;
  HOST_TX = 0x99u;
  if (!(HOST_STATUS & HOST_TX_DROP) || (HOST_STATUS & HOST_ON)) err |= 4;
  HOST_STATUS = HOST_TX_DROP;

  t_up = pmu_seq(PMU_WAKE_EN | PMU_UP, &slept);
  put_line("power-up: ", t_up, slept);
  st = PMU_PWR_STATUS;
  if (irq_status != PMU_IRQ_DONE || PMU_STATE(st) != PMU_STATE_ON) err |= 8;
  r = host_cmd(0x20000000u);
  uint32_t seq = host_cmd(0x30000000u);
  sys_puts("after power-up: STATE ");
  sys_puthex(r);
  sys_puts(" SEQ ");
  sys_putdec(seq);
  sys_puts(" PWR_CYCLES ");
  sys_putdec(PMU_PWR_CYCLES);
  sys_putc('\n');
  if (r != 0xABCD0000u || seq != 4u || PMU_PWR_CYCLES != 1u) err |= 8;
  if (host_cmd(0x55u) != 0x00040055u) err |= 8;

  return err;
}
