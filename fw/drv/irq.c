/*
 * One trap handler for every interrupt. The timer interrupt calls its
 * registered function. An external interrupt claims the lowest pending
 * enabled INTC source and calls that source's function, which must clear the
 * source at its block (sources are levels). Anything else is an exception:
 * report it and end the run with 0x100 + mcause.
 */
#include "drv.h"
#include "lib.h"

static irq_fn handlers[32];
static void (*timer_fn)(void);
volatile uint32_t irq_count;

void irq_init(void)
{
  for (int i = 0; i < 32; i++) handlers[i] = 0;
  timer_fn = 0;
  irq_count = 0;
  INTC_ENABLE = 0;
  set_csr(mie, (1u << 7) | (1u << 11));
  set_csr(mstatus, 1u << 3);
}

void irq_register(uint32_t id, irq_fn fn)
{
  handlers[id] = fn;
  INTC_ENABLE = INTC_ENABLE | (1u << id);
}

void irq_timer_register(void (*fn)(void))
{
  timer_fn = fn;
}

/* Sleep until *flag is set by an interrupt handler. The flag is tested with
 * interrupts masked: an interrupt arriving between the test and WFI stays
 * pending and wakes WFI (a pending enabled source wakes it whatever
 * mstatus.MIE says), and it is taken once MIE is set again. */
void irq_wait(volatile uint32_t *flag)
{
  for (;;) {
    clear_csr(mstatus, 1u << 3);
    if (*flag) break;
    __asm__ volatile("wfi");
    set_csr(mstatus, 1u << 3);
  }
  set_csr(mstatus, 1u << 3);
}

uint32_t trap_handler(uint32_t *frame)
{
  (void)frame;
  uint32_t cause = read_csr(mcause);
  uint32_t epc = read_csr(mepc);

  if (cause == MCAUSE_TIMER_IRQ && timer_fn) {
    timer_fn();
  } else if (cause == MCAUSE_EXT_IRQ) {
    uint32_t id = INTC_CLAIM;
    if (id != 0 && handlers[id]) {
      handlers[id](id);
    } else {
      sys_puts("interrupt with no handler: source ");
      sys_putdec(id);
      sys_putc('\n');
      sys_exit(0x200 | (int)id);
    }
  } else {
    sys_puts("exception: mcause ");
    sys_puthex(cause);
    sys_puts(" mepc ");
    sys_puthex(epc);
    sys_puts(" mtval ");
    sys_puthex(read_csr(mtval));
    sys_putc('\n');
    sys_exit(0x100 | (int)(cause & 0xFFu));
  }
  irq_count++;
  return epc;
}
