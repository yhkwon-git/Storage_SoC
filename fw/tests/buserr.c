/*
 * Bus errors reach the core as access faults:
 *   load from an unmapped address     DECERR from the crossbar      -> load fault
 *   store to the boot ROM             SLVERR from the ROM           -> store fault
 *   load from an APB slot with no
 *   peripheral, and from an undefined
 *   SYS offset                        PSLVERR -> SLVERR             -> load fault
 *   call to an unmapped address       DECERR on the instruction bus -> fetch fault
 *   call into the APB window          no instruction path, DECERR   -> fetch fault
 * and the instruction port does reach SRAM: code copied there runs.
 */
#include "lib.h"
#include "soc.h"

static volatile uint32_t traps;
static volatile uint32_t last_cause;
static volatile uint32_t last_tval;

uint32_t trap_handler(uint32_t *frame)
{
  uint32_t cause = read_csr(mcause);
  uint32_t epc = read_csr(mepc);
  traps++;
  last_cause = cause;
  last_tval = read_csr(mtval);
  if (cause == MCAUSE_INSTR_FAULT) return frame[0]; /* back to the caller */
  if (cause == MCAUSE_LOAD_FAULT || cause == MCAUSE_STORE_FAULT) {
    uint16_t ins = *(volatile uint16_t *)(uintptr_t)epc;
    return epc + (((ins & 3u) == 3u) ? 4u : 2u);
  }
  sys_puts("unexpected trap ");
  sys_puthex(cause);
  sys_putc('\n');
  sys_exit(0x100 | (int)(cause & 0xFFu));
}

static int expect(const char *what, uint32_t cause, uint32_t tval)
{
  int bad = (traps != 1 || last_cause != cause || last_tval != tval);
  sys_puts(what);
  sys_puts(bad ? ": WRONG, mcause " : ": mcause ");
  sys_putdec(last_cause);
  sys_puts(" mtval ");
  sys_puthex(last_tval);
  sys_putc('\n');
  traps = 0;
  return bad;
}

typedef int (*fn_t)(void);

static uint32_t code[4] __attribute__((aligned(8)));

int main(void)
{
  int err = 0;
  volatile uint32_t sink;

  traps = 0;
  sink = *(volatile uint32_t *)0x20000000u;
  err += expect("unmapped load", MCAUSE_LOAD_FAULT, 0x20000000u);

  *(volatile uint32_t *)0x00001000u = 1;
  err += expect("ROM store", MCAUSE_STORE_FAULT, 0x00001000u);

  sink = *(volatile uint32_t *)(uintptr_t)EMPTY_SLOT_BASE;
  err += expect("empty APB slot", MCAUSE_LOAD_FAULT, EMPTY_SLOT_BASE);

  sink = *(volatile uint32_t *)(uintptr_t)(SYS_BASE + 0x20u);
  err += expect("undefined SYS offset", MCAUSE_LOAD_FAULT, SYS_BASE + 0x20u);

  ((fn_t)0x20000000u)();
  err += expect("fetch from unmapped", MCAUSE_INSTR_FAULT, 0x20000000u);

  ((fn_t)(uintptr_t)SYS_BASE)();
  err += expect("fetch from APB", MCAUSE_INSTR_FAULT, SYS_BASE);

  /* li a0, 42; ret */
  code[0] = 0x02A00513u;
  code[1] = 0x00008067u;
  __asm__ volatile("fence.i" ::: "memory");
  int r = ((fn_t)(uintptr_t)code)();
  sys_puts("code in SRAM returned ");
  sys_putdec((uint32_t)r);
  sys_putc('\n');
  if (r != 42 || traps != 0) err++;

  (void)sink;
  return err;
}
