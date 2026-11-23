/*
 * NVMe commands end to end from firmware (steps 2-2 and 2-3,
 * docs/11_nvme_queues.md, docs/12_nvme_data.md), against the NVMe host of
 * dv/tb/tb_soc.sv (+test=nvme). Firmware handles and completes every command:
 *   1. wait until the host has enumerated the device; take the NVMe
 *      interrupt (INTC source 3) for waiting commands and for the controller
 *      events ENABLE, SHUTDOWN, DB_ERR, FETCH_ERR and CQE_ERR
 *   2. the host enables the controller with an 8-entry admin queue pair
 *   3. admin Create I/O Completion Queue and Create I/O Submission Queue
 *      (queue pair 1, 16 entries, vector 1): checked, set up, and completed
 *      on the admin completion queue
 *   4. I/O commands on queue 1 against a namespace of 16 blocks of 512 bytes
 *      in SRAM (0x1000_8000): Write moves the host's data in by PRP and checks
 *      it against the host's pattern, Read moves blocks out, Flush; an
 *      unknown opcode gets Invalid Command Opcode and a block range past the
 *      end LBA Out of Range
 *   5. the host shuts the controller down: EVENT.SHUTDOWN ends the test
 * Prints the clocks of each data transfer (XF_CYCLES).
 */
#include "lib.h"
#include "soc.h"

#define NS_BASE   0x10008000u   /* namespace: 16 blocks of 512 bytes */
#define NS_BLOCKS 16u

#define ST_OK     0x0000u
#define ST_OPC    0x4001u       /* DNR, Invalid Command Opcode */
#define ST_FIELD  0x4002u       /* DNR, Invalid Field in Command */
#define ST_XFER   0x0004u       /* Data Transfer Error */
#define ST_PRP    0x4013u       /* DNR, PRP Offset Invalid */
#define ST_LBA    0x4080u       /* DNR, LBA Out of Range */

static volatile uint32_t events;
static volatile uint32_t wake;
static uint32_t n_admin, n_io, n_bad, first_bad, n_xfer_cycles, n_xfer_bytes;

static void bad(uint32_t what)
{
  if (n_bad++ == 0) first_bad = what;
}

uint32_t trap_handler(uint32_t *frame)
{
  (void)frame;
  uint32_t cause = read_csr(mcause);
  uint32_t epc = read_csr(mepc);

  if (cause == MCAUSE_EXT_IRQ && INTC_CLAIM == IRQ_NVME) {
    /* Commands are handled in main: mask the command interrupt until main
     * has emptied CMD. Events are taken here. */
    uint32_t ev = NVME_EVENT;
    NVME_EVENT = ev;
    events |= ev;
    NVME_CTRL = 0u;
    wake = 1u;
  } else {
    sys_puts("unexpected trap ");
    sys_puthex(cause);
    sys_putc('\n');
    sys_exit(0x100 | (int)(cause & 0xFFu));
  }
  return epc;
}

/* The host's pattern for byte b of the namespace. */
static uint32_t wpat(uint32_t b)
{
  return (b ^ (b >> 8) ^ 0xA5u) & 0xFFu;
}

/* One PRP transfer; returns XF_STATUS.CAUSE (0: done). */
static uint32_t xfer(int d2h, const volatile uint32_t *c, uint32_t laddr, uint32_t len)
{
  uint32_t st;
  NVME_XF_PRP1_LO = c[6];
  NVME_XF_PRP1_HI = c[7];
  NVME_XF_PRP2_LO = c[8];
  NVME_XF_PRP2_HI = c[9];
  NVME_XF_LADDR = laddr;
  NVME_XF_LEN = len;
  NVME_XF_CTRL = NVME_XF_START | (d2h ? NVME_XF_D2H : 0u);
  do {
    st = NVME_XF_STATUS;
  } while (!(st & (NVME_XF_DONE | NVME_XF_ERR)));
  NVME_XF_STATUS = NVME_XF_DONE | NVME_XF_ERR;
  n_xfer_cycles += NVME_XF_CYCLES;
  n_xfer_bytes += len;
  sys_puts(d2h ? "nvme: read " : "nvme: write ");
  sys_putdec(len);
  sys_puts(" B: ");
  sys_putdec(NVME_XF_CYCLES);
  sys_puts(" clocks\n");
  return NVME_XF_CAUSE(st);
}

static uint32_t xfer_status(uint32_t cause)
{
  if (cause == 0u) return ST_OK;
  if (cause == 8u) return ST_FIELD;
  if (cause == 9u) return ST_PRP;
  return ST_XFER;
}

static void post(uint32_t cq, uint32_t cid, uint32_t sq, uint32_t status)
{
  while (NVME_CQE_STATUS & NVME_CQE_FULL) {
  }
  NVME_CQE_DW0 = 0xC0DE0000u | cid;
  NVME_CQE_INFO = (sq << 16) | cid;
  NVME_CQE_CTRL = (status << 17) | cq;
}

