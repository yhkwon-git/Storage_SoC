<!---
Markdown description for SystemRDL register map.

Don't override. Generated from: soc_apb
  - rtl/csr/rdl/soc_apb.rdl
-->

## soc_apb address map

- Absolute Address: 0x0
- Base Offset: 0x0
- Size: 0x8234

<p>Register blocks in the APB window at 0x4000_0000, one 4 KiB slot each.</p>

|Offset|Identifier| Name|
|------|----------|-----|
|0x0000|    SYS   | SYS |
|0x1000|    PMU   | PMU |
|0x2000|   INTC   | INTC|
|0x3000|   TIMER  |TIMER|
|0x4000|    DMA   | DMA |
|0x5000|   HOST   | HOST|
|0x6000|   NAND0  | NAND|
|0x7000|   NAND1  | NAND|
|0x8000|   NVME   | NVME|

## SYS address map

- Absolute Address: 0x0
- Base Offset: 0x0
- Size: 0x10C

<p>Identification, a scratch register, and the simulation console and exit registers.</p>

|Offset| Identifier |    Name    |
|------|------------|------------|
| 0x000|     ID     |     ID     |
| 0x004|   VERSION  |   VERSION  |
| 0x008|   SCRATCH  |   SCRATCH  |
| 0x010|   CONSOLE  |   CONSOLE  |
| 0x014|    EXIT    |    EXIT    |
| 0x100| SOFT_RESET | SOFT_RESET |
| 0x104|  CLK_GATE  |  CLK_GATE  |
| 0x108|SLEEP_CYCLES|SLEEP_CYCLES|

### ID register

- Absolute Address: 0x0
- Base Offset: 0x0
- Size: 0x4

<p>Fixed identification value, "SSOC" in ASCII.</p>

|Bits|Identifier|Access|   Reset  |Name|
|----|----------|------|----------|----|
|31:0|   value  |   r  |0x53534F43|  — |

### VERSION register

- Absolute Address: 0x4
- Base Offset: 0x4
- Size: 0x4

<p>Register map version: 0x0003_0002 is the map of step 3-3 (BCH in the NAND channels).</p>

|Bits|Identifier|Access| Reset |Name|
|----|----------|------|-------|----|
|31:0|   value  |   r  |0x30002|  — |

### SCRATCH register

- Absolute Address: 0x8
- Base Offset: 0x8
- Size: 0x4

<p>Free for software. Byte strobes are honored.</p>

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|31:0|   value  |  rw  | 0x0 |  — |

### CONSOLE register

- Absolute Address: 0x10
- Base Offset: 0x10
- Size: 0x4

<p>A write sends CHAR to the simulation console. Reads return 0.</p>

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
| 7:0|   char   |   w  | 0x0 |  — |

### EXIT register

- Absolute Address: 0x14
- Base Offset: 0x14
- Size: 0x4

<p>A write ends the simulation with CODE; 0 means pass. Reads return 0.</p>

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|31:0|   code   |   w  | 0x0 |  — |

### SOFT_RESET register

- Absolute Address: 0x100
- Base Offset: 0x100
- Size: 0x4

<p>While a bit is 1 its block is held in reset. Use only while the block is idle: a block reset with transactions outstanding leaves them unanswered.</p>

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|  0 |    dma   |  rw  | 0x0 |  — |
|  1 |   nand0  |  rw  | 0x0 |  — |
|  2 |   nand1  |  rw  | 0x0 |  — |

#### dma field

<p>DMA, registers included.</p>

#### nand0 field

<p>NAND0: both clock domains, registers included (the page buffer keeps its contents).</p>

#### nand1 field

<p>NAND1, as NAND0.</p>

### CLK_GATE register

- Absolute Address: 0x104
- Base Offset: 0x104
- Size: 0x4

<p>Clock gates for idle blocks.</p>

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|  0 |    cpu   |  rw  | 0x1 |  — |

#### cpu field

<p>Gate the CPU's clock while it sleeps in WFI with no interrupt pending, as Ibex's own top level does.</p>

### SLEEP_CYCLES register

- Absolute Address: 0x108
- Base Offset: 0x108
- Size: 0x4

<p>Clocks the CPU's clock gate has removed since reset.</p>

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|31:0|   count  |   r  |  —  |  — |

## PMU address map

- Absolute Address: 0x1000
- Base Offset: 0x1000
- Size: 0x20

<p>Power management in PD_AON, clocked by clk_aon and reset only at power-on; reached through an APB clock-domain crossing (rtl/pmu/apb_cdc.sv), so an access takes a few clk_aon cycles. Sequences and states are in docs/07_clock_reset_power.md.</p>

|Offset| Identifier|    Name   |
|------|-----------|-----------|
| 0x00 |  PWR_CTRL |  PWR_CTRL |
| 0x04 | PWR_STATUS| PWR_STATUS|
| 0x08 |  PWR_IRQ  |  PWR_IRQ  |
| 0x0C |  TIMEOUT  |  TIMEOUT  |
| 0x10 | CHIP_RESET| CHIP_RESET|
| 0x14 | RST_CAUSE | RST_CAUSE |
| 0x18 |AON_SCRATCH|AON_SCRATCH|
| 0x1C | PWR_CYCLES| PWR_CYCLES|

### PWR_CTRL register

- Absolute Address: 0x1000
- Base Offset: 0x0
- Size: 0x4

<p>UP starts the PD_HOST power-up sequence from OFF or FAIL; DOWN starts the power-down sequence from ON. Both read as 0.</p>

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|  0 |    up    |   w  | 0x0 |  — |
|  1 |   down   |   w  | 0x0 |  — |
|  8 |  wake_en |  rw  | 0x1 |  — |

#### wake_en field

<p>A rising edge on the wake pin powers PD_HOST up from OFF.</p>

### PWR_STATUS register

- Absolute Address: 0x1004
- Base Offset: 0x4
- Size: 0x4

| Bits|Identifier|Access|Reset|Name|
|-----|----------|------|-----|----|
| 3:0 |   state  |   r  |  —  |  — |
|  8  |    on    |   r  |  —  |  — |
|17:16|  result  |   r  |  —  |  — |
|  24 |   woke   |   r  |  —  |  — |

#### state field

<p>Sequencer state: 0 OFF, 1-4 powering up, 5 ON, 6-10 powering down, 11 FAIL.</p>

#### on field

<p>PD_HOST is on with isolation released.</p>

#### result field

<p>Last sequence: 0 none, 1 completed, 2 power-down refused (host path busy), 3 timeout.</p>

#### woke field

<p>The last power-up was started by the wake pin.</p>

### PWR_IRQ register

- Absolute Address: 0x1008
- Base Offset: 0x8
- Size: 0x4

<p>INTC source 10. Write 1 to clear. A hardware set wins over a software clear in the same clock.</p>

|Bits|Identifier|  Access |Reset|Name|
|----|----------|---------|-----|----|
|  0 |   done   |rw, woclr| 0x0 |  — |
|  1 |    err   |rw, woclr| 0x0 |  — |

#### done field

<p>A sequence completed.</p>

#### err field

<p>A power-down was refused or a sequence timed out.</p>

### TIMEOUT register

- Absolute Address: 0x100C
- Base Offset: 0xC
- Size: 0x4

<p>clk_aon cycles each wait of a sequence may take (switch acknowledge, PLL lock).</p>

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|15:0|  cycles  |  rw  | 0x40|  — |

### CHIP_RESET register

- Absolute Address: 0x1010
- Base Offset: 0x10
- Size: 0x4

<p>Writing 0x5AFE_0001 resets PD_CORE and PD_HOST's logic and runs the reset release order again; PD_AON and PD_HOST's power state are kept. Any other value is ignored. Reads return 0.</p>

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|31:0|    key   |   w  | 0x0 |  — |

### RST_CAUSE register

- Absolute Address: 0x1014
- Base Offset: 0x14
- Size: 0x4

<p>Why PD_CORE was last reset. Write 1 to clear.</p>

|Bits|Identifier|  Access |Reset|Name|
|----|----------|---------|-----|----|
|  0 |    por   |rw, woclr| 0x0 |  — |
|  1 |   chip   |rw, woclr| 0x0 |  — |

#### por field

<p>Power-on reset.</p>

#### chip field

<p>CHIP_RESET.</p>

### AON_SCRATCH register

- Absolute Address: 0x1018
- Base Offset: 0x18
- Size: 0x4

<p>Free for software; kept across a chip reset.</p>

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|31:0|   value  |  rw  | 0x0 |  — |

### PWR_CYCLES register

- Absolute Address: 0x101C
- Base Offset: 0x1C
- Size: 0x4

<p>Completed PD_HOST power-downs since power-on.</p>

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|15:0|   count  |   r  |  —  |  — |

## INTC address map

- Absolute Address: 0x2000
- Base Offset: 0x2000
- Size: 0x10

<p>Interrupt controller for level sources 1 to 31. Source IDs are in docs/01, section 7.</p>

|Offset|Identifier|  Name |
|------|----------|-------|
|  0x0 |  PENDING |PENDING|
|  0x4 |  ENABLE  | ENABLE|
|  0x8 |   CLAIM  | CLAIM |
|  0xC |   SWSET  | SWSET |

### PENDING register

- Absolute Address: 0x2000
- Base Offset: 0x0
- Size: 0x4

<p>Sources that are high, OR SWSET. Bit 0 is always 0.</p>

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|31:0|   value  |   r  |  —  |  — |

### ENABLE register

- Absolute Address: 0x2004
- Base Offset: 0x4
- Size: 0x4

<p>A source raises the core's external interrupt only while its bit is set.</p>

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|31:0|   value  |  rw  | 0x0 |  — |

### CLAIM register

- Absolute Address: 0x2008
- Base Offset: 0x8
- Size: 0x4

<p>Lowest ID that is pending and enabled, 0 if none. Reading has no side effect.</p>

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
| 4:0|    id    |   r  |  —  |  — |

### SWSET register

- Absolute Address: 0x200C
- Base Offset: 0xC
- Size: 0x4

<p>Software-set sources, ORed into PENDING.</p>

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|31:0|   value  |  rw  | 0x0 |  — |

## TIMER address map

- Absolute Address: 0x3000
- Base Offset: 0x3000
- Size: 0x14

<p>RISC-V machine timer. The interrupt is high while MTIME &gt;= MTIMECMP.</p>

