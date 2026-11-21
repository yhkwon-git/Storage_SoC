<!---
Markdown description for SystemRDL register map.

Don't override. Generated from: soc_apb
  - rtl/csr/rdl/soc_apb.rdl
-->

## soc_apb address map

- Absolute Address: 0x0
- Base Offset: 0x0
- Size: 0x500C

<p>Register blocks in the APB window at 0x4000_0000, one 4 KiB slot each.</p>

|Offset|Identifier| Name|
|------|----------|-----|
|0x0000|    SYS   | SYS |
|0x1000|    PMU   | PMU |
|0x2000|   INTC   | INTC|
|0x3000|   TIMER  |TIMER|
|0x4000|    DMA   | DMA |
|0x5000|   HOST   | HOST|

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

<p>Register map version: 0x0001_0007 is the map of step 1-7 (PMU, HOST placeholder, SYS control registers added).</p>

|Bits|Identifier|Access| Reset |Name|
|----|----------|------|-------|----|
|31:0|   value  |   r  |0x10007|  — |

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

#### dma field

<p>DMA, registers included.</p>

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
- Size: 0xC

<p>Core side of the PD_HOST placeholder (rtl/host/): a command FIFO into PD_HOST and a response FIFO out of it. Phase 2 replaces this block with the host interface's registers.</p>

|Offset|Identifier| Name |
|------|----------|------|
|  0x0 |    TX    |  TX  |
|  0x4 |    RX    |  RX  |
|  0x8 |  STATUS  |STATUS|

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
