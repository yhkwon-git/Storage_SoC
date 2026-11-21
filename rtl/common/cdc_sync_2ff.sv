`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// cdc_sync_2ff
//
// Two flip-flops in the destination clock. A multi-bit input must be Gray
// coded (at most one bit changes per source clock), or be a quasi-static value
// that is not used until it has settled.
//
// rst_n is asserted asynchronously and released synchronously to clk. Both
// stages reset to 0.
//
// Origin: axi-pcie-subsystem commit b64e36a, rtl/cdc_async_fifo.sv, module
// cdc_sync_2ff. Logic unchanged; this header rewritten.
// -----------------------------------------------------------------------------

module cdc_sync_2ff #(
  parameter int WIDTH = 4
) (
  input  wire                  clk,
  input  wire                  rst_n,
  input  wire [WIDTH-1:0]      din_async,
  output wire [WIDTH-1:0]      dout
);

  (* ASYNC_REG = "TRUE" *) logic [WIDTH-1:0] stage1;
  (* ASYNC_REG = "TRUE" *) logic [WIDTH-1:0] stage2;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      stage1 <= '0;
      stage2 <= '0;
    end else begin
      stage1 <= din_async;
      stage2 <= stage1;
    end
  end

  assign dout = stage2;

endmodule : cdc_sync_2ff

`default_nettype wire
