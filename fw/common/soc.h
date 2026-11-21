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
#define IRQ_PMU      10u

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
