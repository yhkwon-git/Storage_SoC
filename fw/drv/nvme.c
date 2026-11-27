/*
 * NVMe command handling in firmware (step 2-4, docs/13_nvme_firmware.md).
 *
 * The hardware fetches commands, moves data by PRP and writes completion
 * entries (steps 2-2, 2-3); this layer decides what each command does:
 *   admin  Identify (controller, namespace 1, active namespace list),
 *          Create and Delete I/O Submission and Completion Queue, Set and
 *          Get Features Number of Queues
 *   I/O    Read, Write, Flush on namespace 1: NS_BLOCKS blocks of 512 bytes
 *          in SRAM at NS_BASE; built with NS_NAND (ssd_app, step 3-4), on
 *          NAND through the flash translation layer (ftl.c), the data
 *          staged in SRAM at NS_BASE
 * Anything else is completed with the status the specification gives it
 * (Invalid Command Opcode, Invalid Field, Invalid Namespace, LBA Out of
 * Range, queue errors, PRP Offset Invalid, Data Transfer Error).
 *
 * nvme_service() sleeps until the NVMe interrupt (INTC source 3), then takes
 * every waiting command. The command interrupt is masked from the interrupt
 * to the end of the drain, so the level source does not re-enter.
 *
 * A controller reset (EVENT.RESET) is handled before any command taken after
 * it: the drain stops when the interrupt handler has seen one. The hardware
 * has already dropped the commands, freed the slots and deleted the I/O
 * queues; firmware counts the reset and returns the vendor-specific feature
 * to its default. By the time the handler runs, the host may already have
 * re-enabled the controller (the handler reads RESET and ENABLE together),
 * so the next command and even a shutdown can fall in the same pass of the
 * loop: the reset is taken before the shutdown is looked at.
 *
 * Overlap (vendor-specific feature 0xC0, DW11 bit 0, off at reset): with it
 * on, a Read or a Write does not wait for its transfer. Firmware takes the
 * next command and, if it needs a transfer too, loads the PRP engine's
 * registers for it while the first transfer runs (the engine takes them at
 * START), starts it the moment the first one ends, and only then posts the
 * first command's completion. Commands are still completed in the order
 * they were taken.
 *
 * Epochs (step 2-5): CMD gives the epoch a command was fetched in. Firmware
 * writes it back with everything it does for the command (SLOT_FREE, the
 * transfer start, the completion post, the I/O queue registers), and the
 * hardware ignores those of a command fetched before a controller reset. A
 * command that changes state (queue creation and deletion, Set Features)
 * first compares its epoch with STATUS.EPOCH, with interrupts masked, so a
 * stale one touches nothing: the few register accesses between that check
 * and the writes are far fewer than a host needs to reset the controller,
 * enable it again and send another admin command.
 *
 * Accounting: firmware clocks are the clocks spent in drain() minus the
 * clocks spent spinning on a transfer; transfer clocks are the sum of
 * XF_CYCLES.
 */
#include "drv.h"
#include "lib.h"

#define NS_BASE   (SRAM_BASE + 0x8000u)
#ifdef NS_NAND
/* 32 logical pages of 8 blocks. A command moves at most 8 KiB (MDTS 1), so
 * its logical pages fit in the 12 KiB staging area at NS_BASE. */
#define NS_BLOCKS (8u * FTL_LPNS)
#define NS_MDTS   1u
#else
#define NS_BLOCKS 24u
#define NS_MDTS   5u
#endif

/* Status field (DW3 bits 31:17): DNR 14, SCT 10:8, SC 7:0 */
#define ST(sct, sc, dnr) ((uint32_t)(((dnr) << 14) | ((sct) << 8) | (sc)))
#define ST_OK        0u
#define ST_OPC       ST(0, 0x01, 1)
#define ST_FIELD     ST(0, 0x02, 1)
#define ST_XFER      ST(0, 0x04, 0)
#define ST_NS        ST(0, 0x0B, 1)
#define ST_PRP       ST(0, 0x13, 1)
#define ST_LBA       ST(0, 0x80, 1)
#define ST_CQ_INVAL  ST(1, 0x00, 1)
#define ST_QID       ST(1, 0x01, 1)
#define ST_QSIZE     ST(1, 0x02, 1)
#define ST_IV        ST(1, 0x08, 1)
#define ST_QDEL      ST(1, 0x0C, 1)
#define ST_WFAULT    ST(2, 0x80, 0)       /* Write Fault */
#define ST_UNREC     ST(2, 0x81, 0)       /* Unrecovered Read Error */
/* Not a status: the command came before a controller reset (its epoch is
 * not the controller's). Nothing is posted for it. */
