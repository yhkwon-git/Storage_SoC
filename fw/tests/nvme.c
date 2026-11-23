/*
 * NVMe command reception from firmware (step 2-2, docs/11_nvme_queues.md),
 * against the NVMe host of dv/tb/tb_soc.sv (+test=nvme):
 *   1. wait until the host has enumerated the device; take the NVMe
 *      interrupt (INTC source 3) for waiting commands and for the controller
 *      events ENABLE, SHUTDOWN, DB_ERR and FETCH_ERR
 *   2. the host enables the controller with an 8-entry admin queue pair:
 *      EVENT.ENABLE, and the mirrors of AQA, ASQ and ACQ hold its values
 *   3. admin commands Create I/O Completion Queue and Create I/O Submission
 *      Queue (queue 1, 16 entries): firmware checks them and sets up I/O
 *      queue pair 1 in nvme_regs from them
 *   4. 12 Read commands on queue 1, rung in two batches: each one checked
 *      (opcode, CID in submission order, NSID, PRP1, starting LBA, block
 *      count) and its slot returned
 *   5. the host shuts the controller down: EVENT.SHUTDOWN ends the test, with
 *      every command taken, all 16 slots free and 14 fetches counted
 * Commands are taken in the interrupt handler, which pops CMD until it reads
 * no command, so the level interrupt drops before the handler returns.
 */
#include "lib.h"
#include "soc.h"

#define N_IO 12u

static volatile uint32_t events;      /* EVENT bits seen */
static volatile uint32_t n_admin, n_io, n_bad;
static volatile uint32_t first_bad;   /* what the first bad command was */

/* Command buffer slot s: 16 DWs in SRAM. */
static volatile uint32_t *sqe(uint32_t s)
{
  return (volatile uint32_t *)(uintptr_t)(NVME_CMDBUF + 64u * s);
}

static void bad(uint32_t what)
{
  if (n_bad++ == 0) first_bad = what;
}

/* Create I/O Completion Queue (0x05) and Create I/O Submission Queue (0x01):
 * CDW10 QSIZE[31:16] (0-based), QID[15:0]; physically contiguous queues
 * only (CDW11 bit 0). For a CQ, CDW11 IV[31:16] and IEN[1]; for an SQ,
 * CQID[31:16], which must be a CQ already created. */
static void admin(volatile uint32_t *c)
{
  uint32_t opc = c[0] & 0xFFu;
  uint32_t qid = c[10] & 0xFFFFu;
  uint32_t qsize = c[10] >> 16;
  uint32_t prp1_lo = c[6], prp1_hi = c[7];

  n_admin++;
  if (qid < 1u || qid > 4u || qsize < 1u || qsize > 0xFFFu || !(c[11] & 1u) || (prp1_lo & 0xFFFu)) {
    bad(0x100u | opc);
    return;
  }
  if (opc == 0x05u) {
    uint32_t iv = c[11] >> 16;
    if (iv > 7u) {
      bad(0x200u | opc);
      return;
    }
    NVME_IOQ(qid, CQB_LO) = prp1_lo;
    NVME_IOQ(qid, CQB_HI) = prp1_hi;
    NVME_IOQ(qid, CQ_CFG) = NVME_Q_EN | ((c[11] & 2u) ? NVME_CQ_IEN : 0u) | (iv << 16) | qsize;
  } else if (opc == 0x01u) {
    uint32_t cqid = c[11] >> 16;
    if (cqid < 1u || cqid > 4u || !(NVME_IOQ(cqid, CQ_CFG) & NVME_Q_EN)) {
      bad(0x300u | opc);
      return;
    }
    NVME_IOQ(qid, SQB_LO) = prp1_lo;
    NVME_IOQ(qid, SQB_HI) = prp1_hi;
    NVME_IOQ(qid, SQ_CFG) = NVME_Q_EN | (cqid << 16) | qsize;
  } else {
    bad(0x400u | opc);
  }
}

/* Read (0x02) number i: CID 0x100 + i, NSID 1, PRP1 0x1_5000_0000 + 4 KiB x
 * i, SLBA 8 x i, NLB 7 (8 blocks). */
static void io(volatile uint32_t *c)
{
  uint32_t i = n_io++;
  if (c[0] != (((0x100u + i) << 16) | 0x02u) || c[1] != 1u || c[6] != 0x50000000u + 4096u * i ||
      c[7] != 1u || c[10] != 8u * i || c[11] != 0u || (c[12] & 0xFFFFu) != 7u)
    bad(0x500u | i);
}

