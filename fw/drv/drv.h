/*
 * Drivers for the Storage_SoC peripherals (step 1-8,
 * docs/08_firmware.md). Interrupt-driven: every wait sleeps in WFI until the
 * block's interrupt arrives, and the CPU's clock gate stops the core while it
 * sleeps.
 *
 *   irq    one trap handler: the machine timer, and one handler per INTC
 *          source, called with the source ID; exceptions end the run
 *   timer  cycle counter (mtime counts clk_sys clocks), sleeping delay
 *   dma    chains of descriptors, completion by interrupt, error decode
 *   pmu    PD_HOST power-down and power-up by interrupt, chip reset
 *   host   one command to the PD_HOST placeholder and its response
 *   crc32  table-driven CRC-32 (reflected, polynomial 0xEDB88320)
 */
#ifndef DRV_H
#define DRV_H

#include <stdint.h>
#include "soc.h"

/* irq */
typedef void (*irq_fn)(uint32_t id);
void irq_init(void);
void irq_register(uint32_t id, irq_fn fn);
void irq_timer_register(void (*fn)(void));
void irq_wait(volatile uint32_t *flag);
extern volatile uint32_t irq_count;

/* timer */
static inline uint32_t timer_cycles(void) { return TIMER_MTIME_LO; }
void timer_sleep(uint32_t ticks);

/* dma */
typedef struct {
  uint32_t status;     /* STATUS at the end: DMA_DONE or DMA_ERR */
  uint32_t err_info;
  uint32_t err_addr;
  uint32_t desc_done;
  uint32_t cycles;     /* the DMA's own CYCLES register */
} dma_result_t;

void dma_init(void);
void dma_set(dma_desc_t *d, uint32_t src, uint32_t dst, uint32_t len, dma_desc_t *next);
void dma_start(const dma_desc_t *first);
int  dma_busy(void);
void dma_wait(dma_result_t *r);
int  dma_copy(uint32_t dst, uint32_t src, uint32_t len, dma_result_t *r);

/* pmu */
typedef struct {
  uint32_t status;     /* PWR_STATUS at the end */
  uint32_t irq;        /* PWR_IRQ bits that ended the sequence */
  uint32_t cycles;     /* clk_sys clocks from the request to the interrupt */
} pmu_result_t;

void pmu_init(void);
int  pmu_host_down(pmu_result_t *r);
int  pmu_host_up(pmu_result_t *r);
void pmu_chip_reset(void) __attribute__((noreturn));

/* host */
uint32_t host_cmd(uint32_t cmd);

/* crc32 */
uint32_t crc32(const void *p, uint32_t len);

#endif