#define ST_STALE     0x80000000u

nvme_stats_t nvme_stats;

static volatile uint32_t events;
static volatile uint32_t wake;
static uint32_t overlap;
static uint32_t sq_cq[5];               /* each submission queue's completion queue; 0 for admin */
static uint8_t id_buf[4096] __attribute__((aligned(8)));

static void nvme_isr(uint32_t id)
{
  (void)id;
  uint32_t ev = NVME_EVENT;
  NVME_EVENT = ev;
  events |= ev;
  NVME_CTRL = 0u;
  wake = 1u;
}

void nvme_init(void)
{
  for (uint32_t i = 0; i < sizeof(nvme_stats) / 4u; i++) ((uint32_t *)&nvme_stats)[i] = 0u;
  events = 0u;
  wake = 0u;
  NVME_EVENT_EN = NVME_EV_ENABLE | NVME_EV_RESET | NVME_EV_SHUTDOWN | NVME_EV_DB_ERR | NVME_EV_FETCH_ERR |
                  NVME_EV_CQE_ERR;
  NVME_CTRL = NVME_IEN_CMD;
  irq_register(IRQ_NVME, nvme_isr);
}

uint32_t nvme_events(void)
{
  return events;
}

/* The PRP engine: registers for a transfer, its start, the wait for its
 * end (counted as spin time). */
static void xf_load(const uint32_t *c, uint32_t laddr, uint32_t len)
{
  NVME_XF_PRP1_LO = c[6];
  NVME_XF_PRP1_HI = c[7];
  NVME_XF_PRP2_LO = c[8];
  NVME_XF_PRP2_HI = c[9];
  NVME_XF_LADDR = laddr;
  NVME_XF_LEN = len;
}

static void xf_start(int d2h, uint32_t len, uint32_t ep)
{
  NVME_XF_CTRL = NVME_XF_START | (d2h ? NVME_XF_D2H : 0u) | NVME_XF_EPOCH(ep);
  nvme_stats.bytes += len;
}

static uint32_t xf_wait(void)
{
  uint32_t st;
  uint32_t t0 = timer_cycles();
  do {
    st = NVME_XF_STATUS;
  } while (!(st & (NVME_XF_DONE | NVME_XF_ERR)));
  nvme_stats.spin_clocks += timer_cycles() - t0;
  NVME_XF_STATUS = NVME_XF_DONE | NVME_XF_ERR;
  nvme_stats.xfer_clocks += NVME_XF_CYCLES;
  return NVME_XF_CAUSE(st);
}

/* One PRP transfer from the command's PRP1 and PRP2; returns the cause. */
static uint32_t xfer(int d2h, const uint32_t *c, uint32_t laddr, uint32_t len, uint32_t ep)
{
  xf_load(c, laddr, len);
  xf_start(d2h, len, ep);
  return xf_wait();
}

static uint32_t xfer_status(uint32_t cause)
{
  if (cause == 0u) return ST_OK;
  if (cause == NVME_XF_STALE) return ST_STALE;
  if (cause == 8u) return ST_FIELD;
  if (cause == 9u) return ST_PRP;
  return ST_XFER;
}

static void put16(uint32_t at, uint32_t v)
{
  id_buf[at] = (uint8_t)v;
  id_buf[at + 1u] = (uint8_t)(v >> 8);
}

static void put32(uint32_t at, uint32_t v)
{
  put16(at, v);
  put16(at + 2u, v >> 16);
}

static void put_str(uint32_t at, uint32_t len, const char *s)
{
  for (uint32_t i = 0; i < len; i++) id_buf[at + i] = (*s != '\0') ? (uint8_t)*s++ : (uint8_t)' ';
}

