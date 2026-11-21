/*
 * Code and read-only data in the boot ROM; data, bss and stack in the lower
 * 32 KiB of SRAM. The upper 32 KiB are left to the other bus masters (the
 * testbench drives traffic there while the firmware runs).
 */

OUTPUT_ARCH(riscv)
ENTRY(reset_entry)

MEMORY
{
  ROM (rx)  : ORIGIN = 0x00000000, LENGTH = 16K
  RAM (rwx) : ORIGIN = 0x10000000, LENGTH = 32K
}

SECTIONS
{
  .vectors : { KEEP(*(.vectors)) } > ROM
  .text    : { *(.text.start) *(.text .text.*) } > ROM
  .rodata  : { *(.rodata .rodata.* .srodata .srodata.*) } > ROM

  .data : ALIGN(4)
  {
    _data_start = .;
    *(.data .data.* .sdata .sdata.*)
    . = ALIGN(4);
    _data_end = .;
  } > RAM AT > ROM
  _data_lma = LOADADDR(.data);

  .bss (NOLOAD) : ALIGN(4)
  {
    _bss_start = .;
    *(.bss .bss.* .sbss .sbss.* COMMON)
    . = ALIGN(4);
    _bss_end = .;
  } > RAM

  __global_pointer$ = _data_start + 0x800;
  _stack_top = ORIGIN(RAM) + LENGTH(RAM);

  /DISCARD/ : { *(.comment) *(.riscv.attributes) }
}
