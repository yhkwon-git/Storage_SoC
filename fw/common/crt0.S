/*
 * Start-up code for Ibex in Storage_SoC.
 *
 * Ibex starts at boot_addr + 0x80 with mtvec = boot_addr in vectored mode.
 * boot_addr is 0, so the 32 vector entries sit at 0x00..0x7C and the reset
 * entry at 0x80. Every entry jumps to one handler that saves the caller-saved
 * registers and calls trap_handler(frame); the value it returns becomes mepc.
 * The frame holds ra at index 0, so a handler can return to the caller of a
 * faulting call.
 */

    .section .vectors, "ax"
    .option push
    .option norvc
    .global _vectors
_vectors:
    .rept 32
    j trap_entry
    .endr
    .org 0x80
    j reset_entry
    .option pop

    .section .text.start, "ax"
    .global reset_entry
reset_entry:
    .option push
    .option norelax
    la   gp, __global_pointer$
    .option pop
    la   sp, _stack_top

    /* Copy .data from ROM to SRAM. */
    la   a0, _data_lma
    la   a1, _data_start
    la   a2, _data_end
1:  bgeu a1, a2, 2f
    lw   t0, 0(a0)
    sw   t0, 0(a1)
    addi a0, a0, 4
    addi a1, a1, 4
    j    1b

    /* Clear .bss. */
2:  la   a1, _bss_start
    la   a2, _bss_end
3:  bgeu a1, a2, 4f
    sw   zero, 0(a1)
    addi a1, a1, 4
    j    3b

4:  call main
    call sys_exit
5:  j    5b

    .section .text
    .global trap_entry
    .align 2
trap_entry:
    addi sp, sp, -64
    sw   ra,  0(sp)
    sw   t0,  4(sp)
    sw   t1,  8(sp)
    sw   t2, 12(sp)
    sw   a0, 16(sp)
    sw   a1, 20(sp)
    sw   a2, 24(sp)
    sw   a3, 28(sp)
    sw   a4, 32(sp)
    sw   a5, 36(sp)
    sw   a6, 40(sp)
    sw   a7, 44(sp)
    sw   t3, 48(sp)
    sw   t4, 52(sp)
    sw   t5, 56(sp)
    sw   t6, 60(sp)
    mv   a0, sp
    call trap_handler
    csrw mepc, a0
    lw   ra,  0(sp)
    lw   t0,  4(sp)
    lw   t1,  8(sp)
    lw   t2, 12(sp)
    lw   a0, 16(sp)
    lw   a1, 20(sp)
    lw   a2, 24(sp)
    lw   a3, 28(sp)
    lw   a4, 32(sp)
    lw   a5, 36(sp)
    lw   a6, 40(sp)
    lw   a7, 44(sp)
    lw   t3, 48(sp)
    lw   t4, 52(sp)
    lw   t5, 56(sp)
    lw   t6, 60(sp)
    addi sp, sp, 64
    mret
