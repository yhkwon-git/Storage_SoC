`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// tl_port
//
// Link side of the transaction layer in PD_HOST, on pclk. In step 2-1 the
// host model drives packed TLPs (tl_pkg) on the pins directly, and this block
// joins the pins to the two dual-clock FIFOs that cross to clk_sys. From
// step 2-6 the data link layer takes its place.
//
//   receive   pins -> receive FIFO. HOLD (LINK_CTRL.HOLD, synchronized)
//             stops new TLPs at a TLP boundary: READY stays low from the
//             first beat of the next TLP on, while a TLP in progress
//             finishes. hold_ack: HOLD is in effect and no TLP is in
//             progress, so nothing more will be pushed. READY also waits
//             for fifo_ok: after a power-up the FIFO's pclk side leaves reset
//             two clocks after isolation ends, and a beat pushed before that
//             would be lost.
//   transmit  transmit FIFO -> pins, a beat whenever the FIFO has one.
// -----------------------------------------------------------------------------

module tl_port (
  input  wire          pclk,
  input  wire          rst_n,

  input  wire          hold,          // clk_sys level
  input  wire          fifo_ok,       // the TLP FIFOs' pclk sides are out of reset

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
  output logic         pin_tx_ehalf,

  output logic         rxf_push,
  output logic [66:0]  rxf_data,      // {ehalf, eop, sop, data}
  input  wire          rxf_full,

  output logic         txf_pop,
  input  wire  [66:0]  txf_data,
  input  wire          txf_empty,

  output logic         hold_ack
);

  logic hold_s, in_tlp;

  cdc_sync_2ff #(.WIDTH(1)) u_hold_sync (.clk(pclk), .rst_n(rst_n), .din_async(hold), .dout(hold_s));

  assign pin_rx_ready = fifo_ok && !rxf_full && (in_tlp || !hold_s);
  assign rxf_push     = pin_rx_valid && pin_rx_ready;
  assign rxf_data     = {pin_rx_ehalf, pin_rx_eop, pin_rx_sop, pin_rx_data};

  wire in_tlp_next = rxf_push ? !pin_rx_eop : in_tlp;

  always_ff @(posedge pclk or negedge rst_n) begin
    if (!rst_n) begin
      in_tlp   <= 1'b0;
      hold_ack <= 1'b0;
    end else begin
      in_tlp   <= in_tlp_next;
      hold_ack <= hold_s && !in_tlp_next;
    end
  end

  assign pin_tx_valid = !txf_empty;
  assign {pin_tx_ehalf, pin_tx_eop, pin_tx_sop, pin_tx_data} = txf_data;
  assign txf_pop      = pin_tx_valid && pin_tx_ready;

endmodule : tl_port

`default_nettype wire
