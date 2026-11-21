/*
 * soc_app: the phase-1 firmware flow on soc_top, on the drivers in fw/drv
 * (step 1-8, docs/08_firmware.md).
 *   1. boot: identification, reset cause, PD_HOST on after the automatic
 *      power-up
 *   2. memory check of the DMA buffer area (M2's quarter of SRAM,
 *      0x1000_8000 to 0x1000_BFFF): each word its own address, then the
 *      inverse
 *   3. DMA: a 4 KiB pattern copied SRAM -> NAND0 page buffer -> SRAM, the
 *      second step with FENCE; CRC-32 of source and result agree
 *   4. CPU and DMA at once: a CRC-32 of 4 KiB by the CPU alone, an 8 KiB DMA
 *      copy alone, then both together; clocks for each
 *   5. PD_HOST power cycle by interrupt, with the placeholder's retained
 *      state checked before and after
 * Every wait sleeps in WFI until its interrupt.
 */
#include "drv.h"
#include "lib.h"

#define AREA     (SRAM_BASE + 0x8000u)
#define AREA_LEN 0x4000u
#define BUF_A    (SRAM_BASE + 0x8000u)
#define BUF_B    (SRAM_BASE + 0xA000u)

static uint8_t cpu_buf[4096];
static dma_desc_t desc[2];

static inline uint32_t *w32(uint32_t a) { return (uint32_t *)(uintptr_t)a; }

static void fill(uint32_t *p, uint32_t words, uint32_t seed)
{
  for (uint32_t i = 0; i < words; i++) {
    seed = seed * 1664525u + 1013904223u;
    p[i] = seed;
  }
}

static void report(const char *what, int ok)
{
  sys_puts(what);
  sys_puts(ok ? ": ok\n" : ": FAIL\n");
}

static void put_kv(const char *k, uint32_t v)
{
  sys_puts(k);
  sys_putdec(v);
}

int main(void)
{
  int err = 0;
  dma_result_t dr;
  pmu_result_t pr;
  uint32_t t0, t1, t2, t3;

  /* 1. Boot. */
  irq_init();
  dma_init();
  pmu_init();
  sys_puts("soc_app: ID ");
  sys_puthex(SYS_ID);
  sys_puts(" VERSION ");
  sys_puthex(SYS_VERSION);
  sys_puts(" RST_CAUSE ");
  sys_puthex(PMU_RST_CAUSE);
  sys_putc('\n');
  while (PMU_STATE(PMU_PWR_STATUS) != PMU_STATE_ON) {
  }
  int ok = (SYS_ID == SOC_ID) && (HOST_STATUS & HOST_ON);
  report("boot", ok);
  if (!ok) err |= 1;

  /* 2. Memory check. */
  t0 = timer_cycles();
  uint32_t bad = 0;
  for (uint32_t a = AREA; a < AREA + AREA_LEN; a += 4) *w32(a) = a;
  for (uint32_t a = AREA; a < AREA + AREA_LEN; a += 4) bad += (*w32(a) != a);
  for (uint32_t a = AREA; a < AREA + AREA_LEN; a += 4) *w32(a) = ~a;
  for (uint32_t a = AREA; a < AREA + AREA_LEN; a += 4) bad += (*w32(a) != ~a);
  t1 = timer_cycles();
  put_kv("memory check: 16 KiB, words wrong ", bad);
  put_kv(", clocks ", t1 - t0);
  sys_putc('\n');
  if (bad) err |= 2;

  /* 3. DMA through the NAND0 page buffer. */
  fill(w32(BUF_A), 1024, 7);
  uint32_t crc_a = crc32(w32(BUF_A), 4096);
  dma_set(&desc[0], BUF_A, NAND0_BASE, 4096, &desc[1]);
  dma_set(&desc[1], NAND0_BASE, BUF_B, 4096 | DMA_FENCE, 0);
  dma_start(&desc[0]);
  dma_wait(&dr);
  uint32_t crc_b = crc32(w32(BUF_B), 4096);
  sys_puts("DMA SRAM -> NAND0 -> SRAM: CRC ");
  sys_puthex(crc_a);
  sys_puts(" / ");
  sys_puthex(crc_b);
  put_kv(", DMA cycles ", dr.cycles);
  sys_putc('\n');
  if (dr.status != DMA_DONE || dr.desc_done != 2 || crc_a != crc_b) err |= 4;

  /* 4. CPU and DMA alone and together. */
  fill((uint32_t *)cpu_buf, 1024, 3);
  t0 = timer_cycles();
  uint32_t crc_cpu = crc32(cpu_buf, 4096);
  t1 = timer_cycles();
  uint32_t t_cpu = t1 - t0;

  t0 = timer_cycles();
  if (dma_copy(BUF_B, BUF_A, 8192, &dr) != 0) err |= 8;
  t1 = timer_cycles();
  uint32_t t_dma = t1 - t0;

  dma_set(&desc[0], BUF_A, BUF_B, 8192, 0);
  t0 = timer_cycles();
  dma_start(&desc[0]);
  uint32_t crc_both = crc32(cpu_buf, 4096);
  t2 = timer_cycles();
  dma_wait(&dr);
  t3 = timer_cycles();
  uint32_t t_cpu_both = t2 - t0;
  uint32_t t_both = t3 - t0;
  put_kv("alone: CRC-32 of 4 KiB ", t_cpu);
  put_kv(" clocks, DMA copy of 8 KiB ", t_dma);
  put_kv(" clocks; together: CRC done after ", t_cpu_both);
  put_kv(", both after ", t_both);
  put_kv(" (alone one after the other: ", t_cpu + t_dma);
  sys_puts(")\n");
  /* Timing is reported, not checked: under heavy SRAM contention from other
   * masters, together can take longer than one after the other. */
  if (crc_both != crc_cpu || dr.status != DMA_DONE) err |= 8;

  /* 5. PD_HOST power cycle. */
  uint32_t r_cfg = host_cmd(0x10005A5Au);
  uint32_t r_e0  = host_cmd(0x00000001u);
  uint32_t r_e1  = host_cmd(0x00000002u);
  int dn = pmu_host_down(&pr);
  uint32_t t_dn = pr.cycles;
  int up = pmu_host_up(&pr);
  uint32_t t_up = pr.cycles;
  uint32_t state = host_cmd(0x20000000u);
  uint32_t seq = host_cmd(0x30000000u);
  put_kv("PD_HOST: down ", t_dn);
  put_kv(" clocks, up ", t_up);
  sys_puts(" clocks; STATE ");
  sys_puthex(state);
  put_kv(" SEQ ", seq);
  sys_putc('\n');
  if (r_cfg != 0x10005A5Au || r_e0 != 0x00000001u || r_e1 != 0x00010002u) err |= 16;
  if (dn != 0 || up != 0 || state != 0x5A5A0000u || seq != 2u) err |= 16;

  put_kv("interrupts taken ", irq_count);
  put_kv(", CPU clock gated for ", SYS_SLEEP_CYCLES);
  sys_puts(" clocks\n");
  report("soc_app", err == 0);
  return err;
}