|Offset| Identifier|    Name   |
|------|-----------|-----------|
| 0x00 |  MTIME_LO |  MTIME_LO |
| 0x04 |  MTIME_HI |  MTIME_HI |
| 0x08 |MTIMECMP_LO|MTIMECMP_LO|
| 0x0C |MTIMECMP_HI|MTIMECMP_HI|
| 0x10 |    CTRL   |    CTRL   |

### MTIME_LO register

- Absolute Address: 0x3000
- Base Offset: 0x0
- Size: 0x4

<p>mtime[31:0]. Counts while CTRL.ENABLE is set; a software write takes precedence.</p>

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|31:0|   value  |  rw  | 0x0 |  — |

### MTIME_HI register

- Absolute Address: 0x3004
- Base Offset: 0x4
- Size: 0x4

<p>mtime[63:32].</p>

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|31:0|   value  |  rw  | 0x0 |  — |

### MTIMECMP_LO register

- Absolute Address: 0x3008
- Base Offset: 0x8
- Size: 0x4

<p>mtimecmp[31:0].</p>

|Bits|Identifier|Access|   Reset  |Name|
|----|----------|------|----------|----|
|31:0|   value  |  rw  |0xFFFFFFFF|  — |

### MTIMECMP_HI register

- Absolute Address: 0x300C
- Base Offset: 0xC
- Size: 0x4

<p>mtimecmp[63:32]. Write 0xFFFF_FFFF here first when changing MTIMECMP.</p>

|Bits|Identifier|Access|   Reset  |Name|
|----|----------|------|----------|----|
|31:0|   value  |  rw  |0xFFFFFFFF|  — |

### CTRL register

- Absolute Address: 0x3010
- Base Offset: 0x10
- Size: 0x4

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|  0 |  enable  |  rw  | 0x1 |  — |
|15:8| prescale |  rw  | 0x0 |  — |

#### enable field

<p>Count enable.</p>

#### prescale field

<p>MTIME advances every PRESCALE + 1 clocks.</p>

## DMA address map

- Absolute Address: 0x4000
- Base Offset: 0x4000
- Size: 0x20

<p>Descriptor-based DMA (rtl/dma/dma.sv). Descriptor format and error causes are in docs/06_dma.md.</p>

|Offset|Identifier|   Name  |
|------|----------|---------|
| 0x00 |   CTRL   |   CTRL  |
| 0x04 | DESC_PTR | DESC_PTR|
| 0x08 |  STATUS  |  STATUS |
| 0x0C | ERR_INFO | ERR_INFO|
| 0x10 | ERR_ADDR | ERR_ADDR|
| 0x14 | CUR_DESC | CUR_DESC|
| 0x18 | DESC_DONE|DESC_DONE|
| 0x1C |  CYCLES  |  CYCLES |

### CTRL register

- Absolute Address: 0x4000
- Base Offset: 0x0
- Size: 0x4

<p>Write 1 to START to run the chain at DESC_PTR, or to ABORT to stop a running chain. Both read as 0. START while BUSY is ignored.</p>

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|  0 |   start  |   w  | 0x0 |  — |
|  1 |   abort  |   w  | 0x0 |  — |

#### start field

<p>Start the chain at DESC_PTR.</p>

#### abort field

<p>Stop after the transactions already issued complete.</p>

### DESC_PTR register

- Absolute Address: 0x4004
- Base Offset: 0x4
- Size: 0x4

<p>Address of the first descriptor; 16-byte aligned.</p>

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|31:0|   addr   |  rw  | 0x0 |  — |

### STATUS register

- Absolute Address: 0x4008
- Base Offset: 0x8
- Size: 0x4

<p>DONE and ERR are the DMA's two interrupt sources (INTC 1 and 2). Write 1 to clear; START clears both. A hardware set wins over a software clear in the same clock, so no event is lost.</p>

|Bits|Identifier|  Access |Reset|Name|
|----|----------|---------|-----|----|
|  0 |   busy   |    r    |  —  |  — |
|  1 |   done   |rw, woclr| 0x0 |  — |
|  2 |    err   |rw, woclr| 0x0 |  — |

#### busy field

<p>A chain is running.</p>

#### done field

<p>The chain completed.</p>

#### err field

<p>The chain stopped on an error or an abort; see ERR_INFO.</p>

### ERR_INFO register

- Absolute Address: 0x400C
- Base Offset: 0xC
- Size: 0x4

<p>Why the last run stopped. Cleared by START.</p>

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
| 2:0|   cause  |   r  | 0x0 |  — |
| 5:4|   resp   |   r  | 0x0 |  — |

#### cause field

<p>1 descriptor read error, 2 data read error, 3 data write error, 4 bad descriptor or DESC_PTR, 5 aborted.</p>

#### resp field

<p>RRESP or BRESP of the failed transaction (causes 1 to 3).</p>

### ERR_ADDR register

- Absolute Address: 0x4010
- Base Offset: 0x10
- Size: 0x4

<p>Causes 1 and 4: the descriptor's address. Causes 2 and 3: the start address of the failed burst. Cause 5: CUR_DESC.</p>

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|31:0|   addr   |   r  | 0x0 |  — |

### CUR_DESC register

- Absolute Address: 0x4014
- Base Offset: 0x14
- Size: 0x4

<p>Address of the descriptor whose data is being read, or was read last.</p>

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|31:0|   addr   |   r  |  —  |  — |

### DESC_DONE register

- Absolute Address: 0x4018
- Base Offset: 0x18
- Size: 0x4

<p>Descriptors whose writes all completed in this run, counted until the first error.</p>

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|15:0|   count  |   r  |  —  |  — |

### CYCLES register

- Absolute Address: 0x401C
- Base Offset: 0x1C
- Size: 0x4

<p>Clocks from START to the end of the run (counting while BUSY).</p>

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|31:0|   count  |   r  |  —  |  — |

## HOST address map

- Absolute Address: 0x5000
- Base Offset: 0x5000
- Size: 0x58

<p>Host interface (rtl/host/): the transaction layer's windows, bus master, MSI-X requests, link hold and error status (docs/10_transaction_layer.md), and the PD_HOST placeholder's command and response FIFOs at 0x000 to 0x008, kept for the power tests until the link layer arrives in step 2-6.</p>

|Offset| Identifier|    Name   |
|------|-----------|-----------|
| 0x00 |     TX    |     TX    |
| 0x04 |     RX    |     RX    |
| 0x08 |   STATUS  |   STATUS  |
| 0x10 | LINK_CTRL | LINK_CTRL |
| 0x14 |LINK_STATUS|LINK_STATUS|
| 0x1C |  BAR2_WIN |  BAR2_WIN |
| 0x20 |BM_HADDR_LO|BM_HADDR_LO|
| 0x24 |BM_HADDR_HI|BM_HADDR_HI|
| 0x28 |  BM_LADDR |  BM_LADDR |
| 0x2C |   BM_LEN  |   BM_LEN  |
| 0x30 |  BM_CTRL  |  BM_CTRL  |
| 0x34 | BM_STATUS | BM_STATUS |
| 0x38 | BM_CYCLES | BM_CYCLES |
| 0x3C |  MSIX_REQ |  MSIX_REQ |
| 0x40 | MSIX_PEND | MSIX_PEND |
| 0x44 |CPL_TIMEOUT|CPL_TIMEOUT|
| 0x48 | ERR_STATUS| ERR_STATUS|
| 0x50 |  RX_TLPS  |  RX_TLPS  |
| 0x54 |  TX_TLPS  |  TX_TLPS  |

### TX register

- Absolute Address: 0x5000
- Base Offset: 0x0
- Size: 0x4

<p>A write sends one command into PD_HOST. It is dropped, and STATUS.TX_DROP set, when the FIFO is full or PD_HOST is not on.</p>

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|31:0|   data   |   w  | 0x0 |  — |

### RX register

- Absolute Address: 0x5004
- Base Offset: 0x4
- Size: 0x4

<p>Oldest response; reading it removes it. Reads 0 when STATUS.RX_VALID is 0.</p>

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|31:0|   data   |   r  |  —  |  — |

### STATUS register

- Absolute Address: 0x5008
- Base Offset: 0x8
- Size: 0x4

|Bits|Identifier|  Access |Reset|Name|
|----|----------|---------|-----|----|
|  0 | rx_valid |    r    |  —  |  — |
|  1 |  tx_full |    r    |  —  |  — |
|  2 |    on    |    r    |  —  |  — |
|  3 |   idle   |    r    |  —  |  — |
|  8 |  tx_drop |rw, woclr| 0x0 |  — |

#### rx_valid field

<p>A response is waiting in RX.</p>

#### tx_full field

<p>The command FIFO is full.</p>

#### on field

<p>PD_HOST is on (PMU).</p>

#### idle field

<p>Every command sent has had its response read: the host path is idle.</p>

#### tx_drop field

<p>A command was dropped.</p>

### LINK_CTRL register

- Absolute Address: 0x5010
- Base Offset: 0x10
- Size: 0x4

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|  0 |   hold   |  rw  | 0x0 |  — |

#### hold field

<p>Hold: the link side stops taking new TLPs from the host at the next TLP boundary. Set it before a PD_HOST power-down (the PMU refuses one while the host path is not held and idle) and clear it after the power-up.</p>

### LINK_STATUS register

- Absolute Address: 0x5014
- Base Offset: 0x14
- Size: 0x4

<p>Transaction layer state and the configuration-space settings the host has made.</p>

| Bits|Identifier|Access|Reset|Name|
|-----|----------|------|-----|----|
|  0  | hold_ack |   r  |  —  |  — |
|  1  |   idle   |   r  |  —  |  — |
|  2  |    mse   |   r  |  —  |  — |
|  3  |    bme   |   r  |  —  |  — |
|  4  |  msix_en |   r  |  —  |  — |
|  5  |msix_fmask|   r  |  —  |  — |
|  6  |  mps256  |   r  |  —  |  — |
| 10:8|   mrrs   |   r  |  —  |  — |
|31:16|    id    |   r  |  —  |  — |

#### hold_ack field

<p>Hold is in effect: no TLP from the host is in progress.</p>

#### idle field

<p>The host path is held and idle, as the PMU sees it.</p>

#### mse field

<p>Memory Space Enable.</p>

#### bme field

<p>Bus Master Enable.</p>

#### msix_en field

<p>MSI-X Enable.</p>

#### msix_fmask field

<p>MSI-X Function Mask.</p>

#### mps256 field

<p>Max_Payload_Size is 256 bytes (else 128).</p>

#### mrrs field

<p>Max_Read_Request_Size code: 128 &lt;&lt; MRRS bytes.</p>

