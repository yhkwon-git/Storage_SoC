/*
 * Storage_SoC address map and registers (docs/01_soc_architecture.md,
 * sections 6-7). Register offsets come from the generated soc_regs.h
 * (rtl/csr/rdl/soc_apb.rdl). Its structs are packed, and GCC may access a
 * member of a packed struct byte by byte; registers such as EXIT act on
 * every write. So the offsets are taken from the structs with offsetof, and
 * every access goes through REG32, which is always one 32-bit access.
 */
#ifndef SOC_H
#define SOC_H

#include <stddef.h>
#include <stdint.h>
#include "soc_regs.h"

#define REG32(a) (*(volatile uint32_t *)(uintptr_t)(a))

#define ROM_BASE    0x00000000u
#define SRAM_BASE   0x10000000u
#define NAND0_BASE  0x30000000u
#define NAND1_BASE  0x30010000u
#define APB_BASE    0x40000000u

#define APB_REG(field) REG32(APB_BASE + offsetof(soc_apb_t, field))

#define SYS_BASE    (APB_BASE + (uint32_t)offsetof(soc_apb_t, SYS))
#define INTC_BASE   (APB_BASE + (uint32_t)offsetof(soc_apb_t, INTC))
#define TIMER_BASE  (APB_BASE + (uint32_t)offsetof(soc_apb_t, TIMER))
#define PMU_BASE    (APB_BASE + (uint32_t)offsetof(soc_apb_t, PMU))
#define HOST_BASE   (APB_BASE + (uint32_t)offsetof(soc_apb_t, HOST))
#define EMPTY_SLOT_BASE (APB_BASE + 0x6000u) /* NAND0 registers, phase 3 */

#define SYS_ID           APB_REG(SYS.ID)
#define SYS_VERSION      APB_REG(SYS.VERSION)
#define SYS_SCRATCH      APB_REG(SYS.SCRATCH)
#define SYS_CONSOLE      APB_REG(SYS.CONSOLE)
#define SYS_EXIT         APB_REG(SYS.EXIT)
#define SYS_SOFT_RESET   APB_REG(SYS.SOFT_RESET)
#define SYS_CLK_GATE     APB_REG(SYS.CLK_GATE)
#define SYS_SLEEP_CYCLES APB_REG(SYS.SLEEP_CYCLES)

/* PMU (PD_AON, behind a clock-domain crossing: each access takes a few
 * microseconds). */
#define PMU_PWR_CTRL     APB_REG(PMU.PWR_CTRL)
#define PMU_PWR_STATUS   APB_REG(PMU.PWR_STATUS)
#define PMU_PWR_IRQ      APB_REG(PMU.PWR_IRQ)
#define PMU_TIMEOUT      APB_REG(PMU.TIMEOUT)
#define PMU_CHIP_RESET   APB_REG(PMU.CHIP_RESET)
#define PMU_RST_CAUSE    APB_REG(PMU.RST_CAUSE)
#define PMU_AON_SCRATCH  APB_REG(PMU.AON_SCRATCH)
#define PMU_PWR_CYCLES   APB_REG(PMU.PWR_CYCLES)

#define PMU_UP          PMU_REGS__PWR_CTRL__UP_bm
#define PMU_DOWN        PMU_REGS__PWR_CTRL__DOWN_bm
#define PMU_WAKE_EN     PMU_REGS__PWR_CTRL__WAKE_EN_bm
#define PMU_STATE(s)    ((s) & PMU_REGS__PWR_STATUS__STATE_bm)
#define PMU_RESULT(s)   (((s) & PMU_REGS__PWR_STATUS__RESULT_bm) >> PMU_REGS__PWR_STATUS__RESULT_bp)
#define PMU_STATE_OFF   0u
#define PMU_STATE_ON    5u
#define PMU_IRQ_DONE    PMU_REGS__PWR_IRQ__DONE_bm
#define PMU_IRQ_ERR     PMU_REGS__PWR_IRQ__ERR_bm
#define PMU_CHIP_KEY    0x5AFE0001u

/* HOST: the PD_HOST placeholder (docs/07_clock_reset_power.md). */
#define HOST_TX          APB_REG(HOST.TX)
#define HOST_RX          APB_REG(HOST.RX)
#define HOST_STATUS      APB_REG(HOST.STATUS)
#define HOST_RX_VALID    HOST_REGS__STATUS__RX_VALID_bm
#define HOST_ON          HOST_REGS__STATUS__ON_bm
#define HOST_IDLE        HOST_REGS__STATUS__IDLE_bm
#define HOST_TX_DROP     HOST_REGS__STATUS__TX_DROP_bm

