/*
 * nvme_app: the NVMe front-end's firmware (step 2-4, docs/13_nvme_firmware.md)
 * on the drivers in fw/drv. It serves the host's admin and I/O commands
 * (fw/drv/nvme.c) until the host shuts the controller down, then reports
 * what it did and what it cost:
 *   commands by kind, errors, bytes moved;
 *   firmware clocks per command (clocks in the command loop, spinning on
 *   transfers left out), spin clocks and transfer clocks.
 * The host side of the run is tb_soc's +test=nvme_app.
 */
#include "drv.h"
#include "lib.h"

static void stat(const char *what, uint32_t v)
{
  sys_puts(what);
  sys_putdec(v);
}

int main(void)
{
  int err = 0;
  uint32_t n = 0;

  irq_init();
  /* The host enumerates the device before it touches the controller. */
  while ((HOST_LINK_STATUS & HOST_BME) == 0u) {
    if (++n > 1000000u) {
      sys_puts("nvme_app: no enumeration\n");
      return 1;
    }
  }
  /* What a register access costs the CPU: 32 reads of NVME STATUS, 32
   * writes of CQE_DW0 (a write there does nothing until CQE_CTRL). */
  {
    uint32_t t0 = timer_cycles();
    for (int i = 0; i < 32; i++) (void)NVME_STATUS;
    uint32_t t1 = timer_cycles();
    for (int i = 0; i < 32; i++) NVME_CQE_DW0 = (uint32_t)i;
    uint32_t t2 = timer_cycles();
    stat("nvme_app: APB register read ", (t1 - t0) / 32u);
    stat(" clocks, write ", (t2 - t1) / 32u);
    sys_puts(" clocks\n");
  }
  nvme_init();
  sys_puts("nvme_app: ready\n");
  while (!nvme_service()) {
  }

  stat("nvme_app: commands ", nvme_stats.cmds);
  stat(" (admin ", nvme_stats.admin);
  stat(", read ", nvme_stats.reads);
  stat(", write ", nvme_stats.writes);
  stat(", flush ", nvme_stats.flushes);
  stat("), with an error status ", nvme_stats.errors);
  stat(", bytes ", nvme_stats.bytes);
  stat(", controller resets ", nvme_stats.resets);
  sys_putc('\n');
  /* Commands that predated a controller reset: found stale by firmware, and
   * the posts and starts the hardware refused for a stale epoch. */
  stat("nvme_app: stale commands ", nvme_stats.stale);
  stat(", stale posts discarded ", NVME_STALE & 0xFFFFu);
  stat(", stale transfer starts refused ", NVME_STALE >> 16);
  sys_putc('\n');
  stat("nvme_app: firmware clocks per command ", nvme_stats.cmds ? nvme_stats.fw_clocks / nvme_stats.cmds : 0u);
  stat(", spinning on transfers in all ", nvme_stats.spin_clocks);
  stat(", transfer clocks in all ", nvme_stats.xfer_clocks);
  stat(", completions written ", NVME_CQES);
  sys_putc('\n');
  if (nvme_events() & (NVME_EV_DB_ERR | NVME_EV_FETCH_ERR | NVME_EV_CQE_ERR)) err |= 2;
  if (NVME_STATUS & NVME_ST_CFS) err |= 4;
  return err;
}