/* Identify: CNS 1 controller, 0 namespace 1, 2 active namespace list. */
static uint32_t identify(const uint32_t *c, uint32_t *dw0, uint32_t ep)
{
  uint32_t cns = c[10] & 0xFFu;
  uint32_t *w = (uint32_t *)id_buf;
  (void)dw0;
  for (uint32_t i = 0; i < 1024u; i++) w[i] = 0u;
  if (cns == 0x01u) {
    put16(0, 0x0000u);                  /* VID: placeholder, not an assigned ID */
    put16(2, 0x0000u);                  /* SSVID */
    put_str(4, 20, "SSOC0001");         /* SN */
    put_str(24, 40, "Storage_SoC NVMe front-end");
    put_str(64, 8, "2.4");              /* FR */
    id_buf[72] = 0u;                    /* RAB */
    id_buf[77] = NS_MDTS;               /* MDTS: 2^MDTS x 4 KiB (128 KiB, or 8 KiB on NAND) */
    put16(78, 1u);                      /* CNTLID */
    put32(80, 0x00010400u);             /* VER 1.4.0 */
    id_buf[512] = 0x66u;                /* SQES: 64 bytes */
    id_buf[513] = 0x44u;                /* CQES: 16 bytes */
    put32(516, 1u);                     /* NN */
    id_buf[525] = 0u;                   /* VWC: no volatile write cache */
  } else if (cns == 0x00u) {
    if (c[1] != 1u) return ST_NS;
    put32(0, NS_BLOCKS);                /* NSZE */
    put32(8, NS_BLOCKS);                /* NCAP */
    put32(16, NS_BLOCKS);               /* NUSE */
    id_buf[25] = 0u;                    /* NLBAF: one format */
    id_buf[26] = 0u;                    /* FLBAS: format 0 */
    put32(128, 9u << 16);               /* LBAF0: 2^9-byte blocks */
  } else if (cns == 0x02u) {
    put32(0, 1u);                       /* namespace 1 only */
  } else {
    return ST_FIELD;
  }
  return xfer_status(xfer(1, c, (uint32_t)(uintptr_t)id_buf, 4096u, ep));
}

/* A queue the hardware has enabled in epoch ep. */
static int q_live(uint32_t cfg, uint32_t ep)
{
  return (cfg & NVME_Q_EN) && NVME_Q_EPOCH_OF(cfg) == ep;
}

static int cq_used(uint32_t cq, uint32_t ep)
{
  for (uint32_t q = 1; q <= 4u; q++) {
    uint32_t cfg = NVME_IOQ(q, SQ_CFG);
    if (q_live(cfg, ep) && ((cfg >> 16) & 7u) == cq) return 1;
  }
  return 0;
}

static uint32_t queue_cmd(const uint32_t *c, uint32_t ep)
{
  uint32_t opc = c[0] & 0xFFu;
  uint32_t qid = c[10] & 0xFFFFu;
  uint32_t qsize = c[10] >> 16;

  switch (opc) {
  case 0x05u:                           /* Create I/O Completion Queue */
    if (qid < 1u || qid > 4u || q_live(NVME_IOQ(qid, CQ_CFG), ep)) return ST_QID;
    if (qsize < 1u || qsize > 0xFFFu) return ST_QSIZE;
    if (!(c[11] & 1u) || (c[6] & 0xFFFu)) return ST_FIELD;
    if ((c[11] >> 16) > 7u) return ST_IV;
    NVME_IOQ(qid, CQB_LO) = c[6];
    NVME_IOQ(qid, CQB_HI) = c[7];
    NVME_IOQ(qid, CQ_CFG) = NVME_Q_EN | NVME_Q_EPOCH(ep) | ((c[11] & 2u) ? NVME_CQ_IEN : 0u) |
                            ((c[11] >> 16) << 16) | qsize;
    return ST_OK;
  case 0x01u: {                         /* Create I/O Submission Queue */
    uint32_t cqid = c[11] >> 16;
    if (qid < 1u || qid > 4u || q_live(NVME_IOQ(qid, SQ_CFG), ep)) return ST_QID;
    if (qsize < 1u || qsize > 0xFFFu) return ST_QSIZE;
    if (!(c[11] & 1u) || (c[6] & 0xFFFu)) return ST_FIELD;
    if (cqid < 1u || cqid > 4u || !q_live(NVME_IOQ(cqid, CQ_CFG), ep)) return ST_CQ_INVAL;
    NVME_IOQ(qid, SQB_LO) = c[6];
    NVME_IOQ(qid, SQB_HI) = c[7];
    sq_cq[qid] = cqid;
    NVME_IOQ(qid, SQ_CFG) = NVME_Q_EN | NVME_Q_EPOCH(ep) | (cqid << 16) | qsize;
    return ST_OK;
  }
  case 0x00u:                           /* Delete I/O Submission Queue */
    if (qid < 1u || qid > 4u || !q_live(NVME_IOQ(qid, SQ_CFG), ep)) return ST_QID;
    NVME_IOQ(qid, SQ_CFG) = NVME_IOQ(qid, SQ_CFG) & ~NVME_Q_EN;
    return ST_OK;
  default:                              /* 0x04: Delete I/O Completion Queue */
    if (qid < 1u || qid > 4u || !q_live(NVME_IOQ(qid, CQ_CFG), ep)) return ST_QID;
    if (cq_used(qid, ep)) return ST_QDEL;
    NVME_IOQ(qid, CQ_CFG) = NVME_IOQ(qid, CQ_CFG) & ~NVME_Q_EN;
    return ST_OK;
  }
}