#### id field

<p>Bus and device number captured from configuration writes; function 0.</p>

### BAR2_WIN register

- Absolute Address: 0x501C
- Base Offset: 0x1C
- Size: 0x4

<p>AXI address of BAR2 (32 KiB aligned). Reset value: the upper half of SRAM.</p>

| Bits|Identifier|Access| Reset|Name|
|-----|----------|------|------|----|
|31:15|   base   |  rw  |0x2001|  — |

### BM_HADDR_LO register

- Absolute Address: 0x5020
- Base Offset: 0x20
- Size: 0x4

<p>Bus master: host address, bits 31:2. Host address, local address and length are DW-granular.</p>

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|31:2|   addr   |  rw  | 0x0 |  — |

### BM_HADDR_HI register

- Absolute Address: 0x5024
- Base Offset: 0x24
- Size: 0x4

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|31:0|   addr   |  rw  | 0x0 |  — |

#### addr field

<p>Bus master: host address, bits 63:32.</p>

### BM_LADDR register

- Absolute Address: 0x5028
- Base Offset: 0x28
- Size: 0x4

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|31:2|   addr   |  rw  | 0x0 |  — |

#### addr field

<p>Bus master: local (AXI) address, bits 31:2.</p>

### BM_LEN register

- Absolute Address: 0x502C
- Base Offset: 0x2C
- Size: 0x4

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|19:2|   bytes  |  rw  | 0x0 |  — |

#### bytes field

<p>Bus master: length in bytes, a multiple of 4, 4 to 1 MiB - 4.</p>

### BM_CTRL register

- Absolute Address: 0x5030
- Base Offset: 0x30
- Size: 0x4

<p>START while BM_STATUS.BUSY is ignored.</p>

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|  0 |   start  |   w  | 0x0 |  — |
|  1 |    d2h   |  rw  | 0x0 |  — |

#### start field

<p>Start the transfer.</p>

#### d2h field

<p>Direction: 1 SoC to host (memory writes), 0 host to SoC (memory reads).</p>

### BM_STATUS register

- Absolute Address: 0x5034
- Base Offset: 0x34
- Size: 0x4

<p>DONE or ERR is INTC source 12. Write 1 to clear; START clears both.</p>

|Bits|Identifier|  Access |Reset|Name|
|----|----------|---------|-----|----|
|  0 |   busy   |    r    |  —  |  — |
|  1 |   done   |rw, woclr| 0x0 |  — |
|  2 |    err   |rw, woclr| 0x0 |  — |
| 6:4|   cause  |    r    | 0x0 |  — |

#### busy field

<p>A transfer is running.</p>

#### done field

<p>The transfer ended without an error.</p>

#### err field

<p>The transfer ended with an error; see CAUSE.</p>

#### cause field

<p>Cause of the last error: 1 Bus Master Enable clear, 2 local AXI error, 3 UR completion, 4 CA completion, 5 completion timeout, 6 bad or poisoned completion.</p>

### BM_CYCLES register

- Absolute Address: 0x5038
- Base Offset: 0x38
- Size: 0x4

<p>Clocks from START to the end of the last transfer.</p>

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|31:0|   count  |   r  |  —  |  — |

### MSIX_REQ register

- Absolute Address: 0x503C
- Base Offset: 0x3C
- Size: 0x4

<p>A write requests the MSI-X vector it names. While MSI-X is disabled the request is dropped (ERR_STATUS.MSIX_DROP).</p>

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
| 2:0|  vector  |   w  | 0x0 |  — |

### MSIX_PEND register

- Absolute Address: 0x5040
- Base Offset: 0x40
- Size: 0x4

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
| 7:0|  pending |   r  |  —  |  — |

#### pending field

<p>Pending Bit Array: vectors requested while masked.</p>

### CPL_TIMEOUT register

- Absolute Address: 0x5044
- Base Offset: 0x44
- Size: 0x4

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
| 7:0|   ticks  |  rw  | 0x40|  — |

#### ticks field

<p>Bus master completion timeout in units of 64 clocks (reset: 4096 clocks). Device Control 2 can disable it.</p>

### ERR_STATUS register

- Absolute Address: 0x5048
- Base Offset: 0x48
- Size: 0x4

<p>Transaction layer errors, set by hardware and cleared by writing 1. Bits 0 to 6 together are INTC source 5.</p>

|Bits| Identifier|  Access |Reset|Name|
|----|-----------|---------|-----|----|
|  0 |     ur    |rw, woclr| 0x0 |  — |
|  1 | malformed |rw, woclr| 0x0 |  — |
|  2 |  poisoned |rw, woclr| 0x0 |  — |
|  3 | unexp_cpl |rw, woclr| 0x0 |  — |
|  4 |cpl_timeout|rw, woclr| 0x0 |  — |
|  5 |  cpl_err  |rw, woclr| 0x0 |  — |
|  6 |  axi_err  |rw, woclr| 0x0 |  — |
|  7 |  discard  |rw, woclr| 0x0 |  — |
|  8 | msix_drop |rw, woclr| 0x0 |  — |

#### ur field

<p>An unsupported request was received.</p>

#### malformed field

<p>A malformed TLP was received and dropped.</p>

#### poisoned field

<p>A poisoned TLP was received.</p>

#### unexp_cpl field

<p>A completion matched no outstanding request.</p>

#### cpl_timeout field

<p>A bus master request timed out.</p>

#### cpl_err field

<p>A UR or CA completion, or one that failed the checks, was received.</p>

#### axi_err field

<p>An inbound write or read got an AXI error.</p>

#### discard field

<p>The link layer discarded a TLP (from step 2-6).</p>

#### msix_drop field

<p>An MSI-X request was dropped (MSI-X disabled).</p>

### RX_TLPS register

- Absolute Address: 0x5050
- Base Offset: 0x50
- Size: 0x4

<p>TLPs received and dispatched since reset (wraps).</p>

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|31:0|   count  |   r  |  —  |  — |

### TX_TLPS register

- Absolute Address: 0x5054
- Base Offset: 0x54
- Size: 0x4

<p>TLPs sent since reset (wraps).</p>

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|31:0|   count  |   r  |  —  |  — |

## NAND0 address map

- Absolute Address: 0x6000
- Base Offset: 0x6000
- Size: 0x4C

<p>One NAND channel (rtl/nand/nand_ctrl.sv, docs/15_nand_channel.md): an 8-bit ONFI-style asynchronous interface run by a sequencer in clk_nand, a command queue of 4, a completion queue of 8, and an 8 KiB page buffer on the crossbar. NAND0 is at 0x4000_6000 with its page buffer at 0x3000_0000, NAND1 at 0x4000_7000 and 0x3001_0000.</p>

|Offset|Identifier|   Name  |
|------|----------|---------|
| 0x00 |   CTRL   |   CTRL  |
| 0x04 |  STATUS  |  STATUS |
| 0x08 |   EVENT  |  EVENT  |
| 0x10 |  TIMING0 | TIMING0 |
| 0x14 |  TIMING1 | TIMING1 |
| 0x18 |  TIMEOUT | TIMEOUT |
| 0x20 |  CMD_ROW | CMD_ROW |
| 0x24 |  CMD_COL | CMD_COL |
| 0x28 |  CMD_LEN | CMD_LEN |
| 0x2C |  CMD_BUF | CMD_BUF |
| 0x30 |  CMD_GO  |  CMD_GO |
| 0x34 |    CPL   |   CPL   |
| 0x38 |  CYCLES  |  CYCLES |
| 0x3C | BUSY_TIME|BUSY_TIME|
| 0x40 |   COUNT  |  COUNT  |
| 0x44 |  CPL_ECC | CPL_ECC |
| 0x48 | ECC_COUNT|ECC_COUNT|

### CTRL register

- Absolute Address: 0x6000
- Base Offset: 0x0
- Size: 0x4

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|  0 |    wp    |  rw  | 0x1 |  — |
|  1 | ien_done |  rw  | 0x0 |  — |
|  2 |  ien_err |  rw  | 0x0 |  — |

#### wp field

<p>Write protect: WP# is low while this is 1, from reset until firmware clears it.</p>

#### ien_done field

<p>Interrupt (INTC 6 for NAND0, 8 for NAND1) while a completion waits in CPL.</p>

#### ien_err field

<p>Interrupt (INTC 7 for NAND0, 9 for NAND1) while EVENT.ERR or EVENT.OVF is set.</p>

### STATUS register

- Absolute Address: 0x6004
- Base Offset: 0x4
- Size: 0x4

| Bits|Identifier|Access|Reset|Name|
|-----|----------|------|-----|----|
|  0  |   busy   |   r  |  —  |  — |
|  1  |    rb    |   r  |  —  |  — |
| 10:8|   cmds   |   r  |  —  |  — |
|15:12|   cpls   |   r  |  —  |  — |

#### busy field

<p>A command is running.</p>

#### rb field

<p>R/B#, synchronized into clk_sys: 1 ready, 0 busy.</p>

#### cmds field

<p>Commands waiting in the queue, 0 to 4.</p>

#### cpls field

<p>Completions waiting in CPL, 0 to 8.</p>

### EVENT register

- Absolute Address: 0x6008
- Base Offset: 0x8
- Size: 0x4

<p>Set by hardware, cleared by writing 1.</p>

|Bits|Identifier|  Access |Reset|Name|
|----|----------|---------|-----|----|
|  0 |    err   |rw, woclr| 0x0 |  — |
|  1 |    ovf   |rw, woclr| 0x0 |  — |

#### err field

<p>A command completed with a code other than 0.</p>

#### ovf field

<p>CMD_GO was written with 4 commands waiting; that command was dropped.</p>

### TIMING0 register

- Absolute Address: 0x6010
- Base Offset: 0x10
- Size: 0x4

<p>Bus cycle phases in clk_nand clocks (20 ns), 1 to 15; 0 counts as 1. A command takes TIMING0, TIMING1 and TIMEOUT as they are when it starts. The reset values give 100 ns cycles; 1 and 1 give 40 ns cycles, 25 MB/s.</p>

| Bits|Identifier|Access|Reset|Name|
|-----|----------|------|-----|----|
| 3:0 |    twp   |  rw  | 0x3 |  — |
| 7:4 |    twh   |  rw  | 0x2 |  — |
| 11:8|    trp   |  rw  | 0x3 |  — |
|15:12|   treh   |  rw  | 0x2 |  — |

#### twp field

<p>WE# low (tWP).</p>

