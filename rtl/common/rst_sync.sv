`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// rst_sync
//
// Reset synchronizer: rst_n follows arst_n low at once (asynchronous assert)
// and goes high STAGES clk edges after arst_n rises (synchronous release).
// arst_n may be the AND of several glitch-free reset requests from any clock
// domain. docs/01_soc_architecture.md, section 3.
// -----------------------------------------------------------------------------

module rst_sync #(
  parameter int STAGES = 2
) (
  input  wire  clk,
  input  wire  arst_n,
  output logic rst_n
);

  // The last stage is the downstream blocks' asynchronous reset while the
  // stages feed each other as data: that is what a reset synchronizer is.
  /* verilator lint_off SYNCASYNCNET */
  (* ASYNC_REG = "TRUE" *) logic [STAGES-1:0] sync;
  /* verilator lint_on SYNCASYNCNET */

  always_ff @(posedge clk or negedge arst_n) begin
    if (!arst_n) sync <= '0;
    else         sync <= {sync[STAGES-2:0], 1'b1};
  end

  assign rst_n = sync[STAGES-1];

endmodule : rst_sync

`default_nettype wire
