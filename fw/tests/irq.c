/*
 * Interrupts: three timer interrupts, then external interrupts raised through
 * the INTC's software-set register, claimed lowest ID first.
 */
#include "lib.h"
#include "soc.h"

#define TICK 2000u

static volatile uint32_t timer_hits;
static volatile uint32_t ext_hits;
static volatile uint32_t claims[4];

uint32_t trap_handler(uint32_t *frame)
{
  (void)frame;
  uint32_t cause = read_csr(mcause);
  uint32_t epc = read_csr(mepc);

  if (cause == MCAUSE_TIMER_IRQ) {
    timer_hits++;
    if (timer_hits < 3) timer_set_cmp(timer_now() + TICK);
    else                timer_set_cmp(~0ull);
  } else if (cause == MCAUSE_EXT_IRQ) {
    uint32_t id = INTC_CLAIM;
    if (ext_hits < 4) claims[ext_hits] = id;
    ext_hits++;
    INTC_SWSET = INTC_SWSET & ~(1u << id);
  } else {
    sys_puts("unexpected trap ");
    sys_puthex(cause);
    sys_putc('\n');
    sys_exit(0x100 | (int)(cause & 0xFFu));
  }
  return epc;
}

int main(void)
{
  int err = 0;

  set_csr(mie, (1u << 7) | (1u << 11));
  set_csr(mstatus, 1u << 3);

  uint64_t t0 = timer_now();
  timer_set_cmp(t0 + TICK);
  while (timer_hits < 3) __asm__ volatile("wfi");
  uint64_t t1 = timer_now();
  sys_puts("timer: 3 interrupts in ");
  sys_putdec((uint32_t)(t1 - t0));
  sys_puts(" ticks\n");
  if (t1 - t0 < 3 * TICK) err++;

  INTC_ENABLE = (1u << 15) | (1u << 9) | (1u << 20);
  INTC_SWSET = 1u << 15;
  while (ext_hits < 1) __asm__ volatile("wfi");
  INTC_SWSET = (1u << 20) | (1u << 9);
  while (ext_hits < 3) __asm__ volatile("wfi");

  sys_puts("external: claims ");
  for (int i = 0; i < 3; i++) {
    sys_putdec(claims[i]);
    sys_putc(' ');
  }
  sys_putc('\n');
  if (claims[0] != 15 || claims[1] != 9 || claims[2] != 20) err++;
  if (INTC_PENDING != 0) err++;
  return err;
}
