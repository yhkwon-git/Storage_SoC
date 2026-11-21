`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// ret_reg
//
// Retention register: a normal flop in the switchable domain plus a shadow
// latch on the always-on supply (docs/01, section 4). While save is high the
// shadow follows q; it is neither reset nor lost while the domain is off.
// While restore is high, q loads the shadow on every clk edge, so restore
// must be synchronous to clk and the domain idle. The PMU restores only after
// a save.
// -----------------------------------------------------------------------------

module ret_reg #(
  parameter int WIDTH = 16
) (
  input  wire              clk,
  input  wire              rst_n,
  input  wire              save,
  input  wire              restore,
  input  wire              en,
  input  wire  [WIDTH-1:0] d,
  output logic [WIDTH-1:0] q
);

  logic [WIDTH-1:0] shadow;

  always_latch begin
    if (save) shadow = q;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)       q <= '0;
    else if (restore) q <= shadow;
    else if (en)      q <= d;
  end

endmodule : ret_reg

`default_nettype wire
