`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// pd_host
//
// Boundary of the switchable power domain PD_HOST (docs/01, section 4). Inside:
// the PD_HOST logic reset synchronizer, the restore synchronizer and the logic
// (host_stub until phase 2). Every output passes an iso_clamp, listed in
// syn/upf/storage_soc.upf:
//
//   cmd_pop, rsp_push, rsp_data   clamp 0: no FIFO access from an unpowered block
//   rst_out_n                     clamp 0: the pclk-side FIFO halves stay in reset
//
// Inputs (FIFO status and data, PMU controls, pclk) come from powered domains
// and are not isolated. The PHY PLL that makes pclk has its own supply
// (phy_pll_model, outside this wrapper).
//
// Power-aware simulation: pwr_ack is the switch's power-good. While it is
// low, the logic's outputs before the clamps are garbage: a new random value
// every pclk_in clock under Verilator, X when PA_XPROP is defined (xsim). The
// retention shadows sit on the always-on supply and keep their contents.
// -----------------------------------------------------------------------------

module pd_host (
  input  wire          pclk,          // gated PLL output
  input  wire          pclk_in,       // free-running reference, for the off-state model only
  input  wire          pwr_ack,
  input  wire          rst_req_n,     // PMU: PD_HOST logic reset (clk_aon)
  input  wire          iso_en,
  input  wire          save,
  input  wire          restore,       // clk_aon level

  input  wire  [31:0]  cmd_data,
  input  wire          cmd_empty,
  output logic         cmd_pop,
  output logic [31:0]  rsp_data,
  output logic         rsp_push,
  input  wire          rsp_full,
  output logic         rst_out_n
);

  logic rst_n, restore_s;
  logic raw_pop, raw_push, raw_rst_n;
  logic [31:0] raw_data;

  rst_sync u_rst (.clk(pclk), .arst_n(rst_req_n), .rst_n(rst_n));
  cdc_sync_2ff #(.WIDTH(1)) u_restore_sync (.clk(pclk), .rst_n(rst_n), .din_async(restore), .dout(restore_s));

  host_stub u_stub (
    .pclk      (pclk),
    .rst_n     (rst_n),
    .save      (save),
    .restore   (restore_s),
    .cmd_data  (cmd_data),
    .cmd_empty (cmd_empty),
    .cmd_pop   (raw_pop),
    .rsp_data  (raw_data),
    .rsp_push  (raw_push),
    .rsp_full  (rsp_full)
  );
  assign raw_rst_n = rst_n;

  // ---------------------------------------------------------------------------
  // Off-state model: the outputs of an unpowered domain are undefined
  // ---------------------------------------------------------------------------
  logic        pa_pop, pa_push, pa_rst_n;
  logic [31:0] pa_data;
`ifndef SYNTHESIS
  logic [34:0] junk;
  always @(posedge pclk_in) begin
`ifdef PA_XPROP
    junk <= 'x;
`else
    junk <= {3'($urandom), $urandom};
`endif
  end
  assign {pa_pop, pa_push, pa_rst_n, pa_data} = pwr_ack ? {raw_pop, raw_push, raw_rst_n, raw_data} : junk;
`else
  assign {pa_pop, pa_push, pa_rst_n, pa_data} = {raw_pop, raw_push, raw_rst_n, raw_data};
  wire unused_ok = ^{pclk_in, pwr_ack};
`endif

  // ---------------------------------------------------------------------------
  // Isolation
  // ---------------------------------------------------------------------------
  iso_clamp #(.WIDTH(1),  .CLAMP(1'b0)) u_iso_pop  (.din(pa_pop),   .iso_en(iso_en), .dout(cmd_pop));
  iso_clamp #(.WIDTH(1),  .CLAMP(1'b0)) u_iso_push (.din(pa_push),  .iso_en(iso_en), .dout(rsp_push));
  iso_clamp #(.WIDTH(32), .CLAMP(1'b0)) u_iso_data (.din(pa_data),  .iso_en(iso_en), .dout(rsp_data));
  iso_clamp #(.WIDTH(1),  .CLAMP(1'b0)) u_iso_rst  (.din(pa_rst_n), .iso_en(iso_en), .dout(rst_out_n));

endmodule : pd_host

`default_nettype wire
