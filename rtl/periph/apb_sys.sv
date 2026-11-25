`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// apb_sys
//
// SYS block (APB slot 0, 0x4000_0000). The registers are the generated
// sys_regs (rtl/csr/rdl/soc_apb.rdl, docs/regs/soc_apb.md): ID, VERSION,
// SCRATCH, CONSOLE, EXIT; any other offset in the slot answers PSLVERR.
//
// A write to CONSOLE or EXIT raises console_valid or exit_valid for one
// clock, with the written value on console_char or exit_code. The testbench
// watches them; they stay in the synthesized design as ordinary registers.
//
// Since step 1-7 also SOFT_RESET (soft_rst_dma; since step 3-1 soft_rst_nand
// for the two NAND channels), CLK_GATE (cg_cpu) and SLEEP_CYCLES, which
// counts the clocks the CPU's clock gate removes.
// -----------------------------------------------------------------------------

module apb_sys (
  input  wire          clk,
  input  wire          rst_n,
  input  wire          psel,
  input  wire          penable,
  input  wire  [11:0]  paddr,
  input  wire          pwrite,
  input  wire  [31:0]  pwdata,
  input  wire  [3:0]   pstrb,
  output logic [31:0]  prdata,
  output logic         pready,
  output logic         pslverr,

  output logic         console_valid,
  output logic [7:0]   console_char,
  output logic         exit_valid,
  output logic [31:0]  exit_code,

  output logic         soft_rst_dma,
  output logic [1:0]   soft_rst_nand,
  output logic         cg_cpu,
  input  wire          cpu_sleep
);

  sys_regs_pkg::sys_regs__in_t  hwif_in;
  sys_regs_pkg::sys_regs__out_t hwif_out;

  sys_regs u_regs (
    .clk           (clk),
    .arst_n        (rst_n),
    .s_apb_psel    (psel),
    .s_apb_penable (penable),
    .s_apb_pwrite  (pwrite),
    .s_apb_pprot   (3'b000),
    .s_apb_paddr   (paddr),
    .s_apb_pwdata  (pwdata),
    .s_apb_pstrb   (pstrb),
    .s_apb_pready  (pready),
    .s_apb_prdata  (prdata),
    .s_apb_pslverr (pslverr),
    .hwif_in       (hwif_in),
    .hwif_out      (hwif_out)
  );

  logic [31:0] sleep_cycles;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)         sleep_cycles <= 32'd0;
    else if (cpu_sleep) sleep_cycles <= sleep_cycles + 32'd1;
  end
  assign hwif_in.SLEEP_CYCLES.count.next = sleep_cycles;
  assign soft_rst_dma  = hwif_out.SOFT_RESET.dma.value;
  assign soft_rst_nand = {hwif_out.SOFT_RESET.nand1.value, hwif_out.SOFT_RESET.nand0.value};
  assign cg_cpu       = hwif_out.CLK_GATE.cpu.value;

  // The field stores the written value on the same edge that this flop
  // records the write, so value and valid line up.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      console_valid <= 1'b0;
      exit_valid    <= 1'b0;
    end else begin
      console_valid <= hwif_out.CONSOLE.char.swmod;
      exit_valid    <= hwif_out.EXIT.code.swmod;
    end
  end

  assign console_char = hwif_out.CONSOLE.char.value;
  assign exit_code    = hwif_out.EXIT.code.value;

endmodule : apb_sys

`default_nettype wire
