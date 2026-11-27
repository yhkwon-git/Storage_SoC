/*
 * ssd_app: the NVMe firmware of step 2-4 on a NAND namespace (step 3-4,
 * docs/18_nvme_nand.md). fw/drv/nvme.c, built with NS_NAND, serves the
 * host's commands; Read and Write go through the flash translation layer
 * (fw/drv/ftl.c) to both NAND channels and their BCH path. The flash
 * translation layer starts while the host enumerates the device. At the
 * host's shutdown the firmware reports the commands, then what the NAND
 * side did: logical pages read and written, erases, bad blocks, bits the
 * code corrected, and the clocks a logical page took.
 * The host side of the run is tb_soc's +test=ssd_app or nvme_rand.
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
  dma_init();
  if (ftl_init() != 0) {
    sys_puts("ssd_app: NAND channels did not reset\n");
    return 1;
  }
  stat("ssd_app: flash translation layer ready, factory bad blocks ", ftl_stats.bad_blocks);
  sys_putc('\n');
  while ((HOST_LINK_STATUS & HOST_BME) == 0u) {
    if (++n > 1000000u) {
      sys_puts("ssd_app: no enumeration\n");
      return 1;
    }
  }
  nvme_init();
  sys_puts("ssd_app: ready\n");
  while (!nvme_service()) {
  }

  stat("ssd_app: commands ", nvme_stats.cmds);
  stat(" (admin ", nvme_stats.admin);
  stat(", read ", nvme_stats.reads);
  stat(", write ", nvme_stats.writes);
  stat(", flush ", nvme_stats.flushes);
  stat("), with an error status ", nvme_stats.errors);
  stat(", bytes ", nvme_stats.bytes);
  stat(", controller resets ", nvme_stats.resets);
  stat(", stale commands ", nvme_stats.stale);
  sys_putc('\n');
  stat("ssd_app: NAND: logical pages read ", ftl_stats.reads);
  stat(" (never written ", ftl_stats.unmapped);
  stat("), written ", ftl_stats.writes);
  stat(", erases ", ftl_stats.erases);
  stat(", bad blocks ", ftl_stats.bad_blocks);
  stat(", program failures ", ftl_stats.prog_fails);
  stat("; bits corrected ", ftl_stats.ecc_bits);
  stat(", codewords past correcting ", ftl_stats.ecc_unc);
  stat(", metadata mismatches ", ftl_stats.meta_errors);
  sys_putc('\n');
  stat("ssd_app: clocks per logical page: read ", ftl_stats.reads ? ftl_stats.read_clocks / ftl_stats.reads : 0u);
  stat(", write ", ftl_stats.writes ? ftl_stats.write_clocks / ftl_stats.writes : 0u);
  sys_putc('\n');
  if (nvme_events() & (NVME_EV_DB_ERR | NVME_EV_FETCH_ERR | NVME_EV_CQE_ERR)) err |= 2;
  if (NVME_STATUS & NVME_ST_CFS) err |= 4;
  if (ftl_stats.meta_errors != 0u) err |= 8;
  return err;
}
