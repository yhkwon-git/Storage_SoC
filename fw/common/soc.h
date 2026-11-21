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
#define PMU_BASE    (APB_BASE + 0x1000u) /* slot reserved; no registers yet */

#define SYS_ID         APB_REG(SYS.ID)
#define SYS_VERSION    APB_REG(SYS.VERSION)
#define SYS_SCRATCH    APB_REG(SYS.SCRATCH)
#define SYS_CONSOLE    APB_REG(SYS.CONSOLE)
#define SYS_EXIT       APB_REG(SYS.EXIT)

#define INTC_PENDING   APB_REG(INTC.PENDING)
#define INTC_ENABLE    APB_REG(INTC.ENABLE)
#define INTC_CLAIM     APB_REG(INTC.CLAIM)
#define INTC_SWSET     APB_REG(INTC.SWSET)

#define TIMER_MTIME_LO     APB_REG(TIMER.MTIME_LO)
#define TIMER_MTIME_HI     APB_REG(TIMER.MTIME_HI)
#define TIMER_MTIMECMP_LO  APB_REG(TIMER.MTIMECMP_LO)
#define TIMER_MTIMECMP_HI  APB_REG(TIMER.MTIMECMP_HI)
#define TIMER_CTRL         APB_REG(TIMER.CTRL)

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