/* HOST: the transaction layer (docs/10_transaction_layer.md). */
#define HOST_LINK_CTRL    APB_REG(HOST.LINK_CTRL)
#define HOST_LINK_STATUS  APB_REG(HOST.LINK_STATUS)
#define HOST_BAR2_WIN     APB_REG(HOST.BAR2_WIN)
#define HOST_BM_HADDR_LO  APB_REG(HOST.BM_HADDR_LO)
#define HOST_BM_HADDR_HI  APB_REG(HOST.BM_HADDR_HI)
#define HOST_BM_LADDR     APB_REG(HOST.BM_LADDR)
#define HOST_BM_LEN       APB_REG(HOST.BM_LEN)
#define HOST_BM_CTRL      APB_REG(HOST.BM_CTRL)
#define HOST_BM_STATUS    APB_REG(HOST.BM_STATUS)
#define HOST_BM_CYCLES    APB_REG(HOST.BM_CYCLES)
#define HOST_MSIX_REQ     APB_REG(HOST.MSIX_REQ)
#define HOST_MSIX_PEND    APB_REG(HOST.MSIX_PEND)
#define HOST_CPL_TIMEOUT  APB_REG(HOST.CPL_TIMEOUT)
#define HOST_ERR_STATUS   APB_REG(HOST.ERR_STATUS)
#define HOST_RX_TLPS      APB_REG(HOST.RX_TLPS)
#define HOST_TX_TLPS      APB_REG(HOST.TX_TLPS)

#define HOST_HOLD         HOST_REGS__LINK_CTRL__HOLD_bm
#define HOST_HOLD_ACK     HOST_REGS__LINK_STATUS__HOLD_ACK_bm
#define HOST_LINK_IDLE    HOST_REGS__LINK_STATUS__IDLE_bm
#define HOST_BME          HOST_REGS__LINK_STATUS__BME_bm
#define HOST_MSIX_EN      HOST_REGS__LINK_STATUS__MSIX_EN_bm
#define HOST_BM_START     HOST_REGS__BM_CTRL__START_bm
#define HOST_BM_D2H       HOST_REGS__BM_CTRL__D2H_bm
#define HOST_BM_BUSY      HOST_REGS__BM_STATUS__BUSY_bm
#define HOST_BM_DONE      HOST_REGS__BM_STATUS__DONE_bm
#define HOST_BM_ERR       HOST_REGS__BM_STATUS__ERR_bm
#define HOST_BM_CAUSE(s)  (((s) & HOST_REGS__BM_STATUS__CAUSE_bm) >> HOST_REGS__BM_STATUS__CAUSE_bp)

/* NVME: the controller's registers and queues, firmware side
 * (docs/11_nvme_queues.md). I/O queue pairs are q = 1..4; SQ_PTR and CQ_PTR
 * take q = 0..4 (0 is the admin queue pair). */
#define NVME_BASE       (APB_BASE + (uint32_t)offsetof(soc_apb_t, NVME))
#define NVME_CTRL       APB_REG(NVME.CTRL)
#define NVME_STATUS     APB_REG(NVME.STATUS)
#define NVME_EVENT      APB_REG(NVME.EVENT)
#define NVME_EVENT_EN   APB_REG(NVME.EVENT_EN)
#define NVME_CC         APB_REG(NVME.CC)
#define NVME_CMDBUF     APB_REG(NVME.CMDBUF)
#define NVME_CMD        APB_REG(NVME.CMD)
#define NVME_SLOT_FREE  APB_REG(NVME.SLOT_FREE)
#define NVME_DB_ERR     APB_REG(NVME.DB_ERR)
#define NVME_FETCHES    APB_REG(NVME.FETCHES)
#define NVME_AQA        APB_REG(NVME.AQA)
#define NVME_ASQ_LO     APB_REG(NVME.ASQ_LO)
#define NVME_ASQ_HI     APB_REG(NVME.ASQ_HI)
#define NVME_ACQ_LO     APB_REG(NVME.ACQ_LO)
#define NVME_ACQ_HI     APB_REG(NVME.ACQ_HI)
#define NVME_IOQ(q, f)  REG32(NVME_BASE + (uint32_t)offsetof(nvme_regs_t, IOQ) + \
                              0x20u * ((uint32_t)(q) - 1u) + \
                              (uint32_t)offsetof(nvme_regs__IOQ__stride20_t, f))
#define NVME_SQ_PTR(q)  REG32(NVME_BASE + (uint32_t)offsetof(nvme_regs_t, SQ_PTR) + 4u * (uint32_t)(q))
#define NVME_CQ_PTR(q)  REG32(NVME_BASE + (uint32_t)offsetof(nvme_regs_t, CQ_PTR) + 4u * (uint32_t)(q))

