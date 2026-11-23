`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// pd_host
//
// Boundary of the switchable power domain PD_HOST (docs/01, section 4). Inside:
// the PD_HOST logic reset synchronizer, the restore synchronizer, the link
// side of the transaction layer (tl_port, step 2-1) and the placeholder
// host_stub with its retention registers. Every output passes an iso_clamp,
// listed in syn/upf/storage_soc.upf:
//
//   cmd_pop, rsp_push, rsp_data    clamp 0: no FIFO access from an unpowered block
//   rst_out_n                      clamp 0: the pclk-side FIFO halves stay in reset
//   rxf_push, rxf_data, txf_pop    clamp 0: the same, for the TLP FIFOs
//   hold_ack                       clamp 0: an unpowered link is not held
//   pin_rx_ready, pin_tx_*         clamp 0: the host sees no READY and no TLP
//
// Inputs (FIFO status, data and reset state, PMU controls, pclk, the pins from the host)
// come from powered domains and are not isolated. The PHY PLL that makes pclk
// has its own supply (phy_pll_model, outside this wrapper).
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

  // Placeholder command and response FIFOs
  input  wire  [31:0]  cmd_data,
  input  wire          cmd_empty,
  output logic         cmd_pop,
  output logic [31:0]  rsp_data,
  output logic         rsp_push,
  input  wire          rsp_full,
  output logic         rst_out_n,

  // TLP FIFOs (pclk halves in PD_CORE)
  output logic         rxf_push,
  output logic [66:0]  rxf_data,
  input  wire          rxf_full,
  output logic         txf_pop,
  input  wire  [66:0]  txf_data,
  input  wire          txf_empty,
  input  wire          hold,
  input  wire          fifo_ok,       // host_if: the TLP FIFOs' pclk sides are out of reset
  output logic         hold_ack,

  // Host pins: packed TLPs (tl_pkg)
  input  wire          pin_rx_valid,
  output logic         pin_rx_ready,
  input  wire  [63:0]  pin_rx_data,
  input  wire          pin_rx_sop,
  input  wire          pin_rx_eop,
  input  wire          pin_rx_ehalf,
  output logic         pin_tx_valid,
  input  wire          pin_tx_ready,
  output logic [63:0]  pin_tx_data,
  output logic         pin_tx_sop,
  output logic         pin_tx_eop,
  output logic         pin_tx_ehalf
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

  // Link side of the transaction layer
  logic        raw_rxf_push, raw_txf_pop, raw_hold_ack, raw_rx_ready, raw_tx_valid;
  logic        raw_tx_sop, raw_tx_eop, raw_tx_ehalf;
  logic [66:0] raw_rxf_data;
  logic [63:0] raw_tx_data;

  tl_port u_port (
    .pclk         (pclk),         .rst_n        (rst_n),        .hold        (hold),
    .fifo_ok      (fifo_ok),
    .pin_rx_valid (pin_rx_valid), .pin_rx_ready (raw_rx_ready), .pin_rx_data (pin_rx_data),
    .pin_rx_sop   (pin_rx_sop),   .pin_rx_eop   (pin_rx_eop),   .pin_rx_ehalf (pin_rx_ehalf),
    .pin_tx_valid (raw_tx_valid), .pin_tx_ready (pin_tx_ready), .pin_tx_data (raw_tx_data),
    .pin_tx_sop   (raw_tx_sop),   .pin_tx_eop   (raw_tx_eop),   .pin_tx_ehalf (raw_tx_ehalf),
    .rxf_push     (raw_rxf_push), .rxf_data     (raw_rxf_data), .rxf_full    (rxf_full),
    .txf_pop      (raw_txf_pop),  .txf_data     (txf_data),     .txf_empty   (txf_empty),
    .hold_ack     (raw_hold_ack)
  );

  // ---------------------------------------------------------------------------
  // Off-state model: the outputs of an unpowered domain are undefined
  // ---------------------------------------------------------------------------
  localparam int NOUT = 35 + 1 + 67 + 1 + 1 + 1 + 1 + 64 + 3;
  wire [NOUT-1:0] raw = {raw_pop, raw_push, raw_rst_n, raw_data,
                         raw_rxf_push, raw_rxf_data, raw_txf_pop, raw_hold_ack,
                         raw_rx_ready, raw_tx_valid, raw_tx_data, raw_tx_sop, raw_tx_eop, raw_tx_ehalf};
  logic [NOUT-1:0] pa;
`ifndef SYNTHESIS
  logic [NOUT-1:0] junk;
  always @(posedge pclk_in) begin
