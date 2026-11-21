`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// clk_gate
//
// Integrated clock gate: the enable is latched while clk is low, so gclk
// never has a short pulse, whatever en does between edges. en must be
// synchronous to clk. test_en forces the clock on (scan). Synthesis maps this
// to the library's clock-gating cell (Sky130 sky130_fd_sc_hd__dlclkp, step
// 1-9).
// -----------------------------------------------------------------------------

module clk_gate (
  input  wire clk,
  input  wire en,
  input  wire test_en,
  output wire gclk
);

  logic en_l;

  always_latch begin
    if (!clk) en_l = en | test_en;
  end

  assign gclk = clk & en_l;

endmodule : clk_gate

`default_nettype wire