uint32_t trap_handler(uint32_t *frame)
{
  (void)frame;
  uint32_t cause = read_csr(mcause);
  uint32_t epc = read_csr(mepc);

  if (cause == MCAUSE_EXT_IRQ && INTC_CLAIM == IRQ_NVME) {
    uint32_t ev = NVME_EVENT;
    uint32_t c;
    NVME_EVENT = ev;
    events |= ev;
    while ((c = NVME_CMD) & NVME_CMD_VALID) {
      uint32_t s = NVME_CMD_SLOT(c);
      if (NVME_CMD_SQID(c) == 0u)
        admin(sqe(s));
      else if (NVME_CMD_SQID(c) == 1u)
        io(sqe(s));
      else
        bad(0x600u | NVME_CMD_SQID(c));
      NVME_SLOT_FREE = s;
    }
  } else {
    sys_puts("unexpected trap ");
    sys_puthex(cause);
    sys_putc('\n');
    sys_exit(0x100 | (int)(cause & 0xFFu));
  }
  return epc;
}

/* Sleep until an event bit is set; the flag is tested with interrupts
 * masked, so one that arrives between the test and WFI still wakes WFI. */
static void wait_event(uint32_t bit)
{
  for (;;) {
    __asm__ volatile("csrc mstatus, 8");
    if (events & bit) break;
    __asm__ volatile("wfi");
    __asm__ volatile("csrs mstatus, 8");
  }
  __asm__ volatile("csrs mstatus, 8");
}

int main(void)
{
  int err = 0;
  uint32_t n = 0, st;

  /* 1. Enumeration, interrupts */
  while ((HOST_LINK_STATUS & HOST_BME) == 0u) {
    if (++n > 1000000u) {
      sys_puts("nvme: no enumeration\n");
      return 1;
    }
  }
  /* EVENT bits are sticky: an ENABLE that came before this point still
   * interrupts. */
  NVME_EVENT_EN = NVME_EV_ENABLE | NVME_EV_SHUTDOWN | NVME_EV_DB_ERR | NVME_EV_FETCH_ERR;
  NVME_CTRL = NVME_IEN_CMD;
  INTC_ENABLE = 1u << IRQ_NVME;
  set_csr(mie, 1u << 11);
  set_csr(mstatus, 1u << 3);

  /* 2. Controller enabled by the host */
  wait_event(NVME_EV_ENABLE);
  sys_puts("nvme: enabled, AQA ");
  sys_puthex(NVME_AQA);
  sys_puts(" ASQ ");
  sys_puthex(NVME_ASQ_HI);
  sys_putc(' ');
  sys_puthex(NVME_ASQ_LO);
  sys_puts(" ACQ ");
  sys_puthex(NVME_ACQ_HI);
  sys_putc(' ');
  sys_puthex(NVME_ACQ_LO);
  sys_putc('\n');
  if (NVME_AQA != 0x00070007u || NVME_ASQ_HI != 1u || NVME_ASQ_LO != 0x40000000u ||
      NVME_ACQ_HI != 1u || NVME_ACQ_LO != 0x40010000u)
    err |= 2;

  /* 3-5. Commands come in through the interrupt until the shutdown. */
  wait_event(NVME_EV_SHUTDOWN);
  st = NVME_STATUS;
  sys_puts("nvme: shutdown; admin commands ");
  sys_putdec(n_admin);
  sys_puts(", I/O commands ");
  sys_putdec(n_io);
  sys_puts(", fetches ");
  sys_putdec(NVME_FETCHES);
  sys_puts(", bad ");
  sys_putdec(n_bad);
  if (n_bad) {
    sys_puts(" (first ");
    sys_puthex(first_bad);
    sys_putc(')');
  }
  sys_puts(", STATUS ");
  sys_puthex(st);
  sys_putc('\n');
  if (n_admin != 2u || (NVME_IOQ(1, SQ_CFG) & NVME_Q_EN) == 0u || (NVME_IOQ(1, CQ_CFG) & NVME_Q_EN) == 0u)
    err |= 4;
  if (n_io != N_IO || n_bad != 0u) err |= 8;
  if (NVME_FETCHES != 2u + N_IO || NVME_ST_CMDS(st) != 0u || NVME_ST_FREE(st) != 16u ||
      (NVME_SQ_PTR(1) & 0xFFFu) != N_IO)
    err |= 16;
  if (events & (NVME_EV_DB_ERR | NVME_EV_FETCH_ERR)) err |= 32;
  return err;
}
