<!---
Markdown description for SystemRDL register map.

Don't override. Generated from: soc_apb
  - rtl/csr/rdl/soc_apb.rdl
-->

## soc_apb address map

- Absolute Address: 0x0
- Base Offset: 0x0
- Size: 0x4020

<p>Register blocks in the APB window at 0x4000_0000, one 4 KiB slot each.</p>

|Offset|Identifier| Name|
|------|----------|-----|
|0x0000|    SYS   | SYS |
|0x2000|   INTC   | INTC|
|0x3000|   TIMER  |TIMER|
|0x4000|    DMA   | DMA |

## SYS address map

- Absolute Address: 0x0
- Base Offset: 0x0
- Size: 0x18

<p>Identification, a scratch register, and the simulation console and exit registers.</p>

|Offset|Identifier|  Name |
|------|----------|-------|
| 0x00 |    ID    |   ID  |
| 0x04 |  VERSION |VERSION|
| 0x08 |  SCRATCH |SCRATCH|
| 0x10 |  CONSOLE |CONSOLE|
| 0x14 |   EXIT   |  EXIT |

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

<p>Register map version: 0x0001_0006 is the map of step 1-6 (DMA added).</p>

|Bits|Identifier|Access| Reset |Name|
|----|----------|------|-------|----|
|31:0|   value  |   r  |0x10006|  — |

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
