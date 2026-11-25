`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// nand_ctrl
//
// One NAND channel (step 3-1, docs/15_nand_channel.md): an 8-bit ONFI-style
// asynchronous interface for one target, driven from a command queue.
//
// clk_sys side (this module):
//   - registers (nand_regs, APB slot 6 or 7);
//   - a command queue of 4: CMD_GO queues OP and TAG with CMD_ROW, CMD_COL,
//     CMD_LEN and CMD_BUF as they are then; with 4 waiting it is dropped and
//     EVENT.OVF is set;
//   - a dispatcher that sends one command at a time to the sequencer, with
//     TIMING0, TIMING1 and TIMEOUT as they are at dispatch, and moves its
//     data: from the page buffer to the bus (PROGRAM), or from the bus into
//     the page buffer (READ_ID, READ, CHANGE READ COLUMN), LEN bytes from
//     buffer offset CMD_BUF, one byte per clock at most;
//   - a completion queue of 8 read through CPL. A command is dispatched only
//     with room for its completion, so none is ever lost;
//   - the page buffer (nand_pbuf, 8 KiB) on the crossbar.
// clk_nand side: nand_seq, the bus sequencer. Commands, program data, read
// data and completions cross in dual-clock FIFOs; R/B# and the write enable
// cross in 2-flop synchronizers.
//
// Interrupts: irq_done while a completion waits and CTRL.IEN_DONE is set;
// irq_err while EVENT.ERR or EVENT.OVF is set and CTRL.IEN_ERR is.
// -----------------------------------------------------------------------------

module nand_ctrl #(
  parameter int IDW = 4
) (
  input  wire              clk,            // clk_sys
  input  wire              rst_n,          // this channel's clk_sys reset
  input  wire              clk_nand,
  input  wire              rst_nand_n,     // this channel's clk_nand reset

  // APB, slot 6 or 7
  input  wire              psel,
  input  wire              penable,
  input  wire  [11:0]      paddr,
  input  wire              pwrite,
  input  wire  [31:0]      pwdata,
  input  wire  [3:0]       pstrb,
  output logic [31:0]      prdata,
  output logic             pready,
  output logic             pslverr,

  // AXI4 slave: the page buffer, S3 or S4
  input  wire  [IDW-1:0]   s_awid,
  input  wire  [31:0]      s_awaddr,
  input  wire  [7:0]       s_awlen,
  input  wire              s_awvalid,
  output logic             s_awready,
  input  wire  [63:0]      s_wdata,
  input  wire  [7:0]       s_wstrb,
  input  wire              s_wlast,
  input  wire              s_wvalid,
  output logic             s_wready,
  output logic [IDW-1:0]   s_bid,
  output logic [1:0]       s_bresp,
  output logic             s_bvalid,
  input  wire              s_bready,
  input  wire  [IDW-1:0]   s_arid,
  input  wire  [31:0]      s_araddr,
  input  wire  [7:0]       s_arlen,
  input  wire              s_arvalid,
  output logic             s_arready,
  output logic [IDW-1:0]   s_rid,
  output logic [63:0]      s_rdata,
  output logic [1:0]       s_rresp,
  output logic             s_rlast,
  output logic             s_rvalid,
  input  wire              s_rready,

  // NAND pins (clk_nand)
  output logic             ce_n,
  output logic             cle,
  output logic             ale,
  output logic             we_n,
  output logic             re_n,
  output logic             wp_n,
  output logic [7:0]       dq_o,
  output logic             dq_oe,
  input  wire  [7:0]       dq_i,
  input  wire              rb_n,

  output logic             irq_done,
  output logic             irq_err
);
  import nand_pkg::*;

  // ---------------------------------------------------------------------------
  // Registers
  // ---------------------------------------------------------------------------
  nand_regs_pkg::nand_regs__in_t  hwif_in;
  nand_regs_pkg::nand_regs__out_t hwif_out;

  nand_regs u_regs (
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
  // Command queue
  // ---------------------------------------------------------------------------
  typedef struct packed {
    logic [2:0]  op;
    logic [7:0]  tag;
    logic [23:0] row;
    logic [12:0] col;
    logic [12:0] len;
    logic [12:0] off;
  } qcmd_t;

  // CMD_GO's fields take the written value at the clock edge of the write, so
  // the queue takes them one clock later.
  logic go;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) go <= 1'b0;
    else        go <= hwif_out.CMD_GO.op.swmod;
  end

  qcmd_t      q_in, q_out;
  logic       q_full, q_empty, q_pop;
  logic [2:0] q_count;
  wire        q_push = go && !q_full;

  assign q_in = '{op:  hwif_out.CMD_GO.op.value,   tag: hwif_out.CMD_GO.tag.value,
                  row: hwif_out.CMD_ROW.row.value, col: hwif_out.CMD_COL.col.value,
                  len: hwif_out.CMD_LEN.len.value, off: hwif_out.CMD_BUF.off.value};

  fifo_sync #(.WIDTH($bits(qcmd_t)), .DEPTH(4)) u_q (
    .clk (clk), .rst_n (rst_n), .push (q_push), .din (q_in), .full (q_full),
    .pop (q_pop), .dout (q_out), .empty (q_empty)
  );

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) q_count <= 3'd0;
    else        q_count <= q_count + {2'd0, q_push} - {2'd0, q_pop};
  end

  // ---------------------------------------------------------------------------
  // Clock-domain crossings
  // ---------------------------------------------------------------------------
  cmd_t        x_cmd, n_cmd;
  logic        x_cmd_push, x_cmd_full, n_cmd_pop, n_cmd_empty;
  logic        tx_push, tx_full, n_tx_pop, n_tx_empty;
  logic [7:0]  tx_byte, n_tx_data;
  logic        n_rx_push, n_rx_full, rx_pop, rx_empty;
  logic [7:0]  n_rx_data, rx_byte;
  cpl_t        n_cpl, x_cpl;
  logic        n_cpl_push, n_cpl_full, x_cpl_pop, x_cpl_empty;

  cdc_async_fifo #(.WIDTH($bits(cmd_t)), .DEPTH(4)) u_xcmd (
    .wr_clk (clk), .wr_rst_n (rst_n), .wr_en (x_cmd_push), .wr_data (x_cmd), .wr_full (x_cmd_full),
    .rd_clk (clk_nand), .rd_rst_n (rst_nand_n), .rd_en (n_cmd_pop), .rd_data (n_cmd), .rd_empty (n_cmd_empty)
  );
  cdc_async_fifo #(.WIDTH(8), .DEPTH(16)) u_xtx (
    .wr_clk (clk), .wr_rst_n (rst_n), .wr_en (tx_push), .wr_data (tx_byte), .wr_full (tx_full),
    .rd_clk (clk_nand), .rd_rst_n (rst_nand_n), .rd_en (n_tx_pop), .rd_data (n_tx_data), .rd_empty (n_tx_empty)
  );
  cdc_async_fifo #(.WIDTH(8), .DEPTH(16)) u_xrx (
    .wr_clk (clk_nand), .wr_rst_n (rst_nand_n), .wr_en (n_rx_push), .wr_data (n_rx_data), .wr_full (n_rx_full),
    .rd_clk (clk), .rd_rst_n (rst_n), .rd_en (rx_pop), .rd_data (rx_byte), .rd_empty (rx_empty)
  );
  cdc_async_fifo #(.WIDTH($bits(cpl_t)), .DEPTH(4)) u_xcpl (
    .wr_clk (clk_nand), .wr_rst_n (rst_nand_n), .wr_en (n_cpl_push), .wr_data (n_cpl), .wr_full (n_cpl_full),
    .rd_clk (clk), .rd_rst_n (rst_n), .rd_en (x_cpl_pop), .rd_data (x_cpl), .rd_empty (x_cpl_empty)
  );

  // R/B# for STATUS, in clk_sys
  logic rb_sys;
  cdc_sync_2ff #(.WIDTH(1)) u_rb (.clk (clk), .rst_n (rst_n), .din_async (rb_n), .dout (rb_sys));

  // ---------------------------------------------------------------------------
  // Bus sequencer (clk_nand)
  // ---------------------------------------------------------------------------
  // The write enable crosses into clk_nand from a flop of its own: no logic
  // may sit in front of a synchronizer. It resets to 0, so WP# stays low
  // (protected) from reset until firmware clears CTRL.WP.
  logic wen;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) wen <= 1'b0;
    else        wen <= !hwif_out.CTRL.wp.value;
  end

  nand_seq u_seq (
    .clk (clk_nand), .rst_n (rst_nand_n),
    .cmd_valid (!n_cmd_empty), .cmd (n_cmd), .cmd_pop (n_cmd_pop),
    .tx_valid (!n_tx_empty), .tx_data (n_tx_data), .tx_pop (n_tx_pop),
    .rx_ready (!n_rx_full), .rx_push (n_rx_push), .rx_data (n_rx_data),
    .cpl_ready (!n_cpl_full), .cpl_push (n_cpl_push), .cpl (n_cpl),
    .wen_async (wen),
    .ce_n (ce_n), .cle (cle), .ale (ale), .we_n (we_n), .re_n (re_n), .wp_n (wp_n),
    .dq_o (dq_o), .dq_oe (dq_oe), .dq_i (dq_i), .rb_n (rb_n)
  );

  // ---------------------------------------------------------------------------
  // Page buffer
  // ---------------------------------------------------------------------------
  logic        x_re, x_rgnt, x_wgnt;
  logic [9:0]  x_raddr, x_waddr;
  logic [63:0] x_rdata, x_wdata;
  logic [7:0]  x_we;

  nand_pbuf #(.WORDS(1024), .IDW(IDW)) u_pbuf (
    .clk (clk), .rst_n (rst_n),
    .s_awid (s_awid), .s_awaddr (s_awaddr), .s_awlen (s_awlen), .s_awvalid (s_awvalid),
    .s_awready (s_awready), .s_wdata (s_wdata), .s_wstrb (s_wstrb), .s_wlast (s_wlast),
    .s_wvalid (s_wvalid), .s_wready (s_wready), .s_bid (s_bid), .s_bresp (s_bresp),
    .s_bvalid (s_bvalid), .s_bready (s_bready),
    .s_arid (s_arid), .s_araddr (s_araddr), .s_arlen (s_arlen), .s_arvalid (s_arvalid),
    .s_arready (s_arready), .s_rid (s_rid), .s_rdata (s_rdata), .s_rresp (s_rresp),
    .s_rlast (s_rlast), .s_rvalid (s_rvalid), .s_rready (s_rready),
    .x_re (x_re), .x_raddr (x_raddr), .x_rgnt (x_rgnt), .x_rdata (x_rdata),
    .x_we (x_we), .x_waddr (x_waddr), .x_wdata (x_wdata), .x_wgnt (x_wgnt)
  );

  // ---------------------------------------------------------------------------
  // Dispatcher and data mover
  // ---------------------------------------------------------------------------
  localparam logic [1:0] M_NONE = 2'd0, M_TX = 2'd1, M_RX = 2'd2;

  logic        d_run;
  logic [1:0]  s_mode;
  logic [12:0] s_ptr, s_left;
  // Program data: one buffer word at a time
  logic        w_valid, r_pend;
  logic [63:0] w_data;
  // Read data: bytes gathered into a word, then written
  logic [63:0] acc;
  logic [7:0]  am;
  logic [9:0]  aw;
  logic        a_pend;

  // Completion queue for firmware
  typedef struct packed {
    logic [7:0] tag;
    logic [1:0] code;
    logic [7:0] status;
  } fcpl_t;
  fcpl_t      cq_out;
  logic       cq_push, cq_full, cq_empty, cq_pop;
  logic [3:0] cq_count;

  logic [31:0] cyc, t0, cycles;
  logic [23:0] busy_time;
  logic [15:0] n_done, n_err;

  wire dispatch = !d_run && !q_empty && !x_cmd_full && (cq_count != 4'd8);
  assign q_pop      = dispatch;
  assign x_cmd_push = dispatch;
  assign x_cmd      = '{op: q_out.op, tag: q_out.tag, row: q_out.row, col: q_out.col, len: q_out.len,
                        twp: hwif_out.TIMING0.twp.value, twh: hwif_out.TIMING0.twh.value,
                        trp: hwif_out.TIMING0.trp.value, treh: hwif_out.TIMING0.treh.value,
                        twb: hwif_out.TIMING1.twb.value, twhr: hwif_out.TIMING1.twhr.value,
                        tadl: hwif_out.TIMING1.tadl.value, trr: hwif_out.TIMING1.trr.value,
                        tout: hwif_out.TIMEOUT.busy.value};

  // Program data: read a buffer word, then hand its bytes to the bus.
  assign x_re    = (s_mode == M_TX) && (s_left != 13'd0) && !w_valid && !r_pend;
  assign x_raddr = s_ptr[12:3];
  assign tx_push = (s_mode == M_TX) && w_valid && !tx_full;
  assign tx_byte = w_data[8 * s_ptr[2:0] +: 8];

  // Read data: gather bytes, write a word when it is complete or the data ends.
  assign rx_pop  = (s_mode == M_RX) && (s_left != 13'd0) && !rx_empty && !a_pend;
  assign x_we    = a_pend ? am : 8'd0;
  assign x_waddr = aw;
  assign x_wdata = acc;

  wire s_done   = (s_left == 13'd0) && !a_pend && !w_valid && !r_pend;
  wire complete = d_run && !x_cpl_empty && (s_done || (x_cpl.code != CODE_OK));
  assign x_cpl_pop = complete;
  assign cq_push   = complete;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      d_run     <= 1'b0;
      s_mode    <= M_NONE;
      s_ptr     <= 13'd0;
      s_left    <= 13'd0;
      w_valid   <= 1'b0;
      r_pend    <= 1'b0;
      w_data    <= 64'd0;
      acc       <= 64'd0;
      am        <= 8'd0;
      aw        <= 10'd0;
      a_pend    <= 1'b0;
      cyc       <= 32'd0;
      t0        <= 32'd0;
      cycles    <= 32'd0;
      busy_time <= 24'd0;
      n_done    <= 16'd0;
      n_err     <= 16'd0;
    end else begin
      cyc <= cyc + 32'd1;

      if (dispatch) begin
        d_run  <= 1'b1;
        t0     <= cyc;
        s_ptr  <= q_out.off;
        case (q_out.op)
          OP_PROG:                   begin s_mode <= M_TX; s_left <= q_out.len; end
          OP_ID, OP_READ, OP_RDCOL:  begin s_mode <= M_RX; s_left <= q_out.len; end
          default:                   begin s_mode <= M_NONE; s_left <= 13'd0; end
        endcase
      end

      // Program data
      if (x_rgnt) r_pend <= 1'b1;
      if (r_pend) begin
        r_pend  <= 1'b0;
        w_data  <= x_rdata;
        w_valid <= 1'b1;
      end
      if (tx_push) begin
        s_ptr  <= s_ptr + 13'd1;
        s_left <= s_left - 13'd1;
        if (s_ptr[2:0] == 3'd7 || s_left == 13'd1) w_valid <= 1'b0;
      end

      // Read data
      if (rx_pop) begin
        acc[8 * s_ptr[2:0] +: 8] <= rx_byte;
        am[s_ptr[2:0]]           <= 1'b1;
        aw                       <= s_ptr[12:3];
        s_ptr                    <= s_ptr + 13'd1;
        s_left                   <= s_left - 13'd1;
        if (s_ptr[2:0] == 3'd7 || s_left == 13'd1) a_pend <= 1'b1;
      end
      if (x_wgnt) begin
        a_pend <= 1'b0;
        am     <= 8'd0;
      end

      // Completion: after the data has moved, or at once if the command failed.
      if (complete) begin
        d_run     <= 1'b0;
        s_mode    <= M_NONE;
        s_left    <= 13'd0;
        w_valid   <= 1'b0;
        r_pend    <= 1'b0;
        a_pend    <= 1'b0;
        am        <= 8'd0;
        cycles    <= cyc - t0;
        busy_time <= x_cpl.busy;
        n_done    <= n_done + 16'd1;
        if (x_cpl.code != CODE_OK) n_err <= n_err + 16'd1;
      end
    end
  end

  assign cq_pop = hwif_out.CPL.tag.swacc && !cq_empty;

  fcpl_t cq_in;
  assign cq_in = '{tag: x_cpl.tag, code: x_cpl.code, status: x_cpl.status};

  fifo_sync #(.WIDTH($bits(fcpl_t)), .DEPTH(8)) u_cq (
    .clk (clk), .rst_n (rst_n), .push (cq_push), .din (cq_in), .full (cq_full),
    .pop (cq_pop), .dout (cq_out), .empty (cq_empty)
  );

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) cq_count <= 4'd0;
    else        cq_count <= cq_count + {3'd0, cq_push} - {3'd0, cq_pop};
  end

  // ---------------------------------------------------------------------------
  // Register inputs, interrupts
  // ---------------------------------------------------------------------------
  always_comb begin
    hwif_in.STATUS.busy.next     = d_run;
    hwif_in.STATUS.rb.next       = rb_sys;
    hwif_in.STATUS.cmds.next     = q_count;
    hwif_in.STATUS.cpls.next     = cq_count;
    hwif_in.EVENT.err.hwset      = complete && (x_cpl.code != CODE_OK);
    hwif_in.EVENT.ovf.hwset      = go && q_full;
    hwif_in.CPL.tag.next         = cq_empty ? 8'd0 : cq_out.tag;
    hwif_in.CPL.code.next        = cq_empty ? 2'd0 : cq_out.code;
    hwif_in.CPL.status.next      = cq_empty ? 8'd0 : cq_out.status;
    hwif_in.CPL.valid.next       = !cq_empty;
    hwif_in.CYCLES.count.next    = cycles;
    hwif_in.BUSY_TIME.count.next = busy_time;
    hwif_in.COUNT.done.next      = n_done;
    hwif_in.COUNT.err.next       = n_err;
  end

  assign irq_done = hwif_out.CTRL.ien_done.value && !cq_empty;
  assign irq_err  = hwif_out.CTRL.ien_err.value &&
                    (hwif_out.EVENT.err.value || hwif_out.EVENT.ovf.value);

  /* verilator lint_off UNUSEDSIGNAL */
  wire unused_ok = ^{cq_full};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule : nand_ctrl

`default_nettype wire
