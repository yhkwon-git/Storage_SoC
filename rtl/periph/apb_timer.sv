`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// apb_timer
//
// RISC-V machine timer (APB slot 3, 0x4000_3000). The registers are the
// generated timer_regs (MTIME_LO/HI, MTIMECMP_LO/HI, CTRL;
// docs/regs/soc_apb.md); this module counts.
//
// With CTRL.ENABLE set, mtime advances by one every CTRL.PRESCALE + 1 clocks:
// both MTIME words are loaded through their hardware write enables, and a
// software write in the same clock takes precedence (the SystemRDL default).
// irq is high while mtime >= mtimecmp, the level the core's timer input
// expects; software moves mtimecmp to clear it.
// -----------------------------------------------------------------------------

module apb_timer (
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
  output logic         irq
);

  timer_regs_pkg::timer_regs__in_t  hwif_in;
  timer_regs_pkg::timer_regs__out_t hwif_out;

  timer_regs u_regs (
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

  logic [63:0] mtime;
  logic [63:0] mtimecmp;
  logic [63:0] mtime_next;
  logic [7:0]  pre_cnt;
  logic        tick;

  assign mtime      = {hwif_out.MTIME_HI.value.value, hwif_out.MTIME_LO.value.value};
  assign mtimecmp   = {hwif_out.MTIMECMP_HI.value.value, hwif_out.MTIMECMP_LO.value.value};
  assign mtime_next = mtime + 64'd1;
  assign tick       = hwif_out.CTRL.enable.value && (pre_cnt == hwif_out.CTRL.prescale.value);
  assign irq        = (mtime >= mtimecmp);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pre_cnt <= 8'd0;
    end else if (hwif_out.CTRL.enable.value) begin
      pre_cnt <= tick ? 8'd0 : pre_cnt + 8'd1;
    end
  end

  assign hwif_in.MTIME_LO.value.next = mtime_next[31:0];
  assign hwif_in.MTIME_LO.value.we   = tick;
  assign hwif_in.MTIME_HI.value.next = mtime_next[63:32];
  assign hwif_in.MTIME_HI.value.we   = tick;

endmodule : apb_timer

`default_nettype wire
