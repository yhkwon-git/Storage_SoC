`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// apb_intc
//
// Interrupt controller (APB slot 2, 0x4000_2000) for level sources 1..31;
// source 0 does not exist. Source IDs are listed in docs/01, section 7.
//
//   0x000 PENDING  RO  (src | SWSET), bit 0 always 0
//   0x004 ENABLE   RW
//   0x008 CLAIM    RO  lowest ID that is pending and enabled, 0 if none;
//                      reading has no side effect
//   0x00C SWSET    RW  software-set sources, for tests and software events
// Other offsets answer PSLVERR.
//
// irq (to the core's external interrupt) is high while any enabled source is
// pending. A source stays pending until the block that raised it is cleared.
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

  logic [31:0] enable;
  logic [31:0] swset;
  logic [31:0] pending;
  logic [4:0]  claim;

  assign pending = (src | swset) & 32'hFFFF_FFFE;
  assign irq     = |(pending & enable);

  always_comb begin
    claim = 5'd0;
    for (int i = 31; i >= 1; i--) begin
      if (pending[i] && enable[i]) claim = 5'(i);
    end
  end

  wire access = psel && penable;
  wire wr     = access && pwrite;

  assign pready = 1'b1;

  always_comb begin
    prdata  = 32'd0;
    pslverr = 1'b0;
    case (paddr)
      12'h000: prdata = pending;
      12'h004: prdata = enable;
      12'h008: prdata = {27'd0, claim};
      12'h00C: prdata = swset;
      default: pslverr = 1'b1;
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      enable <= 32'd0;
      swset  <= 32'd0;
    end else if (wr) begin
      for (int i = 0; i < 4; i++) begin
        if (pstrb[i] && paddr == 12'h004) enable[i*8 +: 8] <= pwdata[i*8 +: 8];
        if (pstrb[i] && paddr == 12'h00C) swset[i*8 +: 8]  <= pwdata[i*8 +: 8];
      end
    end
  end

endmodule : apb_intc

`default_nettype wire
