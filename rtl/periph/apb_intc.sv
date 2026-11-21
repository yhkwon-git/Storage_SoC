`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// apb_intc
//
// Interrupt controller (APB slot 2, 0x4000_2000) for level sources 1..31;
// source 0 does not exist. Source IDs are listed in docs/01, section 7.
// The registers are the generated intc_regs (PENDING, ENABLE, CLAIM, SWSET;
// docs/regs/soc_apb.md); this module computes what they report.
//
// PENDING = (src | SWSET) with bit 0 cleared. CLAIM is the lowest ID that is
// pending and enabled, 0 if none; reading it has no side effect. irq (to the
// core's external interrupt) is high while any enabled source is pending. A
// source stays pending until the block that raised it is cleared.
// -----------------------------------------------------------------------------

module apb_intc (
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

  input  wire  [31:0]  src,
  output logic         irq
);

  intc_regs_pkg::intc_regs__in_t  hwif_in;
  intc_regs_pkg::intc_regs__out_t hwif_out;

  intc_regs u_regs (
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

  logic [31:0] pending;
  logic [31:0] enable;
  logic [4:0]  claim;

  assign enable  = hwif_out.ENABLE.value.value;
  assign pending = (src | hwif_out.SWSET.value.value) & 32'hFFFF_FFFE;
  assign irq     = |(pending & enable);

  always_comb begin
    claim = 5'd0;
    for (int i = 31; i >= 1; i--) begin
      if (pending[i] && enable[i]) claim = 5'(i);
    end
  end

  assign hwif_in.PENDING.value.next = pending;
  assign hwif_in.CLAIM.id.next      = claim;

endmodule : apb_intc

`default_nettype wire