`ifdef PA_XPROP
    junk <= 'x;
`else
    for (int i = 0; i < NOUT; i++) junk[i] <= 1'($urandom);
`endif
  end
  assign pa = pwr_ack ? raw : junk;
`else
  assign pa = raw;
  wire unused_ok = ^{pclk_in, pwr_ack};
`endif

  logic        pa_pop, pa_push, pa_rst_n, pa_rxf_push, pa_txf_pop, pa_hold_ack, pa_rx_ready;
  logic        pa_tx_valid, pa_tx_sop, pa_tx_eop, pa_tx_ehalf;
  logic [31:0] pa_data;
  logic [66:0] pa_rxf_data;
  logic [63:0] pa_tx_data;
  assign {pa_pop, pa_push, pa_rst_n, pa_data, pa_rxf_push, pa_rxf_data, pa_txf_pop, pa_hold_ack,
          pa_rx_ready, pa_tx_valid, pa_tx_data, pa_tx_sop, pa_tx_eop, pa_tx_ehalf} = pa;

  // ---------------------------------------------------------------------------
  // Isolation
  // ---------------------------------------------------------------------------
  iso_clamp #(.WIDTH(1),  .CLAMP(1'b0)) u_iso_pop     (.din(pa_pop),      .iso_en(iso_en), .dout(cmd_pop));
  iso_clamp #(.WIDTH(1),  .CLAMP(1'b0)) u_iso_push    (.din(pa_push),     .iso_en(iso_en), .dout(rsp_push));
  iso_clamp #(.WIDTH(32), .CLAMP(1'b0)) u_iso_data    (.din(pa_data),     .iso_en(iso_en), .dout(rsp_data));
  iso_clamp #(.WIDTH(1),  .CLAMP(1'b0)) u_iso_rst     (.din(pa_rst_n),    .iso_en(iso_en), .dout(rst_out_n));
  iso_clamp #(.WIDTH(1),  .CLAMP(1'b0)) u_iso_rxpush  (.din(pa_rxf_push), .iso_en(iso_en), .dout(rxf_push));
  iso_clamp #(.WIDTH(67), .CLAMP(1'b0)) u_iso_rxdata  (.din(pa_rxf_data), .iso_en(iso_en), .dout(rxf_data));
  iso_clamp #(.WIDTH(1),  .CLAMP(1'b0)) u_iso_txpop   (.din(pa_txf_pop),  .iso_en(iso_en), .dout(txf_pop));
  iso_clamp #(.WIDTH(1),  .CLAMP(1'b0)) u_iso_holdack (.din(pa_hold_ack), .iso_en(iso_en), .dout(hold_ack));
  iso_clamp #(.WIDTH(1),  .CLAMP(1'b0)) u_iso_rxready (.din(pa_rx_ready), .iso_en(iso_en), .dout(pin_rx_ready));
  iso_clamp #(.WIDTH(1),  .CLAMP(1'b0)) u_iso_txvalid (.din(pa_tx_valid), .iso_en(iso_en), .dout(pin_tx_valid));
  iso_clamp #(.WIDTH(64), .CLAMP(1'b0)) u_iso_txdata  (.din(pa_tx_data),  .iso_en(iso_en), .dout(pin_tx_data));
  iso_clamp #(.WIDTH(1),  .CLAMP(1'b0)) u_iso_txsop   (.din(pa_tx_sop),   .iso_en(iso_en), .dout(pin_tx_sop));
  iso_clamp #(.WIDTH(1),  .CLAMP(1'b0)) u_iso_txeop   (.din(pa_tx_eop),   .iso_en(iso_en), .dout(pin_tx_eop));
  iso_clamp #(.WIDTH(1),  .CLAMP(1'b0)) u_iso_txehalf (.din(pa_tx_ehalf), .iso_en(iso_en), .dout(pin_tx_ehalf));

endmodule : pd_host

`default_nettype wire
