`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// host_if
//
// Core side of the PD_HOST placeholder, in PD_CORE: the HOST registers
// (host_regs, APB slot 5) and the two dual-clock FIFOs that join clk_sys and
// pclk. The FIFOs sit whole in PD_CORE; their pclk halves are clocked by the
// PLL's gated clock and held in reset through PD_HOST's isolated reset output
// while PD_HOST is off, and their clk_sys halves are held in reset by the PMU
// (hostq_rst_req_n) from the start of a power-down to the end of a power-up.
//
//   TX write  pushes a command, unless the FIFO is full or PD_HOST is not on:
//             then it is dropped and STATUS.TX_DROP is set
//   RX read   returns the oldest response and removes it (0 when none)
//   idle      every command sent has had its response read; the PMU refuses
//             a power-down otherwise. The stub answers each command once, so
//             a count of commands minus responses read is exact.
// -----------------------------------------------------------------------------

module host_if (
  input  wire          clk,
  input  wire          rst_n,            // rst_sys_n
  input  wire          hostq_rst_req_n,  // PMU, clk_aon level

  input  wire          psel,
  input  wire          penable,
  input  wire  [11:0]  paddr,
  input  wire          pwrite,
  input  wire  [31:0]  pwdata,
  input  wire  [3:0]   pstrb,
  output logic [31:0]  prdata,
  output logic         pready,
  output logic         pslverr,

  input  wire          host_on,          // PMU, clk_aon level
  output logic         host_idle,        // to the PMU

  // pclk side, toward PD_HOST
  input  wire          pclk,
  input  wire          prst_req_n,       // PD_HOST's isolated reset output
  output logic [31:0]  cmd_data,
  output logic         cmd_empty,
  input  wire          cmd_pop,
  input  wire  [31:0]  rsp_data,
  input  wire          rsp_push,
  output logic         rsp_full
);

  logic qrst_n, prst_n, on_s;

  rst_sync u_qrst (.clk(clk),  .arst_n(rst_n && hostq_rst_req_n), .rst_n(qrst_n));
  rst_sync u_prst (.clk(pclk), .arst_n(prst_req_n),               .rst_n(prst_n));
  cdc_sync_2ff #(.WIDTH(1)) u_on_sync (.clk(clk), .rst_n(rst_n), .din_async(host_on), .dout(on_s));

  host_regs_pkg::host_regs__in_t  hwif_in;
  host_regs_pkg::host_regs__out_t hwif_out;

  host_regs u_regs (
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

  // ---------------------------------------------------------------------------
  // FIFOs
  // ---------------------------------------------------------------------------
  logic        tx_full, rx_empty;
  logic [31:0] rx_data;
  logic        tx_push, rx_pop, tx_wr, tx_drop;

  cdc_async_fifo #(.WIDTH(32), .DEPTH(8)) u_cmd_fifo (
    .wr_clk (clk),  .wr_rst_n (qrst_n), .wr_en (tx_push), .wr_data (hwif_out.TX.data.value),
    .wr_full (tx_full),
    .rd_clk (pclk), .rd_rst_n (prst_n), .rd_en (cmd_pop), .rd_data (cmd_data),
    .rd_empty (cmd_empty)
  );

  cdc_async_fifo #(.WIDTH(32), .DEPTH(8)) u_rsp_fifo (
    .wr_clk (pclk), .wr_rst_n (prst_n), .wr_en (rsp_push), .wr_data (rsp_data),
    .wr_full (rsp_full),
    .rd_clk (clk),  .rd_rst_n (qrst_n), .rd_en (rx_pop), .rd_data (rx_data),
    .rd_empty (rx_empty)
  );

  // TX stores the written value on the edge that ends the write; the push
  // follows one clock later.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) tx_wr <= 1'b0;
    else        tx_wr <= hwif_out.TX.data.swmod;
  end

  assign tx_push = tx_wr && on_s && qrst_n && !tx_full;
  assign tx_drop = tx_wr && !tx_push;
  assign rx_pop  = hwif_out.RX.data.swacc && !rx_empty && qrst_n;

  // Commands sent minus responses read. host_idle goes to the PMU through a
  // synchronizer, so it is a flop: a decode of the counter could glitch high
  // while its bits change, and the synchronizer could catch the glitch
  // (flow/cdc/check_cdc.py found it). It is registered from the counter's
  // next value, so it changes on the same clock as the counter.
  logic [4:0] pending, pending_next;
  assign pending_next = pending + (tx_push ? 5'd1 : 5'd0) - (rx_pop ? 5'd1 : 5'd0);
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pending   <= 5'd0;
      host_idle <= 1'b1;
    end else begin
      pending   <= pending_next;
      host_idle <= (pending_next == 5'd0);
    end
  end

  always_comb begin
    hwif_in.RX.data.next            = (rx_empty || !qrst_n) ? 32'd0 : rx_data;
    hwif_in.STATUS.rx_valid.next    = !rx_empty && qrst_n;
    hwif_in.STATUS.tx_full.next     = tx_full;
    hwif_in.STATUS.on.next          = on_s;
    hwif_in.STATUS.idle.next        = host_idle;
    hwif_in.STATUS.tx_drop.hwset    = tx_drop;
  end

endmodule : host_if

`default_nettype wire