#define NVME_IEN_CMD       NVME_REGS__CTRL__IEN_CMD_bm
#define NVME_ST_RDY        NVME_REGS__STATUS__RDY_bm
#define NVME_ST_CFS        NVME_REGS__STATUS__CFS_bm
#define NVME_ST_CMDS(s)    (((s) & NVME_REGS__STATUS__CMDS_bm) >> NVME_REGS__STATUS__CMDS_bp)
#define NVME_ST_FREE(s)    (((s) & NVME_REGS__STATUS__FREE_bm) >> NVME_REGS__STATUS__FREE_bp)
#define NVME_EV_ENABLE     NVME_REGS__EVENT__ENABLE_bm
#define NVME_EV_RESET      NVME_REGS__EVENT__RESET_bm
#define NVME_EV_SHUTDOWN   NVME_REGS__EVENT__SHUTDOWN_bm
#define NVME_EV_DB_ERR     NVME_REGS__EVENT__DB_ERR_bm
#define NVME_EV_FETCH_ERR  NVME_REGS__EVENT__FETCH_ERR_bm
#define NVME_CMD_VALID     NVME_REGS__CMD__VALID_bm
#define NVME_CMD_SLOT(c)   ((c) & NVME_REGS__CMD__SLOT_bm)
#define NVME_CMD_SQID(c)   (((c) & NVME_REGS__CMD__SQID_bm) >> NVME_REGS__CMD__SQID_bp)
#define NVME_Q_EN          (1u << 31)   /* SQ_CFG.EN, CQ_CFG.EN */
#define NVME_CQ_IEN        (1u << 24)
#define NVME_EV_CQE_ERR    NVME_REGS__EVENT__CQE_ERR_bm
#define NVME_IEN_XFER      NVME_REGS__CTRL__IEN_XFER_bm

/* Data transfers by PRP and completion queue entries (step 2-3,
 * docs/12_nvme_data.md). */
#define NVME_XF_PRP1_LO    APB_REG(NVME.XF_PRP1_LO)
#define NVME_XF_PRP1_HI    APB_REG(NVME.XF_PRP1_HI)
#define NVME_XF_PRP2_LO    APB_REG(NVME.XF_PRP2_LO)
#define NVME_XF_PRP2_HI    APB_REG(NVME.XF_PRP2_HI)
#define NVME_XF_LADDR      APB_REG(NVME.XF_LADDR)
#define NVME_XF_LEN        APB_REG(NVME.XF_LEN)
#define NVME_XF_CTRL       APB_REG(NVME.XF_CTRL)
#define NVME_XF_STATUS     APB_REG(NVME.XF_STATUS)
#define NVME_XF_CYCLES     APB_REG(NVME.XF_CYCLES)
#define NVME_CQE_DW0       APB_REG(NVME.CQE_DW0)
#define NVME_CQE_INFO      APB_REG(NVME.CQE_INFO)
#define NVME_CQE_CTRL      APB_REG(NVME.CQE_CTRL)
#define NVME_CQE_STATUS    APB_REG(NVME.CQE_STATUS)
#define NVME_CQES          APB_REG(NVME.CQES)

#define NVME_XF_START      NVME_REGS__XF_CTRL__START_bm
#define NVME_XF_D2H        NVME_REGS__XF_CTRL__D2H_bm
#define NVME_XF_BUSY       NVME_REGS__XF_STATUS__BUSY_bm
#define NVME_XF_DONE       NVME_REGS__XF_STATUS__DONE_bm
#define NVME_XF_ERR        NVME_REGS__XF_STATUS__ERR_bm
#define NVME_XF_CAUSE(s)   (((s) & NVME_REGS__XF_STATUS__CAUSE_bm) >> NVME_REGS__XF_STATUS__CAUSE_bp)
#define NVME_CQE_FULL      NVME_REGS__CQE_STATUS__FULL_bm

/* Epochs (step 2-5): the epoch a command was fetched in, and where firmware
 * writes it back: XF_CTRL, CQE_CTRL, SQ_CFG and CQ_CFG. */
#define NVME_STALE         APB_REG(NVME.STALE)
#define NVME_CMD_EPOCH(c)  (((c) & NVME_REGS__CMD__EPOCH_bm) >> NVME_REGS__CMD__EPOCH_bp)
#define NVME_ST_EPOCH(s)   (((s) & NVME_REGS__STATUS__EPOCH_bm) >> NVME_REGS__STATUS__EPOCH_bp)
#define NVME_XF_EPOCH(e)   ((uint32_t)(e) << NVME_REGS__XF_CTRL__EPOCH_bp)
#define NVME_CQE_EPOCH(e)  ((uint32_t)(e) << NVME_REGS__CQE_CTRL__EPOCH_bp)
#define NVME_FREE_EPOCH(e) ((uint32_t)(e) << NVME_REGS__SLOT_FREE__EPOCH_bp)
#define NVME_Q_EPOCH(e)    ((uint32_t)(e) << 26)   /* SQ_CFG.EPOCH, CQ_CFG.EPOCH */
#define NVME_Q_EPOCH_OF(v) (((v) >> 26) & 0xFu)
#define NVME_CQE_STALE     NVME_REGS__CQE_STATUS__STALE_bm
#define NVME_XF_STALE      11u                     /* XF_STATUS.CAUSE: not started */

