/*
 * Host interface from firmware (step 2-1, docs/10_transaction_layer.md),
 * against the host model of dv/tb/tb_soc.sv:
 *   1. wait until the host has enumerated the device: Bus Master Enable and
 *      MSI-X Enable set in configuration space (HOST LINK_STATUS)
 *   2. host to SoC: 8 KiB from host 0x1_0000_0000 (a 64-bit address, so 4DW
 *      headers) into SRAM 0x1000_8000 by the bus master, ended by its
 *      interrupt (INTC source 12); every byte checked against the host
 *      model's fill pattern
 *   3. SoC to host: the buffer, each word XORed with 0xA5A5A5A5, to host
 *      0x2_0000_0000; the testbench checks it after the run
 *   4. host and local addresses in different DW lanes: 1000 bytes from host
 *      0x3000_0004 to SRAM 0x1000_A008, checked, and back to host
 *      0x3000_200C (checked by the testbench)
 *   5. MSI-X vector 2 (the testbench counts the message)
 * Prints the clocks of each transfer (BM_CYCLES).
 */
#include "lib.h"
#include "soc.h"

static volatile uint32_t n_irq;
static volatile uint32_t bm_status;

uint32_t trap_handler(uint32_t *frame)
{
  (void)frame;
  uint32_t cause = read_csr(mcause);
  uint32_t epc = read_csr(mepc);

  if (cause == MCAUSE_EXT_IRQ && INTC_CLAIM == IRQ_HOST_BM) {
    bm_status = HOST_BM_STATUS;
    HOST_BM_STATUS = HOST_BM_DONE | HOST_BM_ERR;
    n_irq++;
  } else {
    sys_puts("unexpected trap ");
    sys_puthex(cause);
    sys_putc('\n');
    sys_exit(0x100 | (int)(cause & 0xFFu));
  }
  return epc;
}

/* Sleep until the interrupt: the flag is tested with interrupts masked, so
 * one that arrives between the test and WFI still wakes the core. */
static void wait_irq(void)
{
  for (;;) {
    __asm__ volatile("csrc mstatus, 8");
    if (n_irq) break;
    __asm__ volatile("wfi");
    __asm__ volatile("csrs mstatus, 8");
  }
  __asm__ volatile("csrs mstatus, 8");
}

/* One bus-master transfer; returns BM_STATUS's cause (0: none). */
static uint32_t bm(int d2h, uint32_t haddr_hi, uint32_t haddr_lo, uint32_t laddr, uint32_t bytes,
                   uint32_t *cycles)
{
  HOST_BM_HADDR_LO = haddr_lo;
  HOST_BM_HADDR_HI = haddr_hi;
  HOST_BM_LADDR = laddr;
  HOST_BM_LEN = bytes;
  n_irq = 0;
  HOST_BM_CTRL = HOST_BM_START | (d2h ? HOST_BM_D2H : 0u);
  wait_irq();
  *cycles = HOST_BM_CYCLES;
  return (bm_status & HOST_BM_ERR) ? HOST_BM_CAUSE(bm_status) : 0u;
}

/* The host model's contents of a byte nobody has written. */
static uint32_t pattern_word(uint32_t a)
{
  uint32_t w = 0;
  for (uint32_t k = 0; k < 4; k++) {
    uint32_t b = a + k;
    w |= (((b ^ (b >> 8) ^ (b >> 16)) & 0xFFu) ^ 0x3Cu) << (8 * k);
  }
  return w;
}

static void report(const char *what, uint32_t cause, uint32_t cycles)
{
  sys_puts(what);
  sys_putdec(cycles);
  sys_puts(" clocks");
  if (cause) {
    sys_puts(", cause ");
    sys_putdec(cause);
  }
  sys_putc('\n');
}

int main(void)
{
  int err = 0;
  uint32_t c, cyc, n = 0;
  volatile uint32_t *buf = (volatile uint32_t *)0x10008000u;
  volatile uint32_t *odd = (volatile uint32_t *)0x1000A008u;

  /* 1. Enumeration by the host */
  while ((HOST_LINK_STATUS & (HOST_BME | HOST_MSIX_EN)) != (HOST_BME | HOST_MSIX_EN)) {
    if (++n > 1000000u) {
      sys_puts("host: no enumeration\n");
      return 1;
    }
  }
  sys_puts("host: enumerated, ID ");
  sys_puthex(HOST_LINK_STATUS >> 16);
  sys_putc('\n');

  INTC_ENABLE = 1u << IRQ_HOST_BM;
  set_csr(mie, 1u << 11);
  set_csr(mstatus, 1u << 3);

  /* 2. Host to SoC */
  c = bm(0, 0x1u, 0x00000000u, 0x10008000u, 8192u, &cyc);
  report("host to SoC 8192 B: ", c, cyc);
  if (c) err |= 2;
  for (uint32_t i = 0; i < 2048u; i++) {
    if (buf[i] != pattern_word(4u * i)) {
      err |= 2;
      break;
    }
  }

  /* 3. SoC to host */
  for (uint32_t i = 0; i < 2048u; i++) buf[i] ^= 0xA5A5A5A5u;
  c = bm(1, 0x2u, 0x00000000u, 0x10008000u, 8192u, &cyc);
  report("SoC to host 8192 B: ", c, cyc);
  if (c) err |= 4;

  /* 4. Different DW lanes on the two sides */
  c = bm(0, 0x0u, 0x30000004u, 0x1000A008u, 1000u, &cyc);
  report("host to SoC 1000 B, lanes differ: ", c, cyc);
  if (c) err |= 8;
  for (uint32_t i = 0; i < 250u; i++) {
    if (odd[i] != pattern_word(0x30000004u + 4u * i)) {
      err |= 8;
      break;
    }
  }
  c = bm(1, 0x0u, 0x3000200Cu, 0x1000A008u, 1000u, &cyc);
  report("SoC to host 1000 B, lanes differ: ", c, cyc);
  if (c) err |= 8;

  /* 5. MSI-X */
  HOST_MSIX_REQ = 2u;

  if (HOST_ERR_STATUS != 0u) {
    sys_puts("host: ERR_STATUS ");
    sys_puthex(HOST_ERR_STATUS);
    sys_putc('\n');
    err |= 16;
  }
  sys_puts("host: TLPs received ");
  sys_putdec(HOST_RX_TLPS);
  sys_puts(", sent ");
  sys_putdec(HOST_TX_TLPS);
  sys_putc('\n');
  return err;
}