#### twh field

<p>WE# high (tWH).</p>

#### trp field

<p>RE# low (tRP); DQ is sampled at the clock edge that raises RE#.</p>

#### treh field

<p>RE# high (tREH).</p>

### TIMING1 register

- Absolute Address: 0x6014
- Base Offset: 0x14
- Size: 0x4

<p>Waits in clk_nand clocks, 1 to 63; 0 counts as 1.</p>

| Bits|Identifier|Access|Reset|Name|
|-----|----------|------|-----|----|
| 5:0 |    twb   |  rw  | 0xC |  — |
| 13:8|   twhr   |  rw  | 0x6 |  — |
|21:16|   tadl   |  rw  | 0xA |  — |
|29:24|    trr   |  rw  | 0x2 |  — |

#### twb field

<p>From the confirm command's WE# rising to the first look at R/B# (tWB, plus 2 clocks of synchronizer).</p>

#### twhr field

<p>From the last WE# rising to RE# falling for a status, ID or changed-column read (tWHR).</p>

#### tadl field

<p>From the last address cycle to the first data cycle of a program (tADL).</p>

#### trr field

<p>From R/B# seen ready to the first RE# falling (tRR).</p>

### TIMEOUT register

- Absolute Address: 0x6018
- Base Offset: 0x18
- Size: 0x4

|Bits|Identifier|Access| Reset|Name|
|----|----------|------|------|----|
|15:0|   busy   |  rw  |0x1000|  — |

#### busy field

<p>R/B# busy for more than this many units of 256 clk_nand clocks ends the command with code 2; 0 waits without limit.</p>

### CMD_ROW register

- Absolute Address: 0x6020
- Base Offset: 0x20
- Size: 0x4

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|23:0|    row   |  rw  | 0x0 |  — |

#### row field

<p>Row address: the page in bits 5:0, the block above.</p>

### CMD_COL register

- Absolute Address: 0x6024
- Base Offset: 0x24
- Size: 0x4

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|12:0|    col   |  rw  | 0x0 |  — |

#### col field

<p>Column: the byte in the page, 0 to 4319 (4096 to 4319 are the spare area). For READ_ID, the address byte.</p>

### CMD_LEN register

- Absolute Address: 0x6028
- Base Offset: 0x28
- Size: 0x4

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|12:0|    len   |  rw  | 0x0 |  — |

#### len field

<p>Bytes to move, 0 to 4320.</p>

### CMD_BUF register

- Absolute Address: 0x602C
- Base Offset: 0x2C
- Size: 0x4

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|12:0|    off   |  rw  | 0x0 |  — |

#### off field

<p>Byte offset of the data in the page buffer.</p>

### CMD_GO register

- Absolute Address: 0x6030
- Base Offset: 0x30
- Size: 0x4

<p>A write queues a command: OP, ECC and TAG with CMD_ROW, CMD_COL, CMD_LEN and CMD_BUF as they are then.</p>

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
| 2:0|    op    |  rw  | 0x0 |  — |
|  3 |    ecc   |  rw  | 0x0 |  — |
|15:8|    tag   |  rw  | 0x0 |  — |

#### op field

<p>0 RESET, 1 READ_ID, 2 READ, 3 PROGRAM, 4 ERASE, 5 STATUS, 6 CHANGE READ COLUMN; 7 completes at once with no bus cycle.</p>

#### ecc field

<p>With READ or PROGRAM: the whole page through the BCH code (docs/17_bch.md). The data (4096 bytes) and metadata (32) are at CMD_BUF; CMD_COL and CMD_LEN are not used.</p>

#### tag field

<p>Returned with the completion.</p>

### CPL register

- Absolute Address: 0x6034
- Base Offset: 0x34
- Size: 0x4

<p>The oldest completion; reading it removes it. VALID is 0 when none waits.</p>

| Bits|Identifier|Access|Reset|Name|
|-----|----------|------|-----|----|
| 7:0 |    tag   |   r  |  —  |  — |
| 10:8|   code   |   r  |  —  |  — |
|23:16|  status  |   r  |  —  |  — |
|  31 |   valid  |   r  |  —  |  — |

#### tag field

<p>TAG of the command.</p>

#### code field

<p>0 done, 1 status fail, 2 busy timeout, 3 write protected, 4 a codeword past correcting (CPL_ECC).</p>

#### status field

<p>The status byte read after a program, an erase or STATUS; 0 otherwise.</p>

### CYCLES register

- Absolute Address: 0x6038
- Base Offset: 0x38
- Size: 0x4

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|31:0|   count  |   r  |  —  |  — |

#### count field

<p>clk_sys clocks from the dispatch of the last completed command to its completion.</p>

### BUSY_TIME register

- Absolute Address: 0x603C
- Base Offset: 0x3C
- Size: 0x4

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|23:0|   count  |   r  |  —  |  — |

#### count field

<p>clk_nand clocks the last completed command waited for R/B# (saturates).</p>

### COUNT register

- Absolute Address: 0x6040
- Base Offset: 0x40
- Size: 0x4

| Bits|Identifier|Access|Reset|Name|
|-----|----------|------|-----|----|
| 15:0|   done   |   r  |  —  |  — |
|31:16|    err   |   r  |  —  |  — |

#### done field

<p>Commands completed (wraps).</p>

#### err field

<p>Of them, with a code other than 0 (wraps).</p>

### CPL_ECC register

- Absolute Address: 0x6044
- Base Offset: 0x44
- Size: 0x4

<p>The BCH result of the completion last read from CPL; 0 for a command without ECC.</p>

| Bits|Identifier|Access|Reset|Name|
|-----|----------|------|-----|----|
| 6:0 |   bits   |   r  |  —  |  — |
| 11:8|    max   |   r  |  —  |  — |
|23:16|    unc   |   r  |  —  |  — |
|31:24|  erased  |   r  |  —  |  — |

#### bits field

<p>Bits corrected in the page.</p>

#### max field

<p>The most bits corrected in one codeword, 0 to 8.</p>

#### unc field

<p>Codewords past correcting, one bit each; their data is as read.</p>

#### erased field

<p>Codewords read with at most 8 bits at 0: erased. They read as FFh, the 0 bits corrected.</p>

### ECC_COUNT register

- Absolute Address: 0x6048
- Base Offset: 0x48
- Size: 0x4

| Bits|Identifier|Access|Reset|Name|
|-----|----------|------|-----|----|
| 15:0|   bits   |   r  |  —  |  — |
|31:16|    unc   |   r  |  —  |  — |

#### bits field

<p>Bits corrected (wraps).</p>

#### unc field

<p>Codewords past correcting (wraps).</p>

## NAND1 address map

- Absolute Address: 0x7000
- Base Offset: 0x7000
- Size: 0x4C

<p>One NAND channel (rtl/nand/nand_ctrl.sv, docs/15_nand_channel.md): an 8-bit ONFI-style asynchronous interface run by a sequencer in clk_nand, a command queue of 4, a completion queue of 8, and an 8 KiB page buffer on the crossbar. NAND0 is at 0x4000_6000 with its page buffer at 0x3000_0000, NAND1 at 0x4000_7000 and 0x3001_0000.</p>

|Offset|Identifier|   Name  |
|------|----------|---------|
| 0x00 |   CTRL   |   CTRL  |
| 0x04 |  STATUS  |  STATUS |
| 0x08 |   EVENT  |  EVENT  |
| 0x10 |  TIMING0 | TIMING0 |
| 0x14 |  TIMING1 | TIMING1 |
| 0x18 |  TIMEOUT | TIMEOUT |
| 0x20 |  CMD_ROW | CMD_ROW |
| 0x24 |  CMD_COL | CMD_COL |
| 0x28 |  CMD_LEN | CMD_LEN |
| 0x2C |  CMD_BUF | CMD_BUF |
| 0x30 |  CMD_GO  |  CMD_GO |
| 0x34 |    CPL   |   CPL   |
| 0x38 |  CYCLES  |  CYCLES |
| 0x3C | BUSY_TIME|BUSY_TIME|
| 0x40 |   COUNT  |  COUNT  |
| 0x44 |  CPL_ECC | CPL_ECC |
| 0x48 | ECC_COUNT|ECC_COUNT|

### CTRL register

- Absolute Address: 0x7000
- Base Offset: 0x0
- Size: 0x4

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|  0 |    wp    |  rw  | 0x1 |  — |
|  1 | ien_done |  rw  | 0x0 |  — |
|  2 |  ien_err |  rw  | 0x0 |  — |

#### wp field

<p>Write protect: WP# is low while this is 1, from reset until firmware clears it.</p>

#### ien_done field

<p>Interrupt (INTC 6 for NAND0, 8 for NAND1) while a completion waits in CPL.</p>

#### ien_err field

<p>Interrupt (INTC 7 for NAND0, 9 for NAND1) while EVENT.ERR or EVENT.OVF is set.</p>

### STATUS register

- Absolute Address: 0x7004
- Base Offset: 0x4
- Size: 0x4

| Bits|Identifier|Access|Reset|Name|
|-----|----------|------|-----|----|
|  0  |   busy   |   r  |  —  |  — |
|  1  |    rb    |   r  |  —  |  — |
| 10:8|   cmds   |   r  |  —  |  — |
|15:12|   cpls   |   r  |  —  |  — |

#### busy field

<p>A command is running.</p>

#### rb field

<p>R/B#, synchronized into clk_sys: 1 ready, 0 busy.</p>

#### cmds field

<p>Commands waiting in the queue, 0 to 4.</p>

#### cpls field

<p>Completions waiting in CPL, 0 to 8.</p>

### EVENT register

- Absolute Address: 0x7008
- Base Offset: 0x8
- Size: 0x4

<p>Set by hardware, cleared by writing 1.</p>

|Bits|Identifier|  Access |Reset|Name|
|----|----------|---------|-----|----|
|  0 |    err   |rw, woclr| 0x0 |  — |
|  1 |    ovf   |rw, woclr| 0x0 |  — |

#### err field

<p>A command completed with a code other than 0.</p>

#### ovf field

<p>CMD_GO was written with 4 commands waiting; that command was dropped.</p>

### TIMING0 register

- Absolute Address: 0x7010
- Base Offset: 0x10
- Size: 0x4

<p>Bus cycle phases in clk_nand clocks (20 ns), 1 to 15; 0 counts as 1. A command takes TIMING0, TIMING1 and TIMEOUT as they are when it starts. The reset values give 100 ns cycles; 1 and 1 give 40 ns cycles, 25 MB/s.</p>