#define INTC_PENDING   APB_REG(INTC.PENDING)
#define INTC_ENABLE    APB_REG(INTC.ENABLE)
#define INTC_CLAIM     APB_REG(INTC.CLAIM)
#define INTC_SWSET     APB_REG(INTC.SWSET)

#define TIMER_MTIME_LO     APB_REG(TIMER.MTIME_LO)
#define TIMER_MTIME_HI     APB_REG(TIMER.MTIME_HI)
#define TIMER_MTIMECMP_LO  APB_REG(TIMER.MTIMECMP_LO)
#define TIMER_MTIMECMP_HI  APB_REG(TIMER.MTIMECMP_HI)
#define TIMER_CTRL         APB_REG(TIMER.CTRL)

#define DMA_BASE       (APB_BASE + (uint32_t)offsetof(soc_apb_t, DMA))
#define DMA_CTRL       APB_REG(DMA.CTRL)
#define DMA_DESC_PTR   APB_REG(DMA.DESC_PTR)
#define DMA_STATUS     APB_REG(DMA.STATUS)
#define DMA_ERR_INFO   APB_REG(DMA.ERR_INFO)
#define DMA_ERR_ADDR   APB_REG(DMA.ERR_ADDR)
#define DMA_CUR_DESC   APB_REG(DMA.CUR_DESC)
#define DMA_DESC_DONE  APB_REG(DMA.DESC_DONE)
#define DMA_CYCLES     APB_REG(DMA.CYCLES)

#define DMA_START  DMA_REGS__CTRL__START_bm
#define DMA_ABORT  DMA_REGS__CTRL__ABORT_bm
#define DMA_BUSY   DMA_REGS__STATUS__BUSY_bm
#define DMA_DONE   DMA_REGS__STATUS__DONE_bm
#define DMA_ERR    DMA_REGS__STATUS__ERR_bm
#define DMA_FENCE  (1u << 24) /* in dma_desc_t.len */

/* DMA descriptor (docs/06_dma.md). len: [23:0] bytes, [24] FENCE. next: the
 * next descriptor, 16-byte aligned, or 0 to end the chain. */
typedef struct __attribute__((aligned(16))) {
  uint32_t src;
  uint32_t dst;
  uint32_t len;
  uint32_t next;
} dma_desc_t;

/* INTC source IDs (docs/01, section 7). */
#define IRQ_DMA_DONE 1u
#define IRQ_DMA_ERR  2u
#define IRQ_NVME     3u
#define IRQ_HOST_ERR 5u
#define IRQ_PMU      10u
#define IRQ_HOST_BM  12u

#define SOC_ID SYS_REGS__ID__VALUE_reset

#define MCAUSE_INSTR_FAULT 1u
#define MCAUSE_LOAD_FAULT  5u
#define MCAUSE_STORE_FAULT 7u
#define MCAUSE_TIMER_IRQ   0x80000007u
#define MCAUSE_EXT_IRQ     0x8000000Bu

#define read_csr(r) ({ uint32_t v_; __asm__ volatile("csrr %0, " #r : "=r"(v_)); v_; })
#define write_csr(r, v) __asm__ volatile("csrw " #r ", %0" :: "rK"(v))
#define set_csr(r, v) __asm__ volatile("csrs " #r ", %0" :: "rK"(v))
#define clear_csr(r, v) __asm__ volatile("csrc " #r ", %0" :: "rK"(v))

static inline uint64_t timer_now(void)
{
  uint32_t hi, lo;
  do {
    hi = TIMER_MTIME_HI;
    lo = TIMER_MTIME_LO;
  } while (hi != TIMER_MTIME_HI);
  return ((uint64_t)hi << 32) | lo;
}

/* Raise mtimecmp's high word first so no intermediate value fires. */
static inline void timer_set_cmp(uint64_t t)
{
  TIMER_MTIMECMP_HI = 0xFFFFFFFFu;
  TIMER_MTIMECMP_LO = (uint32_t)t;
  TIMER_MTIMECMP_HI = (uint32_t)(t >> 32);
}

#endif
