`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// host_if
//
// Core side of the host interface, in PD_CORE: the HOST registers (host_regs,
// APB slot 5), the transaction layer (rtl/host/tl/tl_core.sv, AXI master M3)
// and the four dual-clock FIFOs that join clk_sys and pclk. The FIFOs sit whole
// in PD_CORE; their pclk halves are clocked by the PLL's gated clock and held
// in reset through PD_HOST's isolated reset output while PD_HOST is off, and
// their clk_sys halves are held in reset by the PMU (hostq_rst_req_n) from the
// start of a power-down to the end of a power-up.
//
//   TLP FIFOs  receive (pclk -> clk_sys) and transmit (clk_sys -> pclk) of
//              packed TLPs, 16 beats each
//   TX, RX     the PD_HOST placeholder's command and response FIFOs: a TX
//              write pushes a command unless the FIFO is full or PD_HOST is
//              not on (then STATUS.TX_DROP); an RX read pops the oldest
//              response (0 when none)
//
// The transaction layer runs on the core reset, so its configuration space
// (BARs, enables, MSI-X table) survives a PD_HOST power cycle.
//
// idle, to the PMU: every placeholder command has had its response read, and
// the host path is held and drained: LINK_CTRL.HOLD acknowledged by PD_HOST,
// the receive FIFO empty, the transmit FIFO empty as its pclk side sees it,
// and the transaction layer idle, all for 16 clocks in a row. The PMU refuses
// a power-down otherwise. The 16 clocks cover the synchronizers: a beat
// pushed just before HOLD took effect, or the last transmit beat's pop, shows
// up within about five clk_sys clocks at the 50 and 62.5 MHz clocks.
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

  output logic         irq_err,          // INTC source 5
  output logic         irq_bm,           // INTC source 12

  // AXI4 master M3
  output logic [1:0]   m_awid,
  output logic [31:0]  m_awaddr,
  output logic [7:0]   m_awlen,
  output logic [2:0]   m_awsize,
  output logic [1:0]   m_awburst,
  output logic         m_awvalid,
  input  wire          m_awready,
  output logic [63:0]  m_wdata,
  output logic [7:0]   m_wstrb,
  output logic         m_wlast,
  output logic         m_wvalid,
  input  wire          m_wready,
  input  wire  [1:0]   m_bid,
  input  wire  [1:0]   m_bresp,
  input  wire          m_bvalid,
  output logic         m_bready,
  output logic [1:0]   m_arid,
  output logic [31:0]  m_araddr,
  output logic [7:0]   m_arlen,
  output logic [2:0]   m_arsize,
  output logic [1:0]   m_arburst,
  output logic         m_arvalid,
  input  wire          m_arready,
  input  wire  [1:0]   m_rid,
  input  wire  [63:0]  m_rdata,
  input  wire  [1:0]   m_rresp,
  input  wire          m_rlast,
  input  wire          m_rvalid,
  output logic         m_rready,

  // pclk side, toward PD_HOST
  input  wire          pclk,
  input  wire          prst_req_n,       // PD_HOST's isolated reset output
  output logic [31:0]  cmd_data,
  output logic         cmd_empty,
  input  wire          cmd_pop,
  input  wire  [31:0]  rsp_data,
  input  wire          rsp_push,
  output logic         rsp_full,
  input  wire          rxf_push,
  input  wire  [66:0]  rxf_data,
  output logic         rxf_full,
  input  wire          txf_pop,
  output logic [66:0]  txf_data,
  output logic         txf_empty,
  output logic         hold,
  output logic         fifo_ok,          // pclk: the FIFOs' pclk sides are out of reset
  input  wire          hold_ack          // pclk flop, isolated
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
  // Placeholder FIFOs
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

  // ---------------------------------------------------------------------------
  // TLP FIFOs and the transaction layer
  // ---------------------------------------------------------------------------
  logic        trx_empty, trx_pop, ttx_full, ttx_push;
  logic [66:0] trx_data, ttx_data;

  cdc_async_fifo #(.WIDTH(67), .DEPTH(16)) u_tlp_rx_fifo (
    .wr_clk (pclk), .wr_rst_n (prst_n), .wr_en (rxf_push), .wr_data (rxf_data),
    .wr_full (rxf_full),
    .rd_clk (clk),  .rd_rst_n (qrst_n), .rd_en (trx_pop), .rd_data (trx_data),
    .rd_empty (trx_empty)
  );

  cdc_async_fifo #(.WIDTH(67), .DEPTH(16)) u_tlp_tx_fifo (
    .wr_clk (clk),  .wr_rst_n (qrst_n), .wr_en (ttx_push), .wr_data (ttx_data),
    .wr_full (ttx_full),
    .rd_clk (pclk), .rd_rst_n (prst_n), .rd_en (txf_pop), .rd_data (txf_data),
    .rd_empty (txf_empty)
  );

  logic        rxp_valid, rxp_ready, txp_valid, txp_ready;
  logic [63:0] txp_data;
  logic        txp_sop, txp_eop, txp_ehalf;

  assign rxp_valid = !trx_empty && qrst_n;
  assign trx_pop   = rxp_valid && rxp_ready;
  assign txp_ready = !ttx_full && qrst_n;
  assign ttx_push  = txp_valid && txp_ready;
  assign ttx_data  = {txp_ehalf, txp_eop, txp_sop, txp_data};

  logic        bm_done, bm_busy, msix_req, msix_wr;
  logic [2:0]  bm_cause;
  logic        st_mse, st_bme, st_msix_en, st_msix_fmask, st_mps256;
  logic [2:0]  st_mrrs;
  logic [15:0] st_id;
  logic [7:0]  st_msix_pend;
  logic        ev_ur, ev_poisoned, ev_unexp_cpl, ev_cpl_timeout, ev_cpl_err, ev_axi_err;
  logic        ev_discard, ev_msix_drop, rx_tlp, tx_tlp, tl_idle;
  logic [1:0]  ev_malformed;

  // MSIX_REQ, like TX, is read one clock after its write.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) msix_wr <= 1'b0;
    else        msix_wr <= hwif_out.MSIX_REQ.vector.swmod;
  end
  assign msix_req = msix_wr;

  tl_core u_tl (
    .clk (clk), .rst_n (rst_n),
    .rxp_valid (rxp_valid), .rxp_ready (rxp_ready), .rxp_data (trx_data[63:0]),
    .rxp_sop (trx_data[64]), .rxp_eop (trx_data[65]), .rxp_ehalf (trx_data[66]), .rxp_bad (1'b0),
    .txp_valid (txp_valid), .txp_ready (txp_ready), .txp_data (txp_data), .txp_sop (txp_sop),
    .txp_eop (txp_eop), .txp_ehalf (txp_ehalf),
    .m_awid (m_awid), .m_awaddr (m_awaddr), .m_awlen (m_awlen), .m_awsize (m_awsize),
    .m_awburst (m_awburst), .m_awvalid (m_awvalid), .m_awready (m_awready),
    .m_wdata (m_wdata), .m_wstrb (m_wstrb), .m_wlast (m_wlast), .m_wvalid (m_wvalid),
    .m_wready (m_wready),
    .m_bid (m_bid), .m_bresp (m_bresp), .m_bvalid (m_bvalid), .m_bready (m_bready),
    .m_arid (m_arid), .m_araddr (m_araddr), .m_arlen (m_arlen), .m_arsize (m_arsize),
    .m_arburst (m_arburst), .m_arvalid (m_arvalid), .m_arready (m_arready),
    .m_rid (m_rid), .m_rdata (m_rdata), .m_rresp (m_rresp), .m_rlast (m_rlast),
    .m_rvalid (m_rvalid), .m_rready (m_rready),
    .bar0_win (hwif_out.BAR0_WIN.base.value), .bar2_win (hwif_out.BAR2_WIN.base.value),
    .cto_ticks (hwif_out.CPL_TIMEOUT.ticks.value),
    .bm_start (hwif_out.BM_CTRL.start.value), .bm_d2h (hwif_out.BM_CTRL.d2h.value),
    .bm_haddr ({hwif_out.BM_HADDR_HI.addr.value, hwif_out.BM_HADDR_LO.addr.value}),
    .bm_laddr (hwif_out.BM_LADDR.addr.value), .bm_len (hwif_out.BM_LEN.bytes.value),
    .bm_done (bm_done), .bm_cause (bm_cause), .bm_busy (bm_busy),
    .msix_req (msix_req), .msix_vec (hwif_out.MSIX_REQ.vector.value),
    .st_mse (st_mse), .st_bme (st_bme), .st_msix_en (st_msix_en), .st_msix_fmask (st_msix_fmask),
    .st_mps256 (st_mps256), .st_mrrs (st_mrrs), .st_id (st_id), .st_msix_pend (st_msix_pend),
    .ev_ur (ev_ur), .ev_malformed (ev_malformed), .ev_poisoned (ev_poisoned),
    .ev_unexp_cpl (ev_unexp_cpl), .ev_cpl_timeout (ev_cpl_timeout), .ev_cpl_err (ev_cpl_err),
    .ev_axi_err (ev_axi_err), .ev_discard (ev_discard), .ev_msix_drop (ev_msix_drop),
    .rx_tlp (rx_tlp), .tx_tlp (tx_tlp), .idle (tl_idle)
  );

  assign hold    = hwif_out.LINK_CTRL.hold.value;
  assign fifo_ok = prst_n;

  // ---------------------------------------------------------------------------
  // Idle toward the PMU
  // ---------------------------------------------------------------------------
  // hold_ack arrives through its isolation clamp, which is logic; it is
  // registered again on pclk here so that the synchronizer sees one flop
  // (flow/cdc/check_cdc.py found the clamp in front of it).
  logic hold_ack_p, hold_ack_s, txf_empty_s;
  always_ff @(posedge pclk or negedge prst_n) begin
    if (!prst_n) hold_ack_p <= 1'b0;
    else         hold_ack_p <= hold_ack;
  end
  cdc_sync_2ff #(.WIDTH(1)) u_hack_sync (.clk(clk), .rst_n(rst_n), .din_async(hold_ack_p), .dout(hold_ack_s));
  cdc_sync_2ff #(.WIDTH(1)) u_txe_sync  (.clk(clk), .rst_n(rst_n), .din_async(txf_empty), .dout(txf_empty_s));

  wire        path_quiet = hold && hold_ack_s && txf_empty_s && trx_empty && !ttx_push && tl_idle;
  logic [3:0] quiet_cnt;
  logic       link_idle;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      quiet_cnt <= 4'd0;
      link_idle <= 1'b0;
    end else begin
      if (!path_quiet)              quiet_cnt <= 4'd0;
      else if (quiet_cnt != 4'hF)   quiet_cnt <= quiet_cnt + 4'd1;
      link_idle <= path_quiet && (quiet_cnt == 4'hF);
    end
  end

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
      host_idle <= 1'b0;
    end else begin
      pending   <= pending_next;
      host_idle <= (pending_next == 5'd0) && link_idle && path_quiet;
    end
  end

  // ---------------------------------------------------------------------------
  // Bus master status and cycle count
  // ---------------------------------------------------------------------------
  logic [31:0] bm_cyc;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)                                bm_cyc <= 32'd0;
    else if (hwif_out.BM_CTRL.start.value && !bm_busy) bm_cyc <= 32'd0;
    else if (bm_busy)                          bm_cyc <= bm_cyc + 32'd1;
  end

  logic [31:0] rx_cnt, tx_cnt;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rx_cnt <= 32'd0;
      tx_cnt <= 32'd0;
    end else begin
      rx_cnt <= rx_cnt + {31'd0, rx_tlp};
      tx_cnt <= tx_cnt + {31'd0, tx_tlp};
    end
  end

  wire bm_start_ok = hwif_out.BM_CTRL.start.value && !bm_busy;

  always_comb begin
    hwif_in.RX.data.next            = (rx_empty || !qrst_n) ? 32'd0 : rx_data;
    hwif_in.STATUS.rx_valid.next    = !rx_empty && qrst_n;
    hwif_in.STATUS.tx_full.next     = tx_full;
    hwif_in.STATUS.on.next          = on_s;
    hwif_in.STATUS.idle.next        = host_idle;
    hwif_in.STATUS.tx_drop.hwset    = tx_drop;

    hwif_in.LINK_STATUS.hold_ack.next   = hold_ack_s;
    hwif_in.LINK_STATUS.idle.next       = link_idle;
    hwif_in.LINK_STATUS.mse.next        = st_mse;
    hwif_in.LINK_STATUS.bme.next        = st_bme;
    hwif_in.LINK_STATUS.msix_en.next    = st_msix_en;
    hwif_in.LINK_STATUS.msix_fmask.next = st_msix_fmask;
    hwif_in.LINK_STATUS.mps256.next     = st_mps256;
    hwif_in.LINK_STATUS.mrrs.next       = st_mrrs;
    hwif_in.LINK_STATUS.id.next         = st_id;

    hwif_in.BM_STATUS.busy.next   = bm_busy;
    hwif_in.BM_STATUS.done.hwset  = bm_done && (bm_cause == 3'd0);
    hwif_in.BM_STATUS.done.hwclr  = bm_start_ok;
    hwif_in.BM_STATUS.err.hwset   = bm_done && (bm_cause != 3'd0);
    hwif_in.BM_STATUS.err.hwclr   = bm_start_ok;
    hwif_in.BM_STATUS.cause.next  = bm_cause;
    hwif_in.BM_STATUS.cause.we    = bm_done && (bm_cause != 3'd0);
    hwif_in.BM_CYCLES.count.next  = bm_cyc;
    hwif_in.MSIX_PEND.pending.next = st_msix_pend;

    hwif_in.ERR_STATUS.ur.hwset          = ev_ur;
    hwif_in.ERR_STATUS.malformed.hwset   = (ev_malformed != 2'd0);
    hwif_in.ERR_STATUS.poisoned.hwset    = ev_poisoned;
    hwif_in.ERR_STATUS.unexp_cpl.hwset   = ev_unexp_cpl;
    hwif_in.ERR_STATUS.cpl_timeout.hwset = ev_cpl_timeout;
    hwif_in.ERR_STATUS.cpl_err.hwset     = ev_cpl_err;
    hwif_in.ERR_STATUS.axi_err.hwset     = ev_axi_err;
    hwif_in.ERR_STATUS.discard.hwset     = ev_discard;
    hwif_in.ERR_STATUS.msix_drop.hwset   = ev_msix_drop;

    hwif_in.RX_TLPS.count.next = rx_cnt;
    hwif_in.TX_TLPS.count.next = tx_cnt;
  end

  assign irq_bm  = hwif_out.BM_STATUS.done.value || hwif_out.BM_STATUS.err.value;
  assign irq_err = hwif_out.ERR_STATUS.ur.value || hwif_out.ERR_STATUS.malformed.value ||
                   hwif_out.ERR_STATUS.poisoned.value || hwif_out.ERR_STATUS.unexp_cpl.value ||
                   hwif_out.ERR_STATUS.cpl_timeout.value || hwif_out.ERR_STATUS.cpl_err.value ||
                   hwif_out.ERR_STATUS.axi_err.value;

  // The discard and MSI-X drop bits are status only.
  /* verilator lint_off UNUSEDSIGNAL */
  wire unused_ok = ^{hwif_out.ERR_STATUS.discard.value, hwif_out.ERR_STATUS.msix_drop.value};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule : host_if

`default_nettype wire
