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
 *   nvme   NVMe admin and I/O commands on an SRAM namespace (step 2-4)
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
void     host_hold(void);      /* LINK_CTRL.HOLD, then wait for the host path to be idle */
void     host_release(void);

/* crc32 */
uint32_t crc32(const void *p, uint32_t len);

/* nvme: command handling (step 2-4, docs/13_nvme_firmware.md). Call
 * irq_init() first. nvme_service() sleeps until the NVMe interrupt, takes
 * every waiting command, and returns 1 once the host has asked for a
 * shutdown. */
typedef struct {
  uint32_t cmds, admin, reads, writes, flushes, errors, resets;
  uint32_t fw_clocks;     /* clocks in the command loop, spinning on transfers left out */
  uint32_t spin_clocks;   /* clocks spinning on a transfer's end */
  uint32_t xfer_clocks;   /* summed XF_CYCLES of the PRP transfers */
  uint32_t bytes;
} nvme_stats_t;
extern nvme_stats_t nvme_stats;
void     nvme_init(void);
int      nvme_service(void);
uint32_t nvme_events(void);

#endif