| Bits|Identifier|Access|Reset|Name|
|-----|----------|------|-----|----|
| 3:0 |    twp   |  rw  | 0x3 |  — |
| 7:4 |    twh   |  rw  | 0x2 |  — |
| 11:8|    trp   |  rw  | 0x3 |  — |
|15:12|   treh   |  rw  | 0x2 |  — |

#### twp field

<p>WE# low (tWP).</p>

#### twh field

<p>WE# high (tWH).</p>

#### trp field

<p>RE# low (tRP); DQ is sampled at the clock edge that raises RE#.</p>

#### treh field

<p>RE# high (tREH).</p>

### TIMING1 register

- Absolute Address: 0x7014
- Base Offset: 0x14
- Size: 0x4

<p>Waits in clk_nand clocks, 1 to 63; 0 counts as 1.</p>

| Bits|Identifier|Access|Reset|Name|
|-----|----------|------|-----|----|
| 5:0 |    twb   |  rw  | 0xC |  — |
| 13:8|   twhr   |  rw  | 0x6 |  — |
|21:16|   tadl   |  rw  | 0xA |  — |
|29:24|    trr   |  rw  | 0x2 |  — |

#### twb field

<p>From the confirm command's WE# rising to the first look at R/B# (tWB, plus 2 clocks of synchronizer).</p>

#### twhr field

<p>From the last WE# rising to RE# falling for a status, ID or changed-column read (tWHR).</p>

#### tadl field

<p>From the last address cycle to the first data cycle of a program (tADL).</p>

#### trr field

<p>From R/B# seen ready to the first RE# falling (tRR).</p>

### TIMEOUT register

- Absolute Address: 0x7018
- Base Offset: 0x18
- Size: 0x4

|Bits|Identifier|Access| Reset|Name|
|----|----------|------|------|----|
|15:0|   busy   |  rw  |0x1000|  — |

#### busy field

<p>R/B# busy for more than this many units of 256 clk_nand clocks ends the command with code 2; 0 waits without limit.</p>

### CMD_ROW register

- Absolute Address: 0x7020
- Base Offset: 0x20
- Size: 0x4

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|23:0|    row   |  rw  | 0x0 |  — |

#### row field

<p>Row address: the page in bits 5:0, the block above.</p>

### CMD_COL register

- Absolute Address: 0x7024
- Base Offset: 0x24
- Size: 0x4

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|12:0|    col   |  rw  | 0x0 |  — |

#### col field

<p>Column: the byte in the page, 0 to 4319 (4096 to 4319 are the spare area). For READ_ID, the address byte.</p>

### CMD_LEN register

- Absolute Address: 0x7028
- Base Offset: 0x28
- Size: 0x4

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|12:0|    len   |  rw  | 0x0 |  — |

#### len field

<p>Bytes to move, 0 to 4320.</p>

### CMD_BUF register

- Absolute Address: 0x702C
- Base Offset: 0x2C
- Size: 0x4

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|12:0|    off   |  rw  | 0x0 |  — |

#### off field

<p>Byte offset of the data in the page buffer.</p>

### CMD_GO register

- Absolute Address: 0x7030
- Base Offset: 0x30
- Size: 0x4

<p>A write queues a command: OP, ECC and TAG with CMD_ROW, CMD_COL, CMD_LEN and CMD_BUF as they are then.</p>

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
| 2:0|    op    |  rw  | 0x0 |  — |
|  3 |    ecc   |  rw  | 0x0 |  — |
|15:8|    tag   |  rw  | 0x0 |  — |

#### op field

<p>0 RESET, 1 READ_ID, 2 READ, 3 PROGRAM, 4 ERASE, 5 STATUS, 6 CHANGE READ COLUMN; 7 completes at once with no bus cycle.</p>

#### ecc field

<p>With READ or PROGRAM: the whole page through the BCH code (docs/17_bch.md). The data (4096 bytes) and metadata (32) are at CMD_BUF; CMD_COL and CMD_LEN are not used.</p>

#### tag field

<p>Returned with the completion.</p>

### CPL register

- Absolute Address: 0x7034
- Base Offset: 0x34
- Size: 0x4

<p>The oldest completion; reading it removes it. VALID is 0 when none waits.</p>

| Bits|Identifier|Access|Reset|Name|
|-----|----------|------|-----|----|
| 7:0 |    tag   |   r  |  —  |  — |
| 10:8|   code   |   r  |  —  |  — |
|23:16|  status  |   r  |  —  |  — |
|  31 |   valid  |   r  |  —  |  — |

#### tag field

<p>TAG of the command.</p>

#### code field

<p>0 done, 1 status fail, 2 busy timeout, 3 write protected, 4 a codeword past correcting (CPL_ECC).</p>

#### status field

<p>The status byte read after a program, an erase or STATUS; 0 otherwise.</p>

### CYCLES register

- Absolute Address: 0x7038
- Base Offset: 0x38
- Size: 0x4

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|31:0|   count  |   r  |  —  |  — |

#### count field

<p>clk_sys clocks from the dispatch of the last completed command to its completion.</p>

### BUSY_TIME register

- Absolute Address: 0x703C
- Base Offset: 0x3C
- Size: 0x4

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|23:0|   count  |   r  |  —  |  — |

#### count field

<p>clk_nand clocks the last completed command waited for R/B# (saturates).</p>

### COUNT register

- Absolute Address: 0x7040
- Base Offset: 0x40
- Size: 0x4

| Bits|Identifier|Access|Reset|Name|
|-----|----------|------|-----|----|
| 15:0|   done   |   r  |  —  |  — |
|31:16|    err   |   r  |  —  |  — |

#### done field

<p>Commands completed (wraps).</p>

#### err field

<p>Of them, with a code other than 0 (wraps).</p>

### CPL_ECC register

- Absolute Address: 0x7044
- Base Offset: 0x44
- Size: 0x4

<p>The BCH result of the completion last read from CPL; 0 for a command without ECC.</p>

| Bits|Identifier|Access|Reset|Name|
|-----|----------|------|-----|----|
| 6:0 |   bits   |   r  |  —  |  — |
| 11:8|    max   |   r  |  —  |  — |
|23:16|    unc   |   r  |  —  |  — |
|31:24|  erased  |   r  |  —  |  — |

#### bits field

<p>Bits corrected in the page.</p>

#### max field

<p>The most bits corrected in one codeword, 0 to 8.</p>

#### unc field

<p>Codewords past correcting, one bit each; their data is as read.</p>

#### erased field

<p>Codewords read with at most 8 bits at 0: erased. They read as FFh, the 0 bits corrected.</p>

### ECC_COUNT register

- Absolute Address: 0x7048
- Base Offset: 0x48
- Size: 0x4

| Bits|Identifier|Access|Reset|Name|
|-----|----------|------|-----|----|
| 15:0|   bits   |   r  |  —  |  — |
|31:16|    unc   |   r  |  —  |  — |

#### bits field

<p>Bits corrected (wraps).</p>

#### unc field

<p>Codewords past correcting (wraps).</p>

## NVME address map

- Absolute Address: 0x8000
- Base Offset: 0x8000
- Size: 0x234

<p>Firmware side of the NVMe controller (rtl/host/nvme/nvme_ctrl.sv, docs/11_nvme_queues.md, docs/12_nvme_data.md, docs/14_nvme_host_verification.md). The host side (CAP, CC, CSTS, AQA, ASQ, ACQ, doorbells) is in BAR0 and is mirrored here read-only. The epoch counts controller resets: CMD gives the epoch a command was fetched in, and a transfer start (XF_CTRL), a completion post (CQE_CTRL) or an I/O queue enable (SQ_CFG, CQ_CFG) carrying another epoch does nothing.</p>

|Offset|Identifier|   Name   |
|------|----------|----------|
| 0x000|   CTRL   |   CTRL   |
| 0x004|  STATUS  |  STATUS  |
| 0x008|   EVENT  |   EVENT  |
| 0x00C| EVENT_EN | EVENT_EN |
| 0x010|    CC    |    CC    |
| 0x014|  CMDBUF  |  CMDBUF  |
| 0x018|    CMD   |    CMD   |
| 0x01C| SLOT_FREE| SLOT_FREE|
| 0x020|  DB_ERR  |  DB_ERR  |
| 0x024|  FETCHES |  FETCHES |
| 0x030|    AQA   |    AQA   |
| 0x034|  ASQ_LO  |  ASQ_LO  |
| 0x038|  ASQ_HI  |  ASQ_HI  |
| 0x03C|  ACQ_LO  |  ACQ_LO  |
| 0x040|  ACQ_HI  |  ACQ_HI  |
| 0x050|XF_PRP1_LO|XF_PRP1_LO|
| 0x054|XF_PRP1_HI|XF_PRP1_HI|
| 0x058|XF_PRP2_LO|XF_PRP2_LO|
| 0x05C|XF_PRP2_HI|XF_PRP2_HI|
| 0x060| XF_LADDR | XF_LADDR |
| 0x064|  XF_LEN  |  XF_LEN  |
| 0x068|  XF_CTRL |  XF_CTRL |
| 0x06C| XF_STATUS| XF_STATUS|
| 0x070| XF_CYCLES| XF_CYCLES|
| 0x080|  CQE_DW0 |  CQE_DW0 |
| 0x084| CQE_INFO | CQE_INFO |
| 0x088| CQE_CTRL | CQE_CTRL |
| 0x08C|CQE_STATUS|CQE_STATUS|
| 0x090|   CQES   |   CQES   |
| 0x094|   STALE  |   STALE  |
| 0x100|  IOQ[0]  |     —    |
| 0x120|  IOQ[1]  |     —    |
| 0x140|  IOQ[2]  |     —    |
| 0x160|  IOQ[3]  |     —    |
| 0x200| SQ_PTR[0]|  SQ_PTR  |
| 0x204| SQ_PTR[1]|  SQ_PTR  |
| 0x208| SQ_PTR[2]|  SQ_PTR  |
| 0x20C| SQ_PTR[3]|  SQ_PTR  |
| 0x210| SQ_PTR[4]|  SQ_PTR  |
| 0x220| CQ_PTR[0]|  CQ_PTR  |
| 0x224| CQ_PTR[1]|  CQ_PTR  |
| 0x228| CQ_PTR[2]|  CQ_PTR  |
| 0x22C| CQ_PTR[3]|  CQ_PTR  |
| 0x230| CQ_PTR[4]|  CQ_PTR  |

### CTRL register

