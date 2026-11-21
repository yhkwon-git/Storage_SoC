`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// phy_pll_model
//
// Behavioral stand-in for the PHY's PLL macro, which has its own supply and
// stays outside the switched logic of PD_HOST. ref_clk is the PLL's output
// frequency (pclk_in, 62.5 MHz) and runs all the time in this model. While en
// is high (synchronized into ref_clk) the gated clock runs, and lock rises
// LOCK_CYCLES clocks later; en low stops the clock low and drops lock at once.
// In simulation, +pll_stuck keeps lock low to test the PMU's timeout.
// -----------------------------------------------------------------------------

module phy_pll_model #(
  parameter int LOCK_CYCLES = 16
) (
  input  wire  ref_clk,
  input  wire  rst_n,      // power-on reset
  input  wire  en,         // asynchronous (clk_aon)
  output wire  clk_out,
  output logic lock
);

  logic en_s;
  logic [7:0] cnt;
  bit   stuck = 1'b0;

`ifndef SYNTHESIS
  initial stuck = $test$plusargs("pll_stuck");
`endif

  cdc_sync_2ff #(.WIDTH(1)) u_en_sync (.clk(ref_clk), .rst_n(rst_n), .din_async(en), .dout(en_s));

  always_ff @(posedge ref_clk or negedge rst_n) begin
    if (!rst_n) begin
      cnt  <= 8'd0;
      lock <= 1'b0;
    end else if (!en_s) begin
      cnt  <= 8'd0;
      lock <= 1'b0;
    end else if (cnt != 8'(LOCK_CYCLES)) begin
      cnt <= cnt + 8'd1;
    end else begin
      lock <= !stuck;
    end
  end

  clk_gate u_cg (.clk(ref_clk), .en(en_s), .test_en(1'b0), .gclk(clk_out));

endmodule : phy_pll_model

`default_nettype wire