static uint32_t admin(const uint32_t *c, uint32_t *dw0, uint32_t ep)
{
  uint32_t opc = c[0] & 0xFFu;
  uint32_t st;

  nvme_stats.admin++;
  switch (opc) {
  case 0x06u:
    return identify(c, dw0, ep);
  case 0x05u:
  case 0x01u:
  case 0x00u:
  case 0x04u:
    /* Check the epoch and write the queue registers with interrupts masked. */
    clear_csr(mstatus, 1u << 3);
    st = (ep == NVME_ST_EPOCH(NVME_STATUS)) ? queue_cmd(c, ep) : ST_STALE;
    set_csr(mstatus, 1u << 3);
    return st;
  case 0x09u:                           /* Set Features */
  case 0x0Au:                           /* Get Features */
    if ((c[10] & 0xFFu) == 0x07u) {
      *dw0 = (3u << 16) | 3u;           /* 4 I/O completion and 4 submission queues */
      return ST_OK;
    }
    if ((c[10] & 0xFFu) == 0xC0u) {     /* vendor specific: transfer overlap */
      if (opc == 0x09u) {
        if (ep != NVME_ST_EPOCH(NVME_STATUS)) return ST_STALE;
        overlap = c[11] & 1u;
      }
      *dw0 = overlap;
      return ST_OK;
    }
    return ST_FIELD;
  default:
    return ST_OPC;
  }
}

/* An I/O command's checks. Returns its status; for a Read or a Write that
 * passes, *len is its byte count (0 otherwise). */
static uint32_t io_check(const uint32_t *c, uint32_t *laddr, uint32_t *len)
{
  uint32_t opc = c[0] & 0xFFu;
  uint32_t slba = c[10];
  uint32_t nblk = (c[12] & 0xFFFFu) + 1u;

  *len = 0u;
  if (opc == 0x00u) {
    nvme_stats.flushes++;
    return (c[1] == 1u) ? ST_OK : ST_NS;
  }
  if (opc != 0x01u && opc != 0x02u) return ST_OPC;
  if (c[1] != 1u) return ST_NS;
  if (c[11] != 0u || slba >= NS_BLOCKS || nblk > NS_BLOCKS - slba) return ST_LBA;
  if (opc == 0x02u) nvme_stats.reads++;
  else              nvme_stats.writes++;
  *laddr = NS_BASE + 512u * slba;
  *len = 512u * nblk;
  return ST_OK;
}

#ifdef NS_NAND
/* A Read or a Write on NAND (step 3-4): the command's logical pages through
 * the staging area. A Read fetches them, then moves the blocks asked for to
 * the host. A Write first fetches the pages it covers only in part, so that
 * their other blocks are kept, then takes the host's data over them and
 * writes every page. */
static uint32_t nand_io(const uint32_t *c, uint32_t len, uint32_t ep)
{
  uint32_t slba = c[10], nblk = len / 512u;
  uint32_t lpn0 = slba / 8u, lpn1 = (slba + nblk - 1u) / 8u;
  uint32_t off = 512u * (slba % 8u), st;
  if (len > (4096u << NS_MDTS)) return ST_FIELD;   /* more than MDTS */
  if ((c[0] & 0xFFu) == 0x02u) {
    for (uint32_t l = lpn0; l <= lpn1; l++)
      if (ftl_read(l, NS_BASE + 4096u * (l - lpn0)) != 0) return ST_UNREC;
    return xfer_status(xfer(1, c, NS_BASE + off, len, ep));
  }
  if (slba % 8u != 0u && ftl_read(lpn0, NS_BASE) != 0) return ST_UNREC;
  if ((slba + nblk) % 8u != 0u && (lpn1 != lpn0 || slba % 8u == 0u) &&
      ftl_read(lpn1, NS_BASE + 4096u * (lpn1 - lpn0)) != 0) return ST_UNREC;
  st = xfer_status(xfer(0, c, NS_BASE + off, len, ep));
  if (st != ST_OK) return st;
  for (uint32_t l = lpn0; l <= lpn1; l++)
    if (ftl_write(l, NS_BASE + 4096u * (l - lpn0)) != 0) return ST_WFAULT;
  return ST_OK;
}
#endif

