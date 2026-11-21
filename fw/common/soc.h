/* Storage_SoC address map and registers (docs/01_soc_architecture.md, sections 6-7). */
#ifndef SOC_H
#define SOC_H

#include <stdint.h>

#define REG32(a) (*(volatile uint32_t *)(uintptr_t)(a))

#define ROM_BASE    0x00000000u
#define SRAM_BASE   0x10000000u
#define NAND0_BASE  0x30000000u
#define NAND1_BASE  0x30010000u
#define APB_BASE    0x40000000u

#define SYS_BASE    (APB_BASE + 0x0000u)
#define PMU_BASE    (APB_BASE + 0x1000u)
#define INTC_BASE   (APB_BASE + 0x2000u)
#define TIMER_BASE  (APB_BASE + 0x3000u)

#define SYS_ID         REG32(SYS_BASE + 0x000)
#define SYS_VERSION    REG32(SYS_BASE + 0x004)
#define SYS_SCRATCH    REG32(SYS_BASE + 0x008)
#define SYS_CONSOLE    REG32(SYS_BASE + 0x010)
#define SYS_EXIT       REG32(SYS_BASE + 0x014)

#define INTC_PENDING   REG32(INTC_BASE + 0x000)
#define INTC_ENABLE    REG32(INTC_BASE + 0x004)
#define INTC_CLAIM     REG32(INTC_BASE + 0x008)
#define INTC_SWSET     REG32(INTC_BASE + 0x00C)

#define TIMER_MTIME_LO     REG32(TIMER_BASE + 0x000)
#define TIMER_MTIME_HI     REG32(TIMER_BASE + 0x004)
#define TIMER_MTIMECMP_LO  REG32(TIMER_BASE + 0x008)
#define TIMER_MTIMECMP_HI  REG32(TIMER_BASE + 0x00C)
#define TIMER_CTRL         REG32(TIMER_BASE + 0x010)

#define SOC_ID 0x53534F43u

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
