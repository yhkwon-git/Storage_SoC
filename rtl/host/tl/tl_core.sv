`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// tl_core
//
// Transaction layer of the host interface, in clk_sys (docs/10_transaction_
// layer.md). Packed TLPs come in from the link side and go out to it; the
// SoC side is AXI4 master port M3 and the HOST registers' signals.
//
//   receive     tl_rx_buf (store and forward, malformed TLPs removed whole)
//               -> tl_rx_unpack -> register slice -> dispatcher
//   dispatcher  one TLP at a time, in arrival order:
//                 MWr   BAR2: tl_wr (AXI, owner 0)
//                       BAR0 0x0000-0x1FFF: the register port (rp_*), one DW
//                       per clock (step 2-2: the NVMe controller's registers)
//                       BAR0 0x2000-0x3FFF: MSI-X table and PBA (tl_msix)
//                 MRd   BAR2: completion job MEM (tl_rd)
//                       BAR0: completion job DATA from the register port or
//                       the MSI-X table; at most 2 DWs (CA beyond)
//                 CfgRd0/CfgWr0 to function 0: tl_cfg, completion job
//                 Cpl/CplD: tl_bm checks it; good data goes to tl_wr (owner 1)
//                 Msg: dropped
//                 a request the endpoint does not support (I/O, type 1
//                 configuration, locked read, atomics, memory outside the
//                 BARs or with Memory Space Enable clear): UR, with a
//                 completion when it is non-posted
//                 a poisoned write: dropped (a configuration write gets UR)
//                 an MWr longer than Max_Payload_Size, byte enables against
//                 the rules, a request across 4 KiB, a configuration request
//                 that is not one DW, an unknown type: malformed, dropped
//   transmit    tl_rd (completions) and tl_bm (requests, MSI-X) share
//               tl_tx_pack. At each TLP boundary a posted request goes
//               first, then a completion, then a non-posted request; so no
//               completion or read passes a posted write, and a posted write
//               may pass both, which the ordering rules allow.
//   AXI         AW/W/B from tl_wr (ID 0); AR from tl_rd (ID 0) and tl_bm
//               (ID 1), R routed back by ID; RREADY is always high. AW, W
//               and AR leave through register slices.
//   bus master  two requesters: the HOST registers (bm_start; a START while
//               the bus master is taken waits) and the NVMe controller
//               (nv_*), served alternately when both wait; done goes back to
//               the one that asked.
// -----------------------------------------------------------------------------

module tl_core #(
  parameter int RXBUF_DEPTH = 64,
  parameter int NTAG        = 16
) (
  input  wire           clk,
  input  wire           rst_n,

  // Packed TLPs from the link side
  input  wire           rxp_valid,
  output logic          rxp_ready,
  input  wire  [63:0]   rxp_data,
  input  wire           rxp_sop,
  input  wire           rxp_eop,
  input  wire           rxp_ehalf,
  input  wire           rxp_bad,

  // Packed TLPs to the link side
  output logic          txp_valid,
  input  wire           txp_ready,
  output logic [63:0]   txp_data,
  output logic          txp_sop,
  output logic          txp_eop,
  output logic          txp_ehalf,

  // AXI4 master (M3), 2-bit IDs
  output logic [1:0]    m_awid,
  output logic [31:0]   m_awaddr,
  output logic [7:0]    m_awlen,
  output logic [2:0]    m_awsize,
  output logic [1:0]    m_awburst,
  output logic          m_awvalid,
  input  wire           m_awready,
  output logic [63:0]   m_wdata,
  output logic [7:0]    m_wstrb,
  output logic          m_wlast,
  output logic          m_wvalid,
  input  wire           m_wready,
  input  wire  [1:0]    m_bid,
  input  wire  [1:0]    m_bresp,
  input  wire           m_bvalid,
  output logic          m_bready,
  output logic [1:0]    m_arid,
  output logic [31:0]   m_araddr,
  output logic [7:0]    m_arlen,
  output logic [2:0]    m_arsize,
  output logic [1:0]    m_arburst,
  output logic          m_arvalid,
  input  wire           m_arready,
  input  wire  [1:0]    m_rid,
  input  wire  [63:0]   m_rdata,
  input  wire  [1:0]    m_rresp,
  input  wire           m_rlast,
  input  wire           m_rvalid,
  output logic          m_rready,

  // Register port: BAR0 0x0000-0x1FFF (the NVMe controller's registers)
  output logic          rp_we,
  output logic [10:0]   rp_dw,
  output logic [3:0]    rp_be,
  output logic [31:0]   rp_wdata,
  input  wire  [31:0]   rp_rd0,       // DW rp_dw
  input  wire  [31:0]   rp_rd1,       // DW rp_dw + 1

  // Bus-master requests of the NVMe controller
  input  wire           nv_valid,
  output logic          nv_ready,
  input  wire           nv_d2h,
  input  wire  [63:2]   nv_haddr,
  input  wire  [31:2]   nv_laddr,
  input  wire  [17:0]   nv_len,
  output logic          nv_done,      // pulse
  output logic [2:0]    nv_cause,

  // HOST registers
  input  wire  [31:15]  bar2_win,     // AXI base of BAR2
  input  wire  [7:0]    cto_ticks,
  input  wire           bm_start,
  input  wire           bm_d2h,
  input  wire  [63:2]   bm_haddr,
  input  wire  [31:2]   bm_laddr,
  input  wire  [17:0]   bm_len,
  output logic          bm_done,      // pulse
  output logic [2:0]    bm_cause,
  output logic          bm_busy,      // a HOST-register transfer waits or runs
  input  wire           msix_req,     // pulse
  input  wire  [2:0]    msix_vec,

  output logic          st_mse,
  output logic          st_bme,
  output logic          st_msix_en,
  output logic          st_msix_fmask,
  output logic          st_mps256,
  output logic [2:0]    st_mrrs,
  output logic [15:0]   st_id,
  output logic [7:0]    st_msix_pend,

  // Events (pulses)
  output logic          ev_ur,        // unsupported request received
  output logic [1:0]    ev_malformed, // count this clock: receive buffer and dispatcher
  output logic          ev_poisoned,
  output logic          ev_unexp_cpl,
  output logic          ev_cpl_timeout,
  output logic          ev_cpl_err,   // UR or CA completion, or one failing the checks
  output logic          ev_axi_err,   // an inbound write or read got an AXI error
  output logic          ev_discard,   // a TLP removed by the link layer
  output logic          ev_msix_drop,
  output logic          rx_tlp,
  output logic          tx_tlp,
  output logic          idle
);

  import tl_pkg::*;

  // ---------------------------------------------------------------------------
  // Receive path
  // ---------------------------------------------------------------------------
  logic        b_valid, b_ready, b_eop, b_ehalf, b_sop;
  logic [63:0] b_data;
  logic        buf_malformed;

  tl_rx_buf #(.DEPTH(RXBUF_DEPTH), .MAX_PAY_DW(64)) u_rxbuf (
    .clk (clk), .rst_n (rst_n),
    .in_valid (rxp_valid), .in_ready (rxp_ready), .in_data (rxp_data), .in_sop (rxp_sop),
    .in_eop (rxp_eop), .in_ehalf (rxp_ehalf), .in_bad (rxp_bad),
    .out_valid (b_valid), .out_ready (b_ready), .out_data (b_data), .out_sop (b_sop),
    .out_eop (b_eop), .out_ehalf (b_ehalf),
    .malformed (buf_malformed), .discarded (ev_discard)
  );

  logic         p_valid, p_ready, p_hdr, p_last;
  logic [127:0] p_data;
  logic [1:0]   p_dwv;

  tl_rx_unpack u_unpack (
    .clk (clk), .rst_n (rst_n),
    .in_valid (b_valid), .in_ready (b_ready), .in_data (b_data), .in_eop (b_eop),
    .in_ehalf (b_ehalf),
    .out_valid (p_valid), .out_ready (p_ready), .out_hdr (p_hdr), .out_data (p_data),
    .out_dwv (p_dwv), .out_last (p_last)
  );

  logic         u_valid, u_ready, u_hdr, u_last;
  logic [127:0] u_data;
  logic [1:0]   u_dwv;

  axi_channel_reg_slice #(.WIDTH(132)) u_rx_slice (
    .aclk (clk), .aresetn (rst_n),
    .s_valid (p_valid), .s_ready (p_ready), .s_data ({p_hdr, p_last, p_dwv, p_data}),
    .m_valid (u_valid), .m_ready (u_ready), .m_data ({u_hdr, u_last, u_dwv, u_data})
  );

  // ---------------------------------------------------------------------------
  // Header fields of the TLP at the dispatcher: the header beat itself while
  // the dispatcher waits for one, its copy while the payload follows.
  // ---------------------------------------------------------------------------
  typedef enum logic [2:0] {D_IDLE, D_PAY, D_DRAIN, D_CFGW, D_MSIXW} dst_t;
  dst_t         d_st;
  logic [127:0] hq;
  logic         d_cfgw_lane;
  logic [3:0]   d_fbe, d_lbe;

  wire [127:0] hcur = (d_st == D_IDLE) ? u_data : hq;
  wire [31:0]  dw0  = hcur[31:0];
  wire [31:0]  dw1  = hcur[63:32];
  wire [31:0]  dw2  = hcur[95:64];
  wire [31:0]  dw3  = hcur[127:96];

  wire [2:0]  fmt  = dw0[31:29];
  wire [4:0]  ty   = dw0[28:24];
  wire [2:0]  tc   = dw0[22:20];
  wire        ep   = dw0[14];
  wire [1:0]  attr = dw0[13:12];
  wire [10:0] len  = h_len(dw0);
  wire        is4  = fmt[0];
  wire        dat  = fmt[1];

  wire [15:0] rq_id = dw1[31:16];
  wire [7:0]  rq_tag = dw1[15:8];
  wire [3:0]  lbe  = dw1[7:4];
  wire [3:0]  fbe  = dw1[3:0];
  wire [63:0] addr = is4 ? {dw2, dw3[31:2], 2'b00} : {32'd0, dw2[31:2], 2'b00};

  // Settings from configuration space
  logic        mse, bme, mps256, msix_en, msix_fmask, cto_dis;
  logic [2:0]  mrrs;
  logic [63:0] bar0, bar2;
  logic [15:0] my_id;

  wire bar0_hit = mse && (addr[63:14] == bar0[63:14]);
  wire bar2_hit = mse && (addr[63:15] == bar2[63:15]);
  wire hit      = bar0_hit || bar2_hit;
  wire in_msix  = bar0_hit && addr[13];          // else BAR0 is the register port
  wire [31:0] axi_addr = {bar2_win, addr[14:0]};

  wire be_bad  = (len == 11'd1) ? (lbe != 4'd0) : ((fbe == 4'd0) || (lbe == 4'd0));
  wire [10:0] end_dw = {1'b0, addr[11:2]} + len - 11'd1;
  wire x4k     = end_dw[10];
  wire too_big = (len > (mps256 ? 11'd64 : 11'd32));

  // Classes
  wire f_nd = (fmt == FMT_3DW) || (fmt == FMT_4DW);
  wire f_d  = (fmt == FMT_3DW_D) || (fmt == FMT_4DW_D);
  wire c_memrd  = f_nd && (ty == TY_MEM);
  wire c_memwr  = f_d  && (ty == TY_MEM);
  wire c_cfgrd  = (fmt == FMT_3DW)   && (ty == TY_CFG0);
  wire c_cfgwr  = (fmt == FMT_3DW_D) && (ty == TY_CFG0);
  wire c_cpl    = ((fmt == FMT_3DW) || (fmt == FMT_3DW_D)) && (ty == TY_CPL);
  wire c_cpllk  = ((fmt == FMT_3DW) || (fmt == FMT_3DW_D)) && (ty == TY_CPLLK);
  wire c_msg    = ((fmt == FMT_4DW) || (fmt == FMT_4DW_D)) && (ty[4:3] == 2'b10);
  wire c_np_ur  = (f_nd && (ty == TY_MEMLK)) ||
                  (((fmt == FMT_3DW) || (fmt == FMT_3DW_D)) && ((ty == TY_IO) || (ty == TY_CFG1))) ||
                  (f_d && ((ty == 5'b01100) || (ty == 5'b01101) || (ty == 5'b01110)));

  wire cfg_bad = (len != 11'd1) || (lbe != 4'd0);
  wire cfg_fn0 = (dw2[18:16] == 3'd0);

  // ---------------------------------------------------------------------------
  // Blocks
  // ---------------------------------------------------------------------------
  // Configuration space
  logic        cfg_acc, cfg_wr;
  logic [31:0] cfg_rdata, cfg_wdata;
  logic        ev_sig_ta, ev_rcv_ta, ev_rcv_ma, ev_par_c, ev_par_r, ev_timeout, ev_unexp, ev_badcpl;
  logic        ev_ur_d, ev_mal_d, ev_axi_w;

  tl_cfg u_cfg (
    .clk (clk), .rst_n (rst_n),
    .acc (cfg_acc), .wr (cfg_wr), .idx ({dw2[11:8], dw2[7:2]}), .be (fbe), .wdata (cfg_wdata),
    .wr_id (dw2[31:16]), .rdata (cfg_rdata),
    .mse (mse), .bme (bme), .bar0 (bar0), .bar2 (bar2), .mps256 (mps256), .mrrs (mrrs),
    .msix_en (msix_en), .msix_fmask (msix_fmask), .cto_dis (cto_dis), .my_id (my_id),
    .ev_sig_ta (ev_sig_ta), .ev_rcv_ta (ev_rcv_ta), .ev_rcv_ma (ev_rcv_ma),
    .ev_par (ev_par_c || ev_par_r), .ev_ur (ev_ur_d),
    .ev_nonfatal (ev_ur_d || ev_par_c || ev_par_r || ev_timeout || ev_unexp || ev_sig_ta),
    .ev_fatal (ev_mal_d || buf_malformed), .tx_pending (!bm_req_ready)
  );

  // MSI-X
  logic        mx_we;
  logic [9:0]  mx_dw;
  logic [3:0]  mx_be;
  logic [31:0] mx_wdata, mx_rd0, mx_rd1;
  logic        msg_valid, msg_ready;
  logic [63:0] msg_addr;
  logic [31:0] msg_data;
  logic        mx_idle;

  tl_msix #(.N_VEC(8)) u_msix (
    .clk (clk), .rst_n (rst_n),
    .acc_we (mx_we), .acc_pba (addr[12]), .acc_dw (mx_dw), .acc_be (mx_be),
    .acc_wdata (mx_wdata), .rd_dw0 (mx_rd0), .rd_dw1 (mx_rd1),
    .en (msix_en), .fmask (msix_fmask), .bme (bme),
    .req_valid (msix_req), .req_vec (msix_vec), .req_drop (ev_msix_drop),
    .msg_valid (msg_valid), .msg_ready (msg_ready), .msg_addr (msg_addr), .msg_data (msg_data),
    .pending (st_msix_pend), .idle (mx_idle)
  );

  // Write engine
  logic        wj_valid, wj_ready, wj_owner;
  logic [31:0] wj_addr;
  logic [10:0] wj_len;
  logic [3:0]  wj_fbe, wj_lbe, wj_tag;
  logic        wp_valid, wp_ready;
  logic        wd_valid, wd_owner, wd_err;
  logic [3:0]  wd_tag;
  logic [7:0]  wr_acc, wr_done;
  logic        wr_idle;
  logic [31:0] aw_addr;
  logic [7:0]  aw_len;
  logic [2:0]  aw_size;
  logic        aw_valid, aw_ready, w_valid, w_ready, w_last;
  logic [63:0] w_data;
  logic [7:0]  w_strb;

  tl_wr u_wr (
    .clk (clk), .rst_n (rst_n),
    .job_valid (wj_valid), .job_ready (wj_ready), .job_addr (wj_addr), .job_len (wj_len),
    .job_fbe (wj_fbe), .job_lbe (wj_lbe), .job_owner (wj_owner),
    .job_tag (wj_tag),
    .pay_valid (wp_valid), .pay_ready (wp_ready), .pay_data (u_data[63:0]), .pay_dwv (u_dwv),
    .pay_last (u_last),
    .m_awaddr (aw_addr), .m_awlen (aw_len), .m_awsize (aw_size), .m_awvalid (aw_valid),
    .m_awready (aw_ready),
    .m_wdata (w_data), .m_wstrb (w_strb), .m_wlast (w_last), .m_wvalid (w_valid),
    .m_wready (w_ready),
    .m_bresp (m_bresp), .m_bvalid (m_bvalid), .m_bready (m_bready),
    .done_valid (wd_valid), .done_owner (wd_owner), .done_tag (wd_tag), .done_err (wd_err),
    .jobs_acc (wr_acc), .jobs_done (wr_done), .idle (wr_idle)
  );

  // Completer
  logic        cj_valid, cj_ready;
  logic [1:0]  cj_kind;
  logic [2:0]  cj_status;
  logic [6:0]  cj_la;
  logic [12:0] cj_bc;
  logic [10:0] cj_len;
  logic [63:0] cj_data;
  logic        rd_arvalid, rd_arready, rd_rvalid;
  logic [31:0] rd_araddr;
  logic [7:0]  rd_arlen;
  logic [2:0]  rd_arsize;
  logic         rt_valid, rt_ready, rt_hdr, rt_last;
  logic [127:0] rt_data;
  logic [1:0]   rt_dwv;
  logic         rd_idle;

  tl_rd u_rd (
    .clk (clk), .rst_n (rst_n),
    .cj_valid (cj_valid), .cj_ready (cj_ready), .cj_kind (cj_kind), .cj_status (cj_status),
    .cj_req_id (rq_id), .cj_tag (rq_tag), .cj_tc (tc), .cj_attr (attr), .cj_la (cj_la),
    .cj_bc (cj_bc), .cj_len (cj_len), .cj_data (cj_data), .cj_axi (axi_addr[31:2]),
    .cj_fence (wr_acc),
    .wr_jobs_done (wr_done), .my_id (my_id),
    .m_arvalid (rd_arvalid), .m_arready (rd_arready), .m_araddr (rd_araddr),
    .m_arlen (rd_arlen), .m_arsize (rd_arsize),
    .m_rvalid (rd_rvalid), .m_rdata (m_rdata), .m_rresp (m_rresp), .m_rlast (m_rlast),
    .tx_valid (rt_valid), .tx_ready (rt_ready), .tx_hdr (rt_hdr), .tx_data (rt_data),
    .tx_dwv (rt_dwv), .tx_last (rt_last),
    .ev_sig_ta (ev_sig_ta), .idle (rd_idle)
  );

  // Bus master
  logic         c_valid, c_write;
  logic [31:2]  c_laddr;
  logic         bm_arvalid, bm_arready, bm_rvalid;
  logic [31:0]  bm_araddr;
  logic [7:0]   bm_arlen;
  logic [2:0]   bm_arsize;
  logic         bt_valid, bt_ready, bt_hdr, bt_last, bt_posted;
  logic [127:0] bt_data;
  logic [1:0]   bt_dwv;
  logic         bm_idle, bm_req_ready;

  // Requesters: a HOST-register START waits in csr_pend until the bus master
  // is free; the NVMe controller holds nv_valid. When both wait they take
  // turns. done goes to the owner of the running request.
  logic        csr_pend, csr_run, own_nv, last_nv;
  logic        q_done, q_busy;
  logic [2:0]  q_cause;
  wire  grant_nv  = bm_req_ready && nv_valid && (!csr_pend || !last_nv);
  wire  grant_csr = bm_req_ready && csr_pend && !grant_nv;

  assign nv_ready = grant_nv;
  assign nv_done  = q_done && own_nv;
  assign nv_cause = q_cause;
  assign bm_done  = q_done && !own_nv;
  assign bm_cause = q_cause;
  assign bm_busy  = csr_pend || csr_run;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      csr_pend <= 1'b0;
      csr_run  <= 1'b0;
      own_nv   <= 1'b0;
      last_nv  <= 1'b0;
    end else begin
      if (bm_start && !csr_pend && !csr_run) csr_pend <= 1'b1;
      if (grant_csr) begin
        csr_pend <= 1'b0;
        csr_run  <= 1'b1;
        own_nv   <= 1'b0;
        last_nv  <= 1'b0;
      end else if (grant_nv) begin
        own_nv  <= 1'b1;
        last_nv <= 1'b1;
      end
      if (q_done && !own_nv) csr_run <= 1'b0;
    end
  end

  tl_bm #(.NTAG(NTAG)) u_bm (
    .clk (clk), .rst_n (rst_n),
    .req_valid (grant_nv || grant_csr), .req_ready (bm_req_ready),
    .req_d2h   (grant_nv ? nv_d2h   : bm_d2h),
    .req_haddr (grant_nv ? nv_haddr : bm_haddr),
    .req_laddr (grant_nv ? nv_laddr : bm_laddr),
    .req_len   (grant_nv ? nv_len   : bm_len),
    .done_valid (q_done), .done_cause (q_cause), .busy (q_busy),
    .bme (bme), .mps256 (mps256), .mrrs (mrrs), .my_id (my_id), .cto_dis (cto_dis),
    .cto_ticks (cto_ticks),
    .msg_valid (msg_valid), .msg_ready (msg_ready), .msg_addr (msg_addr), .msg_data (msg_data),
    .c_valid (c_valid), .c_tag (dw2[15:8]), .c_req_id (dw2[31:16]), .c_status (dw1[15:13]),
    .c_bc (dw1[11:0]), .c_la (dw2[6:0]), .c_len (dat ? len : 11'd0), .c_data (dat),
    .c_ep (ep), .c_write (c_write), .c_laddr (c_laddr),
    .wd_valid (wd_valid && wd_owner), .wd_err (wd_err),
    .m_arvalid (bm_arvalid), .m_arready (bm_arready), .m_araddr (bm_araddr),
    .m_arlen (bm_arlen), .m_arsize (bm_arsize),
    .m_rvalid (bm_rvalid), .m_rdata (m_rdata), .m_rresp (m_rresp), .m_rlast (m_rlast),
    .tx_valid (bt_valid), .tx_ready (bt_ready), .tx_hdr (bt_hdr), .tx_data (bt_data),
    .tx_dwv (bt_dwv), .tx_last (bt_last), .tx_posted (bt_posted),
    .ev_rcv_ma (ev_rcv_ma), .ev_rcv_ta (ev_rcv_ta), .ev_unexp (ev_unexp),
    .ev_timeout (ev_timeout), .ev_badcpl (ev_badcpl), .ev_par (ev_par_r), .idle (bm_idle)
  );

  // ---------------------------------------------------------------------------
  // Dispatcher
  // ---------------------------------------------------------------------------
  logic [10:0] d_mxdw;     // BAR0 write: DW (BAR0 offset bits 12:2) of the next payload DW
  logic        d_mxfirst;  // BAR0 write: the next DW is the TLP's first
  logic        d_mxhalf;   // BAR0 write: lane 0 of this beat is done
  logic        d_cfg_ur;   // configuration write that gets UR

  // Action of the header at the dispatcher, decided combinationally.
  typedef enum logic [3:0] {
    A_NONE, A_MAL, A_DROP, A_UR_P, A_UR_NP, A_WR, A_MXW, A_MXW_BAD, A_RD, A_MXR, A_CA_NP,
    A_CFGRD, A_CFGWR, A_CPL
  } act_t;
  act_t act;

  always_comb begin
    act = A_MAL;
    if (c_memwr) begin
      if (be_bad || x4k || too_big) act = A_MAL;
      else if (!hit)                act = A_UR_P;
      else if (ep)                  act = A_DROP;
      else if (bar0_hit)            act = (len <= 11'd2) ? A_MXW : A_MXW_BAD;
      else                          act = A_WR;
    end else if (c_memrd) begin
      if (be_bad || x4k)            act = A_MAL;
      else if (!hit)                act = A_UR_NP;
      else if (bar0_hit)            act = (len <= 11'd2) ? A_MXR : A_CA_NP;
      else                          act = A_RD;
    end else if (c_cfgrd) begin
      if (cfg_bad)                  act = A_MAL;
      else if (!cfg_fn0)            act = A_UR_NP;
      else                          act = A_CFGRD;
    end else if (c_cfgwr) begin
      if (cfg_bad)                  act = A_MAL;
      else                          act = A_CFGWR;  // UR for function != 0 or poisoned
    end else if (c_cpl) begin
      act = A_CPL;
    end else if (c_cpllk || c_msg) begin
      act = A_DROP;
    end else if (c_np_ur) begin
      act = A_UR_NP;
    end
  end

  // Completion job contents
  wire [6:0]  mem_la = {addr[6:2], low_off(fbe)};
  wire [12:0] mem_bc = req_bytes(len, fbe, lbe);
  always_comb begin
    cj_kind   = 2'd2;  // NODATA
    cj_status = CS_SC;
    cj_la     = 7'd0;
    cj_bc     = 13'd4;
    cj_len    = 11'd1;
    cj_data   = in_msix ? {mx_rd1, mx_rd0} : {rp_rd1, rp_rd0};
    case (act)
      A_RD:    begin cj_kind = 2'd0; cj_la = mem_la; cj_bc = mem_bc; cj_len = len; end
      A_MXR:   begin cj_kind = 2'd1; cj_la = mem_la; cj_bc = mem_bc; cj_len = len; end
      A_CA_NP: begin cj_status = CS_CA; cj_la = mem_la; cj_bc = mem_bc; end
      A_UR_NP: begin
        cj_status = CS_UR;
        if (c_memrd) begin cj_la = mem_la; cj_bc = mem_bc; end
      end
      A_CFGRD: begin cj_kind = 2'd1; cj_data = {32'd0, cfg_rdata}; end
      A_CFGWR: cj_status = d_cfg_ur ? CS_UR : CS_SC;  // pushed from D_CFGW
      default: ;
    endcase
  end

  wire hdr_here = u_valid && u_hdr && (d_st == D_IDLE);

  // Needs of each action
  wire need_cj = (act == A_RD) || (act == A_MXR) || (act == A_CA_NP) || (act == A_UR_NP) ||
                 (act == A_CFGRD) || (act == A_CFGWR);
  wire need_wj = (act == A_WR) || (act == A_CPL);
  wire can_go  = (!need_cj || cj_ready) && (!need_wj || wj_ready);
  wire go      = hdr_here && can_go;

  // Write job: inbound write, or completion data for the bus master.
  assign wj_valid = go && ((act == A_WR) || (act == A_CPL && c_write));
  assign wj_addr  = (act == A_CPL) ? {c_laddr, 2'b00} : axi_addr;
  assign wj_len   = len;
  assign wj_fbe   = (act == A_CPL) ? 4'hF : fbe;
  assign wj_lbe   = (act == A_CPL) ? ((len == 11'd1) ? 4'h0 : 4'hF) : lbe;
  assign wj_owner = (act == A_CPL);
  assign wj_tag   = dw2[11:8];
  assign c_valid  = go && (act == A_CPL);

  // Completion job: pushed with the header, except a configuration write's,
  // which follows its payload.
  assign cj_valid = (go && need_cj && (act != A_CFGWR)) ||
                    ((d_st == D_CFGW) && u_valid && !u_hdr);

  // Configuration access
  wire        cfgw_dw_lane = h_lane0(hcur);
  assign cfg_acc   = (go && act == A_CFGRD) ||
                     ((d_st == D_CFGW) && u_valid && !u_hdr && !d_cfg_ur);
  assign cfg_wr    = (d_st == D_CFGW);
  assign cfg_wdata = d_cfgw_lane ? u_data[63:32] : u_data[31:0];

  // BAR0 access, to the MSI-X table (offset bit 13 set) or the register port:
  // reads from the header's DW, writes one DW per clock.
  wire mx_lane0_v = u_dwv[0] && !d_mxhalf;
  wire [31:0] mx_dw_data = mx_lane0_v ? u_data[31:0] : u_data[63:32];
  wire bar0_w     = (d_st == D_MSIXW) && u_valid && !u_hdr;
  assign mx_we    = bar0_w && in_msix;
  assign mx_dw    = (d_st == D_MSIXW) ? d_mxdw[9:0] : addr[11:2];
  assign mx_be    = d_mxfirst ? d_fbe : d_lbe;
  assign mx_wdata = mx_dw_data;
  assign rp_we    = bar0_w && !in_msix;
  assign rp_dw    = (d_st == D_MSIXW) ? d_mxdw : addr[12:2];
  assign rp_be    = mx_be;
  assign rp_wdata = mx_dw_data;

  // A beat in D_MSIXW is taken when its last valid lane has been written.
  wire mx_beat_done = !(mx_lane0_v && u_dwv[1]);

  assign wp_valid = (d_st == D_PAY) && u_valid && !u_hdr;

  always_comb begin
    u_ready = 1'b0;
    case (d_st)
      D_IDLE:  u_ready = u_valid && (!u_hdr || can_go);   // a stray payload beat is dropped
      D_PAY:   u_ready = wp_ready;
      D_DRAIN: u_ready = 1'b1;
      D_CFGW:  u_ready = cj_ready;
      default: u_ready = mx_beat_done;                    // D_MSIXW
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      hq          <= 128'd0;
      d_st        <= D_IDLE;
      d_mxdw      <= 11'd0;
      d_mxfirst   <= 1'b0;
      d_mxhalf    <= 1'b0;
      d_cfg_ur    <= 1'b0;
      d_cfgw_lane <= 1'b0;
      d_fbe       <= 4'd0;
      d_lbe       <= 4'd0;
    end else begin
      case (d_st)
        D_IDLE: if (go) begin
          hq    <= u_data;
          d_fbe <= fbe;
          d_lbe <= lbe;
          if (!u_last) begin
            case (act)
              A_WR:    d_st <= D_PAY;
              A_CPL:   d_st <= c_write ? D_PAY : D_DRAIN;
              A_MXW: begin
                d_st      <= D_MSIXW;
                d_mxdw    <= addr[12:2];
                d_mxfirst <= 1'b1;
                d_mxhalf  <= 1'b0;
              end
              A_CFGWR: begin
                d_st        <= D_CFGW;
                d_cfg_ur    <= ep || !cfg_fn0;
                d_cfgw_lane <= cfgw_dw_lane;
              end
              default: d_st <= D_DRAIN;
            endcase
          end
        end
        D_PAY:   if (u_valid && u_ready && u_last) d_st <= D_IDLE;
        D_DRAIN: if (u_valid && u_last) d_st <= D_IDLE;
        D_CFGW:  if (u_valid && u_ready) d_st <= u_last ? D_IDLE : D_DRAIN;
        default: begin  // D_MSIXW
          if (u_valid) begin
            d_mxdw    <= d_mxdw + 11'd1;
            d_mxfirst <= 1'b0;
            d_mxhalf  <= mx_lane0_v && u_dwv[1];
            if (mx_beat_done && u_last) d_st <= D_IDLE;
          end
        end
      endcase
    end
  end

  // Events from the dispatcher
  assign ev_ur_d  = go && ((act == A_UR_P) || (act == A_UR_NP) || (act == A_MXW_BAD));
  assign ev_mal_d = go && (act == A_MAL);
  assign ev_par_c = go && (act == A_DROP) && c_memwr;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ev_ur <= 1'b0; ev_malformed <= 2'd0; ev_poisoned <= 1'b0; ev_unexp_cpl <= 1'b0;
      ev_cpl_timeout <= 1'b0; ev_cpl_err <= 1'b0; ev_axi_err <= 1'b0; rx_tlp <= 1'b0;
      tx_tlp <= 1'b0;
    end else begin
      ev_ur          <= ev_ur_d || ((d_st == D_CFGW) && cj_valid && cj_ready && d_cfg_ur);
      ev_malformed   <= {1'b0, ev_mal_d} + {1'b0, buf_malformed};
      ev_poisoned    <= ev_par_c || ev_par_r;
      ev_unexp_cpl   <= ev_unexp || (go && c_cpllk);
      ev_cpl_timeout <= ev_timeout;
      ev_cpl_err     <= ev_rcv_ma || ev_rcv_ta || ev_badcpl;
      ev_axi_err     <= ev_axi_w || ev_sig_ta;
      rx_tlp         <= go;
      tx_tlp         <= txp_valid && txp_ready && txp_sop;
    end
  end

  assign ev_axi_w = wd_valid && !wd_owner && wd_err;

  // ---------------------------------------------------------------------------
  // Transmit arbiter: posted, then completions, then non-posted
  // ---------------------------------------------------------------------------
  logic         t_busy, t_sel;   // in a TLP; 1 = bus master
  logic         tp_valid, tp_ready, tp_hdr, tp_last;
  logic [127:0] tp_data;
  logic [1:0]   tp_dwv;

  wire pick_bm = (bt_valid && bt_posted) ? 1'b1 : (rt_valid ? 1'b0 : bt_valid);
  wire sel     = t_busy ? t_sel : pick_bm;

  assign tp_valid = sel ? bt_valid : rt_valid;
  assign tp_hdr   = sel ? bt_hdr   : rt_hdr;
  assign tp_data  = sel ? bt_data  : rt_data;
  assign tp_dwv   = sel ? bt_dwv   : rt_dwv;
  assign tp_last  = sel ? bt_last  : rt_last;
  assign bt_ready = sel && tp_ready;
  assign rt_ready = !sel && tp_ready;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      t_busy <= 1'b0;
      t_sel  <= 1'b0;
    end else if (tp_valid && tp_ready) begin
      t_busy <= !tp_last;
      t_sel  <= sel;
    end
  end

  tl_tx_pack u_pack (
    .clk (clk), .rst_n (rst_n),
    .in_valid (tp_valid), .in_ready (tp_ready), .in_hdr (tp_hdr), .in_data (tp_data),
    .in_dwv (tp_dwv), .in_last (tp_last),
    .out_valid (txp_valid), .out_ready (txp_ready), .out_data (txp_data), .out_sop (txp_sop),
    .out_eop (txp_eop), .out_ehalf (txp_ehalf)
  );

  // ---------------------------------------------------------------------------
  // AXI port
  // ---------------------------------------------------------------------------
  axi_channel_reg_slice #(.WIDTH(43)) u_aw_slice (
    .aclk (clk), .aresetn (rst_n),
    .s_valid (aw_valid), .s_ready (aw_ready), .s_data ({aw_addr, aw_len, aw_size}),
    .m_valid (m_awvalid), .m_ready (m_awready), .m_data ({m_awaddr, m_awlen, m_awsize})
  );

  axi_channel_reg_slice #(.WIDTH(73)) u_w_slice (
    .aclk (clk), .aresetn (rst_n),
    .s_valid (w_valid), .s_ready (w_ready), .s_data ({w_data, w_strb, w_last}),
    .m_valid (m_wvalid), .m_ready (m_wready), .m_data ({m_wdata, m_wstrb, m_wlast})
  );

  // AR: the completer and the bus master, round robin. The choice holds while
  // its AR waits for READY, so the payload does not change under VALID.
  logic ar_last_bm, ar_lock, ar_lock_bm;
  wire  ar_pick_bm = ar_lock ? ar_lock_bm : (bm_arvalid && (!rd_arvalid || !ar_last_bm));
  logic ar_valid, ar_ready, ar_id;
  logic [31:0] ar_addr;
  logic [7:0]  ar_len;
  logic [2:0]  ar_size;

  assign ar_valid   = rd_arvalid || bm_arvalid;
  assign ar_id      = ar_pick_bm;
  assign ar_addr    = ar_pick_bm ? bm_araddr : rd_araddr;
  assign ar_len     = ar_pick_bm ? bm_arlen  : rd_arlen;
  assign ar_size    = ar_pick_bm ? bm_arsize : rd_arsize;
  assign rd_arready = ar_ready && !ar_pick_bm;
  assign bm_arready = ar_ready && ar_pick_bm;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ar_last_bm <= 1'b0;
      ar_lock    <= 1'b0;
      ar_lock_bm <= 1'b0;
    end else begin
      if (ar_valid && ar_ready) ar_last_bm <= ar_pick_bm;
      ar_lock    <= ar_valid && !ar_ready;
      ar_lock_bm <= ar_pick_bm;
    end
  end

  logic m_arid0;
  axi_channel_reg_slice #(.WIDTH(44)) u_ar_slice (
    .aclk (clk), .aresetn (rst_n),
    .s_valid (ar_valid), .s_ready (ar_ready), .s_data ({ar_id, ar_addr, ar_len, ar_size}),
    .m_valid (m_arvalid), .m_ready (m_arready), .m_data ({m_arid0, m_araddr, m_arlen, m_arsize})
  );

  assign m_awid    = 2'b00;
  assign m_awburst = 2'b01;
  assign m_arid    = {1'b0, m_arid0};
  assign m_arburst = 2'b01;
  assign m_rready  = 1'b1;
  assign rd_rvalid = m_rvalid && !m_rid[0];
  assign bm_rvalid = m_rvalid &&  m_rid[0];

  // ---------------------------------------------------------------------------
  // Status and idle
  // ---------------------------------------------------------------------------
  assign st_mse        = mse;
  assign st_bme        = bme;
  assign st_msix_en    = msix_en;
  assign st_msix_fmask = msix_fmask;
  assign st_mps256     = mps256;
  assign st_mrrs       = mrrs;
  assign st_id         = my_id;

  assign idle = !rxp_valid && !b_valid && !p_valid && !u_valid && (d_st == D_IDLE) &&
                wr_idle && rd_idle && bm_idle && mx_idle && !bt_valid && !rt_valid &&
                !t_busy && !txp_valid && !m_awvalid && !m_wvalid && !m_arvalid;

  /* verilator lint_off UNUSEDSIGNAL */
  wire unused_ok = ^{m_bid, m_rid[1], wd_tag, b_sop, dw3[1:0], bar0[13:0], bar2[14:0], end_dw[9:0], q_busy};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule : tl_core

`default_nettype wire