/* Post the completion of a command from submission queue sq to that queue's
 * completion queue, or count the command if it was found stale. */
static void post(uint32_t sq, uint32_t cid, uint32_t status, uint32_t dw0, uint32_t ep)
{
  if (status == ST_STALE) {
    nvme_stats.stale++;
    return;
  }
  if (status != ST_OK) nvme_stats.errors++;
  while (NVME_CQE_STATUS & NVME_CQE_FULL) {
  }
  NVME_CQE_DW0 = dw0;
  NVME_CQE_INFO = (sq << 16) | cid;
  NVME_CQE_CTRL = (status << 17) | NVME_CQE_EPOCH(ep) | sq_cq[sq];
}

/* A command whose transfer is running (overlap mode). */
static struct {
  uint32_t on, q, cid, ep;
} pend;

static void pend_finish(void)
{
  if (!pend.on) return;
  post(pend.q, pend.cid, xfer_status(xf_wait()), 0u, pend.ep);
  pend.on = 0u;
}

/* Take every waiting command; stop early at a controller reset. */
static void drain(void)
{
  uint32_t c;
  uint32_t t0 = timer_cycles();
  uint32_t s0 = nvme_stats.spin_clocks;
  while (!(events & NVME_EV_RESET) && ((c = NVME_CMD) & NVME_CMD_VALID)) {
    const volatile uint32_t *e = (const volatile uint32_t *)(uintptr_t)(NVME_CMDBUF + 64u * NVME_CMD_SLOT(c));
    uint32_t sqe[16];
    uint32_t q = NVME_CMD_SQID(c);
    uint32_t ep = NVME_CMD_EPOCH(c);
    uint32_t st, dw0 = 0u, laddr = 0u, len = 0u;
    for (int i = 0; i < 16; i++) sqe[i] = e[i];
    NVME_SLOT_FREE = NVME_CMD_SLOT(c) | NVME_FREE_EPOCH(ep);
    nvme_stats.cmds++;
    if (q == 0u) {
      pend_finish();
      st = admin(sqe, &dw0, ep);
    } else {
      st = io_check(sqe, &laddr, &len);
#ifdef NS_NAND
      (void)laddr;
      if (st == ST_OK && len != 0u) st = nand_io(sqe, len, ep);
      post(q, sqe[0] >> 16, st, dw0, ep);
      continue;
#endif
      if (st == ST_OK && len != 0u) {
        int d2h = ((sqe[0] & 0xFFu) == 0x02u);
        if (overlap) {
          /* Load the engine for this command while the previous one runs,
           * start it as soon as that one ends, then complete that one. */
          xf_load(sqe, laddr, len);
          if (pend.on) {
            uint32_t pst = xfer_status(xf_wait());
            xf_start(d2h, len, ep);
            post(pend.q, pend.cid, pst, 0u, pend.ep);
          } else {
            xf_start(d2h, len, ep);
          }
          pend.on = 1u;
          pend.q = q;
          pend.cid = sqe[0] >> 16;
          pend.ep = ep;
          continue;
        }
        st = xfer_status(xfer(d2h, sqe, laddr, len, ep));
      } else {
        pend_finish();
      }
    }
    post(q, sqe[0] >> 16, st, dw0, ep);
  }
  pend_finish();
  nvme_stats.fw_clocks += (timer_cycles() - t0) - (nvme_stats.spin_clocks - s0);
}

/* Test and clear an event the handler has recorded, with interrupts masked
 * (the handler ORs into events). */
static uint32_t take_event(uint32_t bit)
{
  clear_csr(mstatus, 1u << 3);
  uint32_t e = events & bit;
  events &= ~bit;
  set_csr(mstatus, 1u << 3);
  return e;
}

int nvme_service(void)
{
  irq_wait(&wake);
  wake = 0u;
  for (;;) {
    if (take_event(NVME_EV_RESET)) {
      /* The hardware dropped the commands, freed the slots and deleted the
       * I/O queues; features go back to their defaults. */
      overlap = 0u;
      nvme_stats.resets++;
    }
    drain();
    if (!(events & NVME_EV_RESET)) break;
  }
  if (events & NVME_EV_SHUTDOWN) return 1;
  NVME_CTRL = NVME_IEN_CMD;
  return 0;
}