- Absolute Address: 0x8000
- Base Offset: 0x0
- Size: 0x4

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|  0 |  ien_cmd |  rw  | 0x0 |  — |
|  1 | ien_xfer |  rw  | 0x0 |  — |

#### ien_cmd field

<p>Interrupt (INTC source 3) while commands wait in CMD.</p>

#### ien_xfer field

<p>Interrupt (INTC source 3) while XF_STATUS.DONE or ERR is set.</p>

### STATUS register

- Absolute Address: 0x8004
- Base Offset: 0x4
- Size: 0x4

| Bits|Identifier|Access|Reset|Name|
|-----|----------|------|-----|----|
|  0  |    rdy   |   r  |  —  |  — |
|  1  |    cfs   |   r  |  —  |  — |
|  2  |    en    |   r  |  —  |  — |
| 5:4 |   shst   |   r  |  —  |  — |
| 12:8|   cmds   |   r  |  —  |  — |
|20:16|   free   |   r  |  —  |  — |
|27:24|   epoch  |   r  |  —  |  — |

#### rdy field

<p>CSTS.RDY.</p>

#### cfs field

<p>CSTS.CFS: a command fetch failed.</p>

#### en field

<p>CC.EN.</p>

#### shst field

<p>CSTS.SHST.</p>

#### cmds field

<p>Commands waiting in CMD.</p>

#### free field

<p>Free command buffer slots.</p>

#### epoch field

<p>Epoch: controller resets since power-on, modulo 16.</p>

### EVENT register

- Absolute Address: 0x8008
- Base Offset: 0x8
- Size: 0x4

<p>Controller events, set by hardware and cleared by writing 1. EVENT AND EVENT_EN is INTC source 3, with CTRL.IEN_CMD.</p>

|Bits|Identifier|  Access |Reset|Name|
|----|----------|---------|-----|----|
|  0 |  enable  |rw, woclr| 0x0 |  — |
|  1 |   reset  |rw, woclr| 0x0 |  — |
|  2 | shutdown |rw, woclr| 0x0 |  — |
|  3 |  db_err  |rw, woclr| 0x0 |  — |
|  4 | fetch_err|rw, woclr| 0x0 |  — |
|  5 |  cqe_err |rw, woclr| 0x0 |  — |

#### enable field

<p>The host enabled the controller (CC.EN 0 to 1); the admin queue is loaded and CSTS.RDY is 1.</p>

#### reset field

<p>A controller reset (CC.EN 1 to 0) finished: queues deleted, commands dropped, CSTS.RDY 0.</p>

#### shutdown field

<p>The host requested a shutdown (CC.SHN).</p>

#### db_err field

<p>A doorbell write was ignored; see DB_ERR.</p>

#### fetch_err field

<p>A command fetch failed; CSTS.CFS is set.</p>

#### cqe_err field

<p>A completion queue entry was dropped (posted while 4 wait, or to a completion queue that is not enabled) or its write to the host failed (CSTS.CFS is set); see CQE_STATUS.</p>

### EVENT_EN register

- Absolute Address: 0x800C
- Base Offset: 0xC
- Size: 0x4

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
| 5:0|    en    |  rw  | 0x0 |  — |

### CC register

- Absolute Address: 0x8010
- Base Offset: 0x10
- Size: 0x4

<p>The host's Controller Configuration.</p>

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|31:0|   value  |   r  |  —  |  — |

### CMDBUF register

- Absolute Address: 0x8014
- Base Offset: 0x14
- Size: 0x4

<p>SRAM address of the command buffer: 16 slots of 64 bytes, 1 KiB aligned.</p>

| Bits|Identifier|Access| Reset |Name|
|-----|----------|------|-------|----|
|31:10|   base   |  rw  |0x4002F|  — |

### CMD register

- Absolute Address: 0x8018
- Base Offset: 0x18
- Size: 0x4

<p>Oldest fetched command; reading it removes it. VALID 0 when none waits. The command is at CMDBUF + 64 x SLOT until SLOT_FREE returns the slot.</p>

| Bits|Identifier|Access|Reset|Name|
|-----|----------|------|-----|----|
| 3:0 |   slot   |   r  |  —  |  — |
|18:16|   sqid   |   r  |  —  |  — |
|27:24|   epoch  |   r  |  —  |  — |
|  31 |   valid  |   r  |  —  |  — |

#### sqid field

<p>Submission queue it came from.</p>

#### epoch field

<p>Epoch it was fetched in; firmware writes it back with the command's transfer and completion.</p>

### SLOT_FREE register

- Absolute Address: 0x801C
- Base Offset: 0x1C
- Size: 0x4

<p>A write returns the slot it names to the free list, if EPOCH is the controller's and the controller is on (a controller reset has freed every slot already).</p>

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
| 3:0|   slot   |   w  | 0x0 |  — |
| 7:4|   epoch  |   w  | 0x0 |  — |

#### epoch field

<p>The command's epoch (CMD.EPOCH).</p>

### DB_ERR register

- Absolute Address: 0x8020
- Base Offset: 0x20
- Size: 0x4

<p>The last doorbell write that was ignored: to a queue that is not enabled, or a value not below the queue size.</p>

| Bits|Identifier|Access|Reset|Name|
|-----|----------|------|-----|----|
| 2:0 |    qid   |   r  | 0x0 |  — |
|  3  |    cq    |   r  | 0x0 |  — |
|31:16|   value  |   r  | 0x0 |  — |

#### qid field

<p>Queue ID.</p>

#### cq field

<p>1: completion queue head doorbell; 0: submission queue tail doorbell.</p>

#### value field

<p>Value written.</p>

### FETCHES register

- Absolute Address: 0x8024
- Base Offset: 0x24
- Size: 0x4

<p>Commands fetched since reset (wraps).</p>

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|31:0|   count  |   r  |  —  |  — |

### AQA register

- Absolute Address: 0x8030
- Base Offset: 0x30
- Size: 0x4

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|31:0|   value  |   r  |  —  |  — |

#### value field

<p>The host's Admin Queue Attributes.</p>

### ASQ_LO register

- Absolute Address: 0x8034
- Base Offset: 0x34
- Size: 0x4

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|31:0|   value  |   r  |  —  |  — |

#### value field

<p>Admin Submission Queue base, bits 31:0.</p>

### ASQ_HI register

- Absolute Address: 0x8038
- Base Offset: 0x38
- Size: 0x4

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|31:0|   value  |   r  |  —  |  — |

### ACQ_LO register

- Absolute Address: 0x803C
- Base Offset: 0x3C
- Size: 0x4

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|31:0|   value  |   r  |  —  |  — |

#### value field

<p>Admin Completion Queue base, bits 31:0.</p>

### ACQ_HI register

- Absolute Address: 0x8040
- Base Offset: 0x40
- Size: 0x4

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|31:0|   value  |   r  |  —  |  — |

### XF_PRP1_LO register

- Absolute Address: 0x8050
- Base Offset: 0x50
- Size: 0x4

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|31:0|   value  |  rw  | 0x0 |  — |

#### value field

<p>PRP entry 1, bits 31:0: the first page and the offset in it, DW aligned.</p>

### XF_PRP1_HI register

- Absolute Address: 0x8054
- Base Offset: 0x54
- Size: 0x4

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|31:0|   value  |  rw  | 0x0 |  — |

### XF_PRP2_LO register

- Absolute Address: 0x8058
- Base Offset: 0x58
- Size: 0x4

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|31:0|   value  |  rw  | 0x0 |  — |

#### value field

<p>PRP entry 2, bits 31:0: the second page (page aligned) when the data spans two pages, or a PRP list pointer (8-byte aligned) when it spans more.</p>

### XF_PRP2_HI register

- Absolute Address: 0x805C
- Base Offset: 0x5C
- Size: 0x4

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|31:0|   value  |  rw  | 0x0 |  — |

### XF_LADDR register

- Absolute Address: 0x8060
- Base Offset: 0x60
- Size: 0x4

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|31:2|   addr   |  rw  | 0x0 |  — |

#### addr field

<p>SRAM address of the data, contiguous there.</p>

### XF_LEN register

- Absolute Address: 0x8064
- Base Offset: 0x64
- Size: 0x4

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|17:2|   bytes  |  rw  | 0x0 |  — |

#### bytes field

<p>Length in bytes, a multiple of 4, 4 to 128 KiB.</p>

### XF_CTRL register

- Absolute Address: 0x8068
- Base Offset: 0x68
- Size: 0x4

<p>START while XF_STATUS.BUSY is ignored.</p>

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|  0 |   start  |   w  | 0x0 |  — |
|  1 |    d2h   |  rw  | 0x0 |  — |
| 7:4|   epoch  |  rw  | 0x0 |  — |

#### start field

<p>Start the transfer.</p>

#### d2h field

<p>1: SRAM to host (a read command); 0: host to SRAM (a write command).</p>

#### epoch field

<p>The command's epoch (CMD.EPOCH). A START with another epoch, or while the controller is not on, moves nothing and ends with ERR, cause 11.</p>

### XF_STATUS register

- Absolute Address: 0x806C
- Base Offset: 0x6C
- Size: 0x4

<p>DONE or ERR is INTC source 3 with CTRL.IEN_XFER. Write 1 to clear; START clears both.</p>

|Bits|Identifier|  Access |Reset|Name|
|----|----------|---------|-----|----|
|  0 |   busy   |    r    |  —  |  — |
|  1 |   done   |rw, woclr| 0x0 |  — |
|  2 |    err   |rw, woclr| 0x0 |  — |
|11:8|   cause  |    r    | 0x0 |  — |

#### cause field

<p>Why the transfer failed: 1 to 7 the bus master's cause, 8 a length out of range, 9 a PRP entry with a bad offset, 10 aborted by a controller reset, 11 not started: stale epoch or controller not on.</p>

### XF_CYCLES register

- Absolute Address: 0x8070
- Base Offset: 0x70
- Size: 0x4

<p>Clocks from START to the end of the last transfer.</p>

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|31:0|   count  |   r  |  —  |  — |

### CQE_DW0 register

- Absolute Address: 0x8080
- Base Offset: 0x80
- Size: 0x4

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|31:0|   value  |  rw  | 0x0 |  — |

#### value field

<p>Command specific DW0 of the entry.</p>

### CQE_INFO register

- Absolute Address: 0x8084
- Base Offset: 0x84
- Size: 0x4

| Bits|Identifier|Access|Reset|Name|
|-----|----------|------|-----|----|
| 15:0|    cid   |  rw  | 0x0 |  — |
|18:16|   sqid   |  rw  | 0x0 |  — |

