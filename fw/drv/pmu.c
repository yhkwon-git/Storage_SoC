/*
 * PMU driver (rtl/pmu/pmu.sv, docs/07_clock_reset_power.md). PD_HOST
 * power-down and power-up sleep until the PMU interrupt (INTC source 10).
 * Every PMU access crosses into clk_aon and takes a few microseconds.
 */
#include "drv.h"

static volatile uint32_t pmu_irq_bits;
static volatile uint32_t pmu_ended;

static void on_pmu(uint32_t id)
{
  pmu_irq_bits = PMU_PWR_IRQ;
  PMU_PWR_IRQ = PMU_IRQ_DONE | PMU_IRQ_ERR;
  /* The source crosses from clk_aon: wait until the INTC sees it drop. */
  while (INTC_PENDING & (1u << id)) {
  }
  pmu_ended = 1;
}

void pmu_init(void)
{
  irq_register(IRQ_PMU, on_pmu);
}

static int pmu_seq(uint32_t ctrl, uint32_t want_state, pmu_result_t *r)
{
  uint32_t t0 = timer_cycles();
  pmu_ended = 0;
  PMU_PWR_CTRL = ctrl;
  irq_wait(&pmu_ended);
  r->cycles = timer_cycles() - t0;
  r->irq = pmu_irq_bits;
  r->status = PMU_PWR_STATUS;
  return (r->irq == PMU_IRQ_DONE && PMU_STATE(r->status) == want_state) ? 0 : -1;
}

int pmu_host_down(pmu_result_t *r)
{
  return pmu_seq(PMU_WAKE_EN | PMU_DOWN, PMU_STATE_OFF, r);
}

int pmu_host_up(pmu_result_t *r)
{
  return pmu_seq(PMU_WAKE_EN | PMU_UP, PMU_STATE_ON, r);
}

void pmu_chip_reset(void)
{
  PMU_CHIP_RESET = PMU_CHIP_KEY;
  for (;;) {
  }
}

uint32_t host_cmd(uint32_t cmd)
{
  HOST_TX = cmd;
  while (!(HOST_STATUS & HOST_RX_VALID)) {
  }
  return HOST_RX;
}
