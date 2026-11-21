/* Boot, print, and read and write the SYS block. */
#include "lib.h"
#include "soc.h"

int main(void)
{
  int err = 0;

  sys_puts("hello from Ibex\n");

  if (SYS_ID != SOC_ID) {
    sys_puts("SYS ID wrong\n");
    err++;
  }
  SYS_SCRATCH = 0xA5A55A5Au;
  if (SYS_SCRATCH != 0xA5A55A5Au) err++;
  *(volatile uint8_t *)(uintptr_t)(SYS_BASE + 0x009) = 0x3C;
  if (SYS_SCRATCH != 0xA5A53C5Au) {
    sys_puts("SCRATCH byte write wrong\n");
    err++;
  }

  sys_puts("ID ");
  sys_puthex(SYS_ID);
  sys_puts(" VERSION ");
  sys_puthex(SYS_VERSION);
  sys_putc('\n');
  return err;
}