#### cid field

<p>Command identifier.</p>

#### sqid field

<p>Submission queue the command came from; the entry carries its head.</p>

### CQE_CTRL register

- Absolute Address: 0x8088
- Base Offset: 0x88
- Size: 0x4

<p>A write queues the entry.</p>

| Bits|Identifier|Access|Reset|Name|
|-----|----------|------|-----|----|
| 2:0 |   cqid   |  rw  | 0x0 |  — |
| 7:4 |   epoch  |  rw  | 0x0 |  — |
|31:17|  status  |  rw  | 0x0 |  — |

#### cqid field

<p>Completion queue, 0 to 4.</p>

#### epoch field

<p>The command's epoch (CMD.EPOCH). A post with another epoch, or while the controller is not on, is discarded (CQE_STATUS.STALE).</p>

#### status field

<p>Status field of DW3 (bits 31:17: SC, SCT, CRD, M, DNR); 0 for success.</p>

### CQE_STATUS register

- Absolute Address: 0x808C
- Base Offset: 0x8C
- Size: 0x4

|Bits|Identifier|  Access |Reset|Name|
|----|----------|---------|-----|----|
| 2:0|   count  |    r    |  —  |  — |
|  4 |   full   |    r    |  —  |  — |
|  5 |  cq_full |    r    |  —  |  — |
|  8 |   drop   |rw, woclr| 0x0 |  — |
|  9 |   werr   |rw, woclr| 0x0 |  — |
| 10 |   stale  |rw, woclr| 0x0 |  — |

#### count field

<p>Entries waiting to be written.</p>

#### full field

<p>4 entries wait: a post now is dropped.</p>

#### cq_full field

<p>The oldest entry waits for room in its completion queue.</p>

#### drop field

<p>An entry was dropped: posted while 4 waited, or to a completion queue that is not enabled.</p>

#### werr field

<p>An entry's write to the host failed.</p>

#### stale field

<p>A post was discarded: its epoch was not the controller's, or the controller was not on. Not an error: the command was dropped by a controller reset.</p>

### CQES register

- Absolute Address: 0x8090
- Base Offset: 0x90
- Size: 0x4

<p>Completion queue entries written since reset (wraps).</p>

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|31:0|   count  |   r  |  —  |  — |

### STALE register

- Absolute Address: 0x8094
- Base Offset: 0x94
- Size: 0x4

<p>Firmware actions refused for a stale epoch or with the controller not on, since power-on (each count wraps).</p>

| Bits|Identifier|Access|Reset|Name|
|-----|----------|------|-----|----|
| 15:0|    cqe   |   r  |  —  |  — |
|31:16|    xf    |   r  |  —  |  — |

#### cqe field

<p>Completion posts discarded.</p>

#### xf field

<p>Transfer starts refused.</p>

## IOQ register file

- Absolute Address: 0x8100
- Base Offset: 0x100
- Size: 0x18
- Array Dimensions: [4]
- Array Stride: 0x20
- Total Size: 0x80

|Offset|Identifier| Name |
|------|----------|------|
| 0x00 |  SQB_LO  |SQB_LO|
| 0x04 |  SQB_HI  |SQB_HI|
| 0x08 |  SQ_CFG  |SQ_CFG|
| 0x0C |  CQB_LO  |CQB_LO|
| 0x10 |  CQB_HI  |CQB_HI|
| 0x14 |  CQ_CFG  |CQ_CFG|

### SQB_LO register

- Absolute Address: 0x8100
- Base Offset: 0x0
- Size: 0x4

| Bits|Identifier|Access|Reset|Name|
|-----|----------|------|-----|----|
|31:12|   base   |  rw  | 0x0 |  — |

#### base field

<p>Submission queue base, bits 31:12.</p>

### SQB_HI register

- Absolute Address: 0x8104
- Base Offset: 0x4
- Size: 0x4

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|31:0|   base   |  rw  | 0x0 |  — |

### SQ_CFG register

- Absolute Address: 0x8108
- Base Offset: 0x8
- Size: 0x4

| Bits|Identifier|Access|Reset|Name|
|-----|----------|------|-----|----|
| 11:0|   size   |  rw  | 0x0 |  — |
|18:16|   cqid   |  rw  | 0x0 |  — |
|29:26|   epoch  |  rw  | 0x0 |  — |
|  31 |    en    |  rw  | 0x0 |  — |

#### size field

<p>Entries - 1.</p>

#### cqid field

<p>Completion queue for this submission queue.</p>

#### epoch field

<p>Epoch of the command that created the queue; the queue is enabled only while it is the controller's.</p>

#### en field

<p>Queue enabled; enabling sets its head and tail to 0.</p>

### CQB_LO register

- Absolute Address: 0x810C
- Base Offset: 0xC
- Size: 0x4

| Bits|Identifier|Access|Reset|Name|
|-----|----------|------|-----|----|
|31:12|   base   |  rw  | 0x0 |  — |

#### base field

<p>Completion queue base, bits 31:12.</p>

### CQB_HI register

- Absolute Address: 0x8110
- Base Offset: 0x10
- Size: 0x4

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|31:0|   base   |  rw  | 0x0 |  — |

### CQ_CFG register

- Absolute Address: 0x8114
- Base Offset: 0x14
- Size: 0x4

| Bits|Identifier|Access|Reset|Name|
|-----|----------|------|-----|----|
| 11:0|   size   |  rw  | 0x0 |  — |
|18:16|    iv    |  rw  | 0x0 |  — |
|  24 |    ien   |  rw  | 0x0 |  — |
|29:26|   epoch  |  rw  | 0x0 |  — |
|  31 |    en    |  rw  | 0x0 |  — |

#### size field

<p>Entries - 1.</p>

#### iv field

<p>MSI-X vector.</p>

#### ien field

<p>Interrupts enabled.</p>

#### epoch field

<p>Epoch of the command that created the queue; the queue is enabled only while it is the controller's.</p>

#### en field

<p>Queue enabled; enabling sets head and tail to 0 and the phase to 1.</p>

## IOQ register file

- Absolute Address: 0x8120
- Base Offset: 0x100
- Size: 0x18
- Array Dimensions: [4]
- Array Stride: 0x20
- Total Size: 0x80

|Offset|Identifier| Name |
|------|----------|------|
| 0x00 |  SQB_LO  |SQB_LO|
| 0x04 |  SQB_HI  |SQB_HI|
| 0x08 |  SQ_CFG  |SQ_CFG|
| 0x0C |  CQB_LO  |CQB_LO|
| 0x10 |  CQB_HI  |CQB_HI|
| 0x14 |  CQ_CFG  |CQ_CFG|

### SQB_LO register

- Absolute Address: 0x8120
- Base Offset: 0x0
- Size: 0x4

| Bits|Identifier|Access|Reset|Name|
|-----|----------|------|-----|----|
|31:12|   base   |  rw  | 0x0 |  — |

#### base field

<p>Submission queue base, bits 31:12.</p>

### SQB_HI register

- Absolute Address: 0x8124
- Base Offset: 0x4
- Size: 0x4

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|31:0|   base   |  rw  | 0x0 |  — |

### SQ_CFG register

- Absolute Address: 0x8128
- Base Offset: 0x8
- Size: 0x4

| Bits|Identifier|Access|Reset|Name|
|-----|----------|------|-----|----|
| 11:0|   size   |  rw  | 0x0 |  — |
|18:16|   cqid   |  rw  | 0x0 |  — |
|29:26|   epoch  |  rw  | 0x0 |  — |
|  31 |    en    |  rw  | 0x0 |  — |

#### size field

<p>Entries - 1.</p>

#### cqid field

<p>Completion queue for this submission queue.</p>

#### epoch field

<p>Epoch of the command that created the queue; the queue is enabled only while it is the controller's.</p>

#### en field

<p>Queue enabled; enabling sets its head and tail to 0.</p>

### CQB_LO register

- Absolute Address: 0x812C
- Base Offset: 0xC
- Size: 0x4

| Bits|Identifier|Access|Reset|Name|
|-----|----------|------|-----|----|
|31:12|   base   |  rw  | 0x0 |  — |

#### base field

<p>Completion queue base, bits 31:12.</p>

### CQB_HI register

- Absolute Address: 0x8130
- Base Offset: 0x10
- Size: 0x4

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|31:0|   base   |  rw  | 0x0 |  — |

### CQ_CFG register

- Absolute Address: 0x8134
- Base Offset: 0x14
- Size: 0x4

| Bits|Identifier|Access|Reset|Name|
|-----|----------|------|-----|----|
| 11:0|   size   |  rw  | 0x0 |  — |
|18:16|    iv    |  rw  | 0x0 |  — |
|  24 |    ien   |  rw  | 0x0 |  — |
|29:26|   epoch  |  rw  | 0x0 |  — |
|  31 |    en    |  rw  | 0x0 |  — |

#### size field

<p>Entries - 1.</p>

#### iv field

<p>MSI-X vector.</p>

#### ien field

<p>Interrupts enabled.</p>

#### epoch field

<p>Epoch of the command that created the queue; the queue is enabled only while it is the controller's.</p>

#### en field

<p>Queue enabled; enabling sets head and tail to 0 and the phase to 1.</p>

## IOQ register file

- Absolute Address: 0x8140
- Base Offset: 0x100
- Size: 0x18
- Array Dimensions: [4]
- Array Stride: 0x20
- Total Size: 0x80

|Offset|Identifier| Name |
|------|----------|------|
| 0x00 |  SQB_LO  |SQB_LO|
| 0x04 |  SQB_HI  |SQB_HI|
| 0x08 |  SQ_CFG  |SQ_CFG|
| 0x0C |  CQB_LO  |CQB_LO|
| 0x10 |  CQB_HI  |CQB_HI|
| 0x14 |  CQ_CFG  |CQ_CFG|

### SQB_LO register

- Absolute Address: 0x8140
- Base Offset: 0x0
- Size: 0x4

| Bits|Identifier|Access|Reset|Name|
|-----|----------|------|-----|----|
|31:12|   base   |  rw  | 0x0 |  — |

#### base field

<p>Submission queue base, bits 31:12.</p>

### SQB_HI register

- Absolute Address: 0x8144
- Base Offset: 0x4
- Size: 0x4

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|31:0|   base   |  rw  | 0x0 |  — |

### SQ_CFG register

- Absolute Address: 0x8148
- Base Offset: 0x8
- Size: 0x4