/* Create I/O Completion Queue (0x05) and Create I/O Submission Queue (0x01). */
static uint32_t admin(const volatile uint32_t *c)
{
  uint32_t opc = c[0] & 0xFFu;
  uint32_t qid = c[10] & 0xFFFFu;
  uint32_t qsize = c[10] >> 16;

  n_admin++;
  if (opc != 0x05u && opc != 0x01u) return ST_OPC;
  if (qid < 1u || qid > 4u || qsize < 1u || qsize > 0xFFFu || !(c[11] & 1u) || (c[6] & 0xFFFu))
    return ST_FIELD;
  if (opc == 0x05u) {
    uint32_t iv = c[11] >> 16;
    if (iv > 7u) return ST_FIELD;
    NVME_IOQ(qid, CQB_LO) = c[6];
    NVME_IOQ(qid, CQB_HI) = c[7];
    NVME_IOQ(qid, CQ_CFG) = NVME_Q_EN | ((c[11] & 2u) ? NVME_CQ_IEN : 0u) | (iv << 16) | qsize;
  } else {
    uint32_t cqid = c[11] >> 16;
    if (cqid < 1u || cqid > 4u || !(NVME_IOQ(cqid, CQ_CFG) & NVME_Q_EN)) return ST_FIELD;
    NVME_IOQ(qid, SQB_LO) = c[6];
    NVME_IOQ(qid, SQB_HI) = c[7];
    NVME_IOQ(qid, SQ_CFG) = NVME_Q_EN | (cqid << 16) | qsize;
  }
  return ST_OK;
}

/* Read (0x02), Write (0x01), Flush (0x00) on the SRAM namespace. */
static uint32_t io(const volatile uint32_t *c)
{
  uint32_t opc = c[0] & 0xFFu;
  uint32_t slba = c[10];
  uint32_t nblk = (c[12] & 0xFFFFu) + 1u;
  uint32_t len = 512u * nblk;
  uint32_t st;

  n_io++;
  if (opc == 0x00u) return ST_OK;
  if (opc != 0x01u && opc != 0x02u) return ST_OPC;
  if (c[11] != 0u || slba >= NS_BLOCKS || nblk > NS_BLOCKS - slba) return ST_LBA;
  st = xfer_status(xfer(opc == 0x02u, c, NS_BASE + 512u * slba, len));
  if (opc == 0x01u && st == ST_OK) {
    const volatile uint8_t *d = (const volatile uint8_t *)(uintptr_t)(NS_BASE + 512u * slba);
    for (uint32_t i = 0; i < len; i++) {
      if (d[i] != wpat(512u * slba + i)) {
        bad(0x100u | (c[0] >> 16));
        break;
      }
    }
  }
  return st;
}

/* Take every waiting command: copy its entry, return its slot, handle it,
 * complete it on the completion queue of the same number. */
static void take_commands(void)
{
  uint32_t c;
  while ((c = NVME_CMD) & NVME_CMD_VALID) {
    const volatile uint32_t *e = (const volatile uint32_t *)(uintptr_t)(NVME_CMDBUF + 64u * NVME_CMD_SLOT(c));
    uint32_t sqe[16];
    uint32_t q = NVME_CMD_SQID(c);
    uint32_t st;
    for (int i = 0; i < 16; i++) sqe[i] = e[i];
    NVME_SLOT_FREE = NVME_CMD_SLOT(c);
    st = (q == 0u) ? admin(sqe) : io(sqe);
    post(q, sqe[0] >> 16, q, st);
  }
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
  NVME_EVENT_EN = NVME_EV_ENABLE | NVME_EV_SHUTDOWN | NVME_EV_DB_ERR | NVME_EV_FETCH_ERR | NVME_EV_CQE_ERR;
  NVME_CTRL = NVME_IEN_CMD;
  INTC_ENABLE = 1u << IRQ_NVME;
  set_csr(mie, 1u << 11);
  set_csr(mstatus, 1u << 3);

  /* 2-5. Sleep until the interrupt, take the commands, until the shutdown.
   * The flag is tested with interrupts masked, so one that arrives between
   * the test and WFI still wakes WFI. */
  for (;;) {
    for (;;) {
      __asm__ volatile("csrc mstatus, 8");
      if (wake) break;
      __asm__ volatile("wfi");
      __asm__ volatile("csrs mstatus, 8");
    }
    wake = 0u;
    __asm__ volatile("csrs mstatus, 8");
    take_commands();
    if (events & NVME_EV_SHUTDOWN) break;
    NVME_CTRL = NVME_IEN_CMD;
  }

  st = NVME_STATUS;
  sys_puts("nvme: shutdown; admin commands ");
  sys_putdec(n_admin);
  sys_puts(", I/O commands ");
  sys_putdec(n_io);
  sys_puts(", completions ");
  sys_putdec(NVME_CQES);
  sys_puts(", data ");
  sys_putdec(n_xfer_bytes);
  sys_puts(" B in ");
  sys_putdec(n_xfer_cycles);
  sys_puts(" clocks, bad ");
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
  if (n_io != 7u || n_bad != 0u) err |= 8;
  if (NVME_CQES != 9u || NVME_ST_CMDS(st) != 0u || NVME_ST_FREE(st) != 16u) err |= 16;
  if (events & (NVME_EV_DB_ERR | NVME_EV_FETCH_ERR | NVME_EV_CQE_ERR)) err |= 32;
  return err;
}
