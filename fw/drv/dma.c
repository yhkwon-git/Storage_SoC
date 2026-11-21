/*
 * DMA driver (rtl/dma/dma.sv, docs/06_dma.md). A chain is started with
 * dma_start and finished with dma_wait, which sleeps until the DONE or ERR
 * interrupt (INTC sources 1 and 2) and returns the DMA's status registers.
 * Between the two the CPU is free to work: the DMA only needs the bus.
 */
#include "drv.h"

#define barrier() __asm__ volatile("" ::: "memory")

static volatile uint32_t dma_status;
static volatile uint32_t dma_ended;

static void on_dma(uint32_t id)
{
  (void)id;
  dma_status = DMA_STATUS;
  DMA_STATUS = DMA_DONE | DMA_ERR;   /* the sources are levels */
  dma_ended = 1;
}

void dma_init(void)
{
  irq_register(IRQ_DMA_DONE, on_dma);
  irq_register(IRQ_DMA_ERR, on_dma);
  dma_ended = 0;
}

void dma_set(dma_desc_t *d, uint32_t src, uint32_t dst, uint32_t len, dma_desc_t *next)
{
  d->src = src;
  d->dst = dst;
  d->len = len;
  d->next = (uint32_t)(uintptr_t)next;
}

void dma_start(const dma_desc_t *first)
{
  barrier();   /* descriptors and source data are in memory before START */
  dma_ended = 0;
  DMA_DESC_PTR = (uint32_t)(uintptr_t)first;
  DMA_CTRL = DMA_START;
}

int dma_busy(void)
{
  return !dma_ended;
}

void dma_wait(dma_result_t *r)
{
  irq_wait(&dma_ended);
  barrier();
  r->status = dma_status;
  r->err_info = DMA_ERR_INFO;
  r->err_addr = DMA_ERR_ADDR;
  r->desc_done = DMA_DESC_DONE;
  r->cycles = DMA_CYCLES;
}

int dma_copy(uint32_t dst, uint32_t src, uint32_t len, dma_result_t *r)
{
  static dma_desc_t d;
  dma_set(&d, src, dst, len, 0);
  dma_start(&d);
  dma_wait(r);
  return r->status == DMA_DONE ? 0 : -1;
}