| Bits|Identifier|Access|Reset|Name|
|-----|----------|------|-----|----|
| 11:0|   size   |  rw  | 0x0 |  — |
|18:16|   cqid   |  rw  | 0x0 |  — |
|29:26|   epoch  |  rw  | 0x0 |  — |
|  31 |    en    |  rw  | 0x0 |  — |

#### size field

<p>Entries - 1.</p>

#### cqid field

<p>Completion queue for this submission queue.</p>

#### epoch field

<p>Epoch of the command that created the queue; the queue is enabled only while it is the controller's.</p>

#### en field

<p>Queue enabled; enabling sets its head and tail to 0.</p>

### CQB_LO register

- Absolute Address: 0x814C
- Base Offset: 0xC
- Size: 0x4

| Bits|Identifier|Access|Reset|Name|
|-----|----------|------|-----|----|
|31:12|   base   |  rw  | 0x0 |  — |

#### base field

<p>Completion queue base, bits 31:12.</p>

### CQB_HI register

- Absolute Address: 0x8150
- Base Offset: 0x10
- Size: 0x4

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|31:0|   base   |  rw  | 0x0 |  — |

### CQ_CFG register

- Absolute Address: 0x8154
- Base Offset: 0x14
- Size: 0x4

| Bits|Identifier|Access|Reset|Name|
|-----|----------|------|-----|----|
| 11:0|   size   |  rw  | 0x0 |  — |
|18:16|    iv    |  rw  | 0x0 |  — |
|  24 |    ien   |  rw  | 0x0 |  — |
|29:26|   epoch  |  rw  | 0x0 |  — |
|  31 |    en    |  rw  | 0x0 |  — |

#### size field

<p>Entries - 1.</p>

#### iv field

<p>MSI-X vector.</p>

#### ien field

<p>Interrupts enabled.</p>

#### epoch field

<p>Epoch of the command that created the queue; the queue is enabled only while it is the controller's.</p>

#### en field

<p>Queue enabled; enabling sets head and tail to 0 and the phase to 1.</p>

## IOQ register file

- Absolute Address: 0x8160
- Base Offset: 0x100
- Size: 0x18
- Array Dimensions: [4]
- Array Stride: 0x20
- Total Size: 0x80

|Offset|Identifier| Name |
|------|----------|------|
| 0x00 |  SQB_LO  |SQB_LO|
| 0x04 |  SQB_HI  |SQB_HI|
| 0x08 |  SQ_CFG  |SQ_CFG|
| 0x0C |  CQB_LO  |CQB_LO|
| 0x10 |  CQB_HI  |CQB_HI|
| 0x14 |  CQ_CFG  |CQ_CFG|

### SQB_LO register

- Absolute Address: 0x8160
- Base Offset: 0x0
- Size: 0x4

| Bits|Identifier|Access|Reset|Name|
|-----|----------|------|-----|----|
|31:12|   base   |  rw  | 0x0 |  — |

#### base field

<p>Submission queue base, bits 31:12.</p>

### SQB_HI register

- Absolute Address: 0x8164
- Base Offset: 0x4
- Size: 0x4

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|31:0|   base   |  rw  | 0x0 |  — |

### SQ_CFG register

- Absolute Address: 0x8168
- Base Offset: 0x8
- Size: 0x4

| Bits|Identifier|Access|Reset|Name|
|-----|----------|------|-----|----|
| 11:0|   size   |  rw  | 0x0 |  — |
|18:16|   cqid   |  rw  | 0x0 |  — |
|29:26|   epoch  |  rw  | 0x0 |  — |
|  31 |    en    |  rw  | 0x0 |  — |

#### size field

<p>Entries - 1.</p>

#### cqid field

<p>Completion queue for this submission queue.</p>

#### epoch field

<p>Epoch of the command that created the queue; the queue is enabled only while it is the controller's.</p>

#### en field

<p>Queue enabled; enabling sets its head and tail to 0.</p>

### CQB_LO register

- Absolute Address: 0x816C
- Base Offset: 0xC
- Size: 0x4

| Bits|Identifier|Access|Reset|Name|
|-----|----------|------|-----|----|
|31:12|   base   |  rw  | 0x0 |  — |

#### base field

<p>Completion queue base, bits 31:12.</p>

### CQB_HI register

- Absolute Address: 0x8170
- Base Offset: 0x10
- Size: 0x4

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|31:0|   base   |  rw  | 0x0 |  — |

### CQ_CFG register

- Absolute Address: 0x8174
- Base Offset: 0x14
- Size: 0x4

| Bits|Identifier|Access|Reset|Name|
|-----|----------|------|-----|----|
| 11:0|   size   |  rw  | 0x0 |  — |
|18:16|    iv    |  rw  | 0x0 |  — |
|  24 |    ien   |  rw  | 0x0 |  — |
|29:26|   epoch  |  rw  | 0x0 |  — |
|  31 |    en    |  rw  | 0x0 |  — |

#### size field

<p>Entries - 1.</p>

#### iv field

<p>MSI-X vector.</p>

#### ien field

<p>Interrupts enabled.</p>

#### epoch field

<p>Epoch of the command that created the queue; the queue is enabled only while it is the controller's.</p>

#### en field

<p>Queue enabled; enabling sets head and tail to 0 and the phase to 1.</p>

### SQ_PTR register

- Absolute Address: 0x8200
- Base Offset: 0x200
- Size: 0x4
- Array Dimensions: [5]
- Array Stride: 0x4
- Total Size: 0x14

<p>Submission queue 0 to 4: head (next entry to fetch) and tail (last doorbell).</p>

| Bits|Identifier|Access|Reset|Name|
|-----|----------|------|-----|----|
| 11:0|   head   |   r  |  —  |  — |
|27:16|   tail   |   r  |  —  |  — |

### SQ_PTR register

- Absolute Address: 0x8204
- Base Offset: 0x200
- Size: 0x4
- Array Dimensions: [5]
- Array Stride: 0x4
- Total Size: 0x14

<p>Submission queue 0 to 4: head (next entry to fetch) and tail (last doorbell).</p>

| Bits|Identifier|Access|Reset|Name|
|-----|----------|------|-----|----|
| 11:0|   head   |   r  |  —  |  — |
|27:16|   tail   |   r  |  —  |  — |

### SQ_PTR register

- Absolute Address: 0x8208
- Base Offset: 0x200
- Size: 0x4
- Array Dimensions: [5]
- Array Stride: 0x4
- Total Size: 0x14

<p>Submission queue 0 to 4: head (next entry to fetch) and tail (last doorbell).</p>

| Bits|Identifier|Access|Reset|Name|
|-----|----------|------|-----|----|
| 11:0|   head   |   r  |  —  |  — |
|27:16|   tail   |   r  |  —  |  — |

### SQ_PTR register

- Absolute Address: 0x820C
- Base Offset: 0x200
- Size: 0x4
- Array Dimensions: [5]
- Array Stride: 0x4
- Total Size: 0x14

<p>Submission queue 0 to 4: head (next entry to fetch) and tail (last doorbell).</p>

| Bits|Identifier|Access|Reset|Name|
|-----|----------|------|-----|----|
| 11:0|   head   |   r  |  —  |  — |
|27:16|   tail   |   r  |  —  |  — |

### SQ_PTR register

- Absolute Address: 0x8210
- Base Offset: 0x200
- Size: 0x4
- Array Dimensions: [5]
- Array Stride: 0x4
- Total Size: 0x14

<p>Submission queue 0 to 4: head (next entry to fetch) and tail (last doorbell).</p>

| Bits|Identifier|Access|Reset|Name|
|-----|----------|------|-----|----|
| 11:0|   head   |   r  |  —  |  — |
|27:16|   tail   |   r  |  —  |  — |

### CQ_PTR register

- Absolute Address: 0x8220
- Base Offset: 0x220
- Size: 0x4
- Array Dimensions: [5]
- Array Stride: 0x4
- Total Size: 0x14

<p>Completion queue 0 to 4: head (last doorbell), tail (next entry to write) and phase.</p>

| Bits|Identifier|Access|Reset|Name|
|-----|----------|------|-----|----|
| 11:0|   head   |   r  |  —  |  — |
|27:16|   tail   |   r  |  —  |  — |
|  31 |   phase  |   r  |  —  |  — |

### CQ_PTR register

- Absolute Address: 0x8224
- Base Offset: 0x220
- Size: 0x4
- Array Dimensions: [5]
- Array Stride: 0x4
- Total Size: 0x14

<p>Completion queue 0 to 4: head (last doorbell), tail (next entry to write) and phase.</p>

| Bits|Identifier|Access|Reset|Name|
|-----|----------|------|-----|----|
| 11:0|   head   |   r  |  —  |  — |
|27:16|   tail   |   r  |  —  |  — |
|  31 |   phase  |   r  |  —  |  — |

### CQ_PTR register

- Absolute Address: 0x8228
- Base Offset: 0x220
- Size: 0x4
- Array Dimensions: [5]
- Array Stride: 0x4
- Total Size: 0x14

<p>Completion queue 0 to 4: head (last doorbell), tail (next entry to write) and phase.</p>

| Bits|Identifier|Access|Reset|Name|
|-----|----------|------|-----|----|
| 11:0|   head   |   r  |  —  |  — |
|27:16|   tail   |   r  |  —  |  — |
|  31 |   phase  |   r  |  —  |  — |

### CQ_PTR register

- Absolute Address: 0x822C
- Base Offset: 0x220
- Size: 0x4
- Array Dimensions: [5]
- Array Stride: 0x4
- Total Size: 0x14

<p>Completion queue 0 to 4: head (last doorbell), tail (next entry to write) and phase.</p>

| Bits|Identifier|Access|Reset|Name|
|-----|----------|------|-----|----|
| 11:0|   head   |   r  |  —  |  — |
|27:16|   tail   |   r  |  —  |  — |
|  31 |   phase  |   r  |  —  |  — |

### CQ_PTR register

- Absolute Address: 0x8230
- Base Offset: 0x220
- Size: 0x4
- Array Dimensions: [5]
- Array Stride: 0x4
- Total Size: 0x14

<p>Completion queue 0 to 4: head (last doorbell), tail (next entry to write) and phase.</p>

| Bits|Identifier|Access|Reset|Name|
|-----|----------|------|-----|----|
| 11:0|   head   |   r  |  —  |  — |
|27:16|   tail   |   r  |  —  |  — |
|  31 |   phase  |   r  |  —  |  — |
