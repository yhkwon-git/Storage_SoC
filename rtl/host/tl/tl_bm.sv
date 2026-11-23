`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// tl_bm
//
// Bus master of the transaction layer: moves data between host memory and
// the SoC, and sends MSI-X messages. One request at a time; a request is a
// direction, a host DW address, a local (AXI) DW address and a length in
// DWs. Addresses and lengths are DW-granular, as NVMe PRP transfers are.
//
// Host to SoC (memory reads):
//   * The range is cut into MRd requests of at most Max_Read_Request_Size,
//     never crossing a 4 KiB boundary of the host or the local address.
//   * Each MRd takes a free tag (NTAG tags). The tag remembers the local
//     address, the length and the bytes still expected.
//   * Each completion is checked against its tag: requester ID, status,
//     Byte Count equal to the bytes still expected, Lower Address equal to
//     the next expected address, a length that fits, and a split only at a
//     64-byte boundary. A good one is written to local memory at its offset
//     (c_write, c_laddr: the dispatcher hands the payload to tl_wr), so
//     completions may arrive in any order across tags.
//   * A tag older than the completion timeout is retired with an error. It
//     is not reused for one more timeout period, and a completion that
//     arrives for it in that time is dropped as unexpected.
//   * The request ends when every MRd is issued, every tag has its last
//     completion (or an error), and every local write has its B.
//
// SoC to host (memory writes):
//   * The range is cut into MWr requests of at most Max_Payload_Size, again
//     within 4 KiB on both sides. A chunk's local data is read (ARID 1, bursts
//     split at 128 bytes) into the write buffer, whose space for the whole
//     chunk is reserved first, so RREADY is always high.
//   * A chunk is sent only when all of it has arrived, so its TLP has no gap;
//     the payload passes an aligner from the local lane to the host lane.
//   * The request ends when its last MWr has been handed to the transmitter.
//
// MSI-X: a message from tl_msix is sent between TLPs, as a one-DW MWr in the
// same stream as the data writes, so it never passes data written before it.
//
// Errors (done_cause, the first one): 1 Bus Master Enable clear, 2 local AXI
// error, 3 UR completion, 4 CA completion, 5 completion timeout, 6 a
// completion that fails the checks or is poisoned. After an error nothing new
// is issued; what is in flight completes or times out (H2D) or is read and
// dropped (D2H); then done_valid reports the request.
// -----------------------------------------------------------------------------

module tl_bm #(
  parameter int NTAG      = 16,
  parameter int BUF_DEPTH = 64,
  parameter int CH_DEPTH  = 4
) (
  input  wire           clk,
  input  wire           rst_n,

  // Request
  input  wire           req_valid,
  output logic          req_ready,
  input  wire           req_d2h,
  input  wire  [63:2]   req_haddr,
  input  wire  [31:2]   req_laddr,
  input  wire  [17:0]   req_len,       // DWs, at least 1
  output logic          done_valid,
  output logic [2:0]    done_cause,    // 0: no error
  output logic          busy,

  // Settings
  input  wire           bme,
  input  wire           mps256,
  input  wire  [2:0]    mrrs,
  input  wire  [15:0]   my_id,
  input  wire           cto_dis,
  input  wire  [7:0]    cto_ticks,     // completion timeout, units of 64 clocks

  // MSI-X message
  input  wire           msg_valid,
  output logic          msg_ready,
  input  wire  [63:0]   msg_addr,
  input  wire  [31:0]   msg_data,

  // Completion header from the dispatcher, answered in the same clock
  input  wire           c_valid,
  input  wire  [7:0]    c_tag,
  input  wire  [15:0]   c_req_id,
  input  wire  [2:0]    c_status,
  input  wire  [11:0]   c_bc,
  input  wire  [6:0]    c_la,
  input  wire  [10:0]   c_len,
  input  wire           c_data,
  input  wire           c_ep,
  output logic          c_write,       // write the payload ...
  output logic [31:2]   c_laddr,       // ... here

  // Local writes of completion data finished (tl_wr, owner 1)
  input  wire           wd_valid,
  input  wire           wd_err,

  // AXI4 read (ARID 1)
  output logic          m_arvalid,
  input  wire           m_arready,
  output logic [31:0]   m_araddr,
  output logic [7:0]    m_arlen,
  output logic [2:0]    m_arsize,
  input  wire           m_rvalid,
  input  wire  [63:0]   m_rdata,
  input  wire  [1:0]    m_rresp,
  input  wire           m_rlast,

  // Requests, unpacked (tl_pkg)
  output logic          tx_valid,
  input  wire           tx_ready,
  output logic          tx_hdr,
  output logic [127:0]  tx_data,
  output logic [1:0]    tx_dwv,
  output logic          tx_last,
  output logic          tx_posted,     // the header beat is a posted request

  output logic          ev_rcv_ma,
  output logic          ev_rcv_ta,
  output logic          ev_unexp,
  output logic          ev_timeout,
  output logic          ev_badcpl,
  output logic          ev_par,
  output logic          idle
);

  import tl_pkg::*;

  localparam int TW = $clog2(NTAG);
  localparam int BW = $clog2(BUF_DEPTH);
  localparam int QW = $clog2(CH_DEPTH);

  localparam logic [1:0] T_FREE = 2'd0, T_BUSY = 2'd1, T_QUAR = 2'd2;

  // ---------------------------------------------------------------------------
  // Request state
  // ---------------------------------------------------------------------------
  logic        r_act, r_d2h;
  logic [61:0] r_h;        // next host DW address
  logic [29:0] r_l;        // next local DW address
  logic [17:0] r_rem;      // DWs not yet cut into chunks
  logic [2:0]  r_cause;
  wire         r_err = (r_cause != 3'd0);

  // Chunk size: the smallest of what is left, the size limit and both 4 KiB
  // boundaries.
  wire [10:0] max_dw  = r_d2h ? (mps256 ? 11'd64 : 11'd32) : (11'd32 << mrrs);
  wire [10:0] dist_h  = 11'd1024 - {1'b0, r_h[9:0]};
  wire [10:0] dist_l  = 11'd1024 - {1'b0, r_l[9:0]};
  logic [10:0] ch_len;
  always_comb begin
    ch_len = max_dw;
    if (dist_h < ch_len) ch_len = dist_h;
    if (dist_l < ch_len) ch_len = dist_l;
    if (r_rem < 18'(ch_len)) ch_len = r_rem[10:0];
  end

  // ---------------------------------------------------------------------------
  // Tags (host to SoC)
  // ---------------------------------------------------------------------------
  logic [1:0]  t_st    [NTAG];
  logic [29:0] t_l     [NTAG];   // local DW address of the MRd's first DW
  logic [10:0] t_len   [NTAG];   // DWs requested
  logic [12:0] t_rem   [NTAG];   // bytes still expected
  logic [4:0]  t_h     [NTAG];   // host address bits 6:2 of the first DW
  logic [7:0]  t_age   [NTAG];

  logic [TW-1:0] free_tag;
  logic          have_free;
  logic          any_busy;
  always_comb begin
    free_tag  = '0;
    have_free = 1'b0;
    any_busy  = 1'b0;
    for (int i = NTAG - 1; i >= 0; i--) begin
      if (t_st[i] == T_FREE) begin
        free_tag  = TW'(i);
        have_free = 1'b1;
      end
      if (t_st[i] == T_BUSY) any_busy = 1'b1;
    end
  end

  // Completion check (combinational answer to c_valid)
  wire [TW-1:0] ct     = c_tag[TW-1:0];
  wire          c_tagok = (c_tag < 8'(NTAG)) && (t_st[ct] == T_BUSY) && (c_req_id == my_id);
  wire [12:0]   c_bytes = {c_len, 2'b00};
  wire [12:0]   c_done  = {t_len[ct], 2'b00} - t_rem[ct];           // bytes already received
  wire [6:0]    c_exp_la = {t_h[ct], 2'b00} + c_done[6:0];
  wire          c_final = (c_bytes == t_rem[ct]);
  wire          c_fit   = c_data && (c_bytes <= t_rem[ct]) && (c_bc == t_rem[ct][11:0]) &&
                          (c_la == c_exp_la) && (c_final || ((c_la + c_bytes[6:0]) & 7'h3F) == 7'h00);
  wire          c_ok    = c_tagok && (c_status == CS_SC) && !c_ep && c_fit;

  assign c_write = c_valid && c_ok;
  assign c_laddr = t_l[ct] + {19'd0, c_done[12:2]};

  // Local writes of completion data still outstanding.
  logic [5:0] wr_pend;

  // Timeout prescaler
  logic [5:0] presc;
  wire        tick = (presc == 6'd63);

  // ---------------------------------------------------------------------------
  // SoC to host: local reads into the write buffer, chunk queue
  // ---------------------------------------------------------------------------
  logic [61:0] q_h   [CH_DEPTH];
  logic [10:0] q_len [CH_DEPTH];
  logic        q_ll  [CH_DEPTH];   // local lane of the first DW
  logic        q_el  [CH_DEPTH];   // local lane of the last DW
  logic [5:0]  q_beats [CH_DEPTH];
  logic        q_err [CH_DEPTH];
  logic        q_rdy [CH_DEPTH];
  logic [QW:0] q_wp, q_fp, q_hp;   // push, fill, head (emit)
  logic [5:0]  fill_cnt;
  logic [BW:0] credit_used;

  wire [29:0] ch_last_l = r_l + {19'd0, ch_len} - 30'd1;
  wire [5:0]  ch_beats  = 6'(ch_last_l[29:1] - r_l[29:1]) + 6'd1;
  wire        q_full    = ((q_wp - q_hp) == (QW+1)'(CH_DEPTH));
  wire        q_empty   = (q_wp == q_hp);

  // AR generator: one chunk's bursts at a time.
  logic        ar_act;
  logic        ar_pend;       // a chunk's first AR is out, waiting for READY
  logic [29:0] ar_l;
  logic [10:0] ar_rem;

  // A chunk starts when its credits and a queue entry are there; its first AR
  // then stays up until taken, even if an error arrives meanwhile (its data
  // is dropped then).
  wire start_chunk = r_act && r_d2h && !r_err && (r_rem != 18'd0) && !ar_act && !ar_pend &&
                     !q_full &&
                     (credit_used + (BW+1)'(ch_beats) <= (BW+1)'(BUF_DEPTH)) && bme;

  wire [29:0] b_l      = ar_act ? ar_l : r_l;
  wire [10:0] b_rem    = ar_act ? ar_rem : ch_len;
  wire [5:0]  b_bound  = 6'd32 - {1'b0, b_l[4:0]};
  wire [10:0] b_dws    = (b_rem < {5'd0, b_bound}) ? b_rem : {5'd0, b_bound};
  wire [29:0] b_last   = b_l + {19'd0, b_dws} - 30'd1;
  wire [4:0]  b_beats  = 5'(b_last[29:1] - b_l[29:1]) + 5'd1;

  // Reads are always 64-bit beats; a chunk's credit covers all its beats.
  assign m_arvalid = ar_act || ar_pend;
  assign m_araddr  = {b_l[29:1], 3'b000};
  assign m_arlen   = {3'd0, b_beats - 5'd1};
  assign m_arsize  = 3'd3;

  wire ar_hs   = m_arvalid && m_arready;
  wire ar_lastb = (b_dws == b_rem);

  // Write buffer
  logic        wb_empty, wb_pop;
  logic [63:0] wb_out;
  logic        wb_full;   // never set: a chunk reserves its beats before its reads

  fifo_sync #(.WIDTH(64), .DEPTH(BUF_DEPTH)) u_wb (
    .clk (clk), .rst_n (rst_n),
    .push (m_rvalid), .din (m_rdata), .full (wb_full),
    .pop (wb_pop), .dout (wb_out), .empty (wb_empty)
  );

  // ---------------------------------------------------------------------------
  // Transmitter
  // ---------------------------------------------------------------------------
  typedef enum logic [2:0] {E_IDLE, E_MSG_H, E_MSG_P, E_MWR_H, E_MWR_P, E_MRD_H, E_DROP} est_t;
  est_t        e_st;
  logic [5:0]  e_beat;

  wire [QW-1:0] hi = q_hp[QW-1:0];
  wire          head_rdy = !q_empty && q_rdy[hi];
  wire          can_mrd  = r_act && !r_d2h && !r_err && (r_rem != 18'd0) && have_free && bme;

  // Header of each kind
  wire        mrd_4dw = (r_h[61:30] != 32'd0);
  wire [3:0]  mrd_lbe = (ch_len == 11'd1) ? 4'h0 : 4'hF;
  wire [31:0] mrd_dw0 = mk_dw0(mrd_4dw ? FMT_4DW : FMT_3DW, TY_MEM, 3'd0, 2'd0, ch_len);
  wire [31:0] mrd_dw1 = {my_id, 8'(free_tag), mrd_lbe, 4'hF};
  wire [127:0] mrd_hdr = mrd_4dw ? {r_h[29:0], 2'b00, r_h[61:30], mrd_dw1, mrd_dw0}
                                 : {32'd0, r_h[29:0], 2'b00, mrd_dw1, mrd_dw0};

  wire [61:0] w_h     = q_h[hi];
  wire [10:0] w_len   = q_len[hi];
  wire        mwr_4dw = (w_h[61:30] != 32'd0);
  wire [31:0] mwr_dw0 = mk_dw0(mwr_4dw ? FMT_4DW_D : FMT_3DW_D, TY_MEM, 3'd0, 2'd0, w_len);
  wire [31:0] mwr_dw1 = {my_id, 8'd0, (w_len == 11'd1) ? 4'h0 : 4'hF, 4'hF};
  wire [127:0] mwr_hdr = mwr_4dw ? {w_h[29:0], 2'b00, w_h[61:30], mwr_dw1, mwr_dw0}
                                 : {32'd0, w_h[29:0], 2'b00, mwr_dw1, mwr_dw0};

  wire        msg_4dw = (msg_addr[63:32] != 32'd0);
  wire [31:0] msg_dw0 = mk_dw0(msg_4dw ? FMT_4DW_D : FMT_3DW_D, TY_MEM, 3'd0, 2'd0, 11'd1);
  wire [31:0] msg_dw1 = {my_id, 8'd0, 4'h0, 4'hF};
  wire [127:0] msg_hdr = msg_4dw ? {msg_addr[31:2], 2'b00, msg_addr[63:32], msg_dw1, msg_dw0}
                                 : {32'd0, msg_addr[31:2], 2'b00, msg_dw1, msg_dw0};

  // Payload aligner, local lane to host lane.
  logic        al_in_valid, al_in_ready, al_in_last;
  logic [1:0]  al_in_dwv;
  logic        al_out_valid, al_out_ready, al_out_last;
  logic [63:0] al_out_data;
  logic [1:0]  al_out_dwv;
  wire         w_lastbeat = (e_beat == q_beats[hi] - 6'd1);

  assign al_in_valid = (e_st == E_MWR_P) && !wb_empty;
  assign al_in_dwv   = {!(w_lastbeat && !q_el[hi]), !(e_beat == 6'd0 && q_ll[hi])};
  assign al_in_last  = w_lastbeat;

  tl_dw_align u_align (
    .clk       (clk),          .rst_n     (rst_n),
    .in_valid  (al_in_valid),  .in_ready  (al_in_ready), .in_data (wb_out),
    .in_dwv    (al_in_dwv),    .in_last   (al_in_last),  .out_lane0 (w_h[0]),
    .out_valid (al_out_valid), .out_ready (al_out_ready), .out_data (al_out_data),
    .out_dwv   (al_out_dwv),   .out_last  (al_out_last)
  );

  always_comb begin
    tx_valid     = 1'b0;
    tx_hdr       = 1'b0;
    tx_data      = mrd_hdr;
    tx_dwv       = 2'b00;
    tx_last      = 1'b0;
    tx_posted    = 1'b0;
    case (e_st)
      E_MSG_H: begin
        tx_valid = 1'b1; tx_hdr = 1'b1; tx_data = msg_hdr; tx_posted = 1'b1;
      end
      E_MSG_P: begin
        tx_valid = 1'b1;
        tx_data  = {64'd0, msg_data, msg_data};
        tx_dwv   = msg_addr[2] ? 2'b10 : 2'b01;
        tx_last  = 1'b1;
      end
      E_MWR_H: begin
        tx_valid = 1'b1; tx_hdr = 1'b1; tx_data = mwr_hdr; tx_posted = 1'b1;
      end
      E_MWR_P: begin
        tx_valid = al_out_valid;
        tx_data  = {64'd0, al_out_data};
        tx_dwv   = al_out_dwv;
        tx_last  = al_out_last;
      end
      E_MRD_H: begin
        tx_valid = 1'b1; tx_hdr = 1'b1; tx_data = mrd_hdr; tx_last = 1'b1;
      end
      default: ;
    endcase
  end

  wire tx_hs    = tx_valid && tx_ready;

  assign al_out_ready = (e_st == E_MWR_P) && tx_ready;
  assign wb_pop       = ((e_st == E_MWR_P) && al_in_valid && al_in_ready) ||
                        ((e_st == E_DROP) && !wb_empty);
  wire drop_end = (e_st == E_DROP) && wb_pop && (e_beat == q_beats[hi] - 6'd1);
  wire mwr_end  = (e_st == E_MWR_P) && tx_hs && tx_last;
  wire head_adv = drop_end || mwr_end;

  assign msg_ready = (e_st == E_MSG_P) && tx_hs;

  // ---------------------------------------------------------------------------
  // Sequential state
  // ---------------------------------------------------------------------------
  wire mrd_issue = (e_st == E_MRD_H) && tx_hs;
  wire chunk_cut = mrd_issue || (ar_hs && !ar_act);   // a chunk leaves r_rem

  assign req_ready = !r_act;
  assign busy      = r_act;

  wire h2d_end = !r_d2h && (r_rem == 18'd0 || r_err) && !any_busy && (wr_pend == 6'd0) &&
                 (e_st != E_MRD_H);
  wire d2h_end = r_d2h && (r_rem == 18'd0 || r_err) && !ar_act && !ar_pend && q_empty &&
                 (e_st == E_IDLE);

  // Error events from completions
  logic [2:0] c_cause;
  always_comb begin
    c_cause = 3'd0;
    if (c_valid && c_tagok && !c_ok) begin
      if (c_status == CS_UR)      c_cause = 3'd3;
      else if (c_status == CS_CA) c_cause = 3'd4;
      else                        c_cause = 3'd6;
    end
  end

  logic        to_hit;     // some tag timed out this clock
  always_comb begin
    to_hit = 1'b0;
    for (int i = 0; i < NTAG; i++) begin
      if (tick && t_st[i] == T_BUSY && !cto_dis && (t_age[i] >= cto_ticks) &&
          !(c_valid && c_tagok && ct == TW'(i))) to_hit = 1'b1;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      r_act <= 1'b0; r_d2h <= 1'b0; r_h <= 62'd0; r_l <= 30'd0; r_rem <= 18'd0;
      r_cause <= 3'd0;
      done_valid <= 1'b0; done_cause <= 3'd0;
      wr_pend <= 6'd0; presc <= 6'd0;
      e_st <= E_IDLE; e_beat <= 6'd0;
      ar_act <= 1'b0; ar_pend <= 1'b0; ar_l <= 30'd0; ar_rem <= 11'd0;
      q_wp <= '0; q_fp <= '0; q_hp <= '0; fill_cnt <= 6'd0;
      credit_used <= '0;
      ev_rcv_ma <= 1'b0; ev_rcv_ta <= 1'b0; ev_unexp <= 1'b0; ev_timeout <= 1'b0;
      ev_badcpl <= 1'b0; ev_par <= 1'b0;
      for (int i = 0; i < NTAG; i++) begin
        t_st[i] <= T_FREE; t_l[i] <= 30'd0; t_len[i] <= 11'd0; t_rem[i] <= 13'd0;
        t_h[i] <= 5'd0; t_age[i] <= 8'd0;
      end
      for (int i = 0; i < CH_DEPTH; i++) begin
        q_h[i] <= 62'd0; q_len[i] <= 11'd0; q_ll[i] <= 1'b0; q_el[i] <= 1'b0;
        q_beats[i] <= 6'd0; q_err[i] <= 1'b0; q_rdy[i] <= 1'b0;
      end
    end else begin
      done_valid <= 1'b0;
      ev_rcv_ma  <= c_valid && c_tagok && (c_status == CS_UR);
      ev_rcv_ta  <= c_valid && c_tagok && (c_status == CS_CA);
      ev_unexp   <= c_valid && !c_tagok;
      ev_badcpl  <= c_valid && c_tagok && (c_status == CS_SC) && (c_ep || !c_fit);
      ev_par     <= c_valid && c_tagok && c_ep;
      ev_timeout <= to_hit;
      presc      <= presc + 6'd1;

      // Request start and end
      if (req_valid && req_ready) begin
        r_act   <= 1'b1;
        r_d2h   <= req_d2h;
        r_h     <= req_haddr;
        r_l     <= req_laddr;
        r_rem   <= req_len;
        r_cause <= bme ? 3'd0 : 3'd1;
      end else if (r_act && (h2d_end || d2h_end)) begin
        r_act      <= 1'b0;
        done_valid <= 1'b1;
        done_cause <= r_cause;
      end else if (r_act && !r_err) begin
        if (!bme)                                   r_cause <= 3'd1;
        else if (wd_valid && wd_err)                r_cause <= 3'd2;
        else if (m_rvalid && (m_rresp != 2'b00))    r_cause <= 3'd2;
        else if (c_cause != 3'd0)                   r_cause <= c_cause;
        else if (to_hit)                            r_cause <= 3'd5;
      end

      // Cutting chunks
      if (chunk_cut) begin
        r_h   <= r_h + {51'd0, ch_len};
        r_l   <= r_l + {19'd0, ch_len};
        r_rem <= r_rem - {7'd0, ch_len};
      end

      // Outstanding local writes
      wr_pend <= wr_pend + (c_write ? 6'd1 : 6'd0) - (wd_valid ? 6'd1 : 6'd0);

      // Tags
      for (int i = 0; i < NTAG; i++) begin
        if (mrd_issue && free_tag == TW'(i)) begin
          t_st[i]  <= T_BUSY;
          t_l[i]   <= r_l;
          t_len[i] <= ch_len;
          t_rem[i] <= {ch_len, 2'b00};
          t_h[i]   <= r_h[4:0];
          t_age[i] <= 8'd0;
        end else if (c_valid && c_tagok && ct == TW'(i)) begin
          if (c_ok) begin
            t_rem[i] <= t_rem[i] - c_bytes;
            if (c_final) t_st[i] <= T_FREE;
          end else begin
            t_st[i] <= T_FREE;   // an error completion ends the request's tag
          end
        end else if (tick && t_st[i] != T_FREE) begin
          if (t_st[i] == T_BUSY && !cto_dis && (t_age[i] >= cto_ticks)) begin
            t_st[i]  <= T_QUAR;
            t_age[i] <= 8'd0;
          end else if (t_st[i] == T_QUAR && (t_age[i] >= cto_ticks)) begin
            t_st[i] <= T_FREE;
          end else if (t_age[i] != 8'hFF) begin
            t_age[i] <= t_age[i] + 8'd1;
          end
        end
      end

      // AR generator and chunk queue
      if (ar_hs && !ar_act)  ar_pend <= 1'b0;
      else if (start_chunk) ar_pend <= 1'b1;
      if (ar_hs) begin
        if (!ar_act) begin
          q_h[q_wp[QW-1:0]]     <= r_h;
          q_len[q_wp[QW-1:0]]   <= ch_len;
          q_ll[q_wp[QW-1:0]]    <= r_l[0];
          q_el[q_wp[QW-1:0]]    <= ch_last_l[0];
          q_beats[q_wp[QW-1:0]] <= ch_beats;
          q_err[q_wp[QW-1:0]]   <= 1'b0;
          q_rdy[q_wp[QW-1:0]]   <= 1'b0;
          q_wp <= q_wp + 1'b1;
        end
        ar_act <= !ar_lastb;
        ar_l   <= b_l + {19'd0, b_dws};
        ar_rem <= b_rem - b_dws;
      end
      credit_used <= credit_used + ((ar_hs && !ar_act) ? (BW+1)'(ch_beats) : '0) -
                     (wb_pop ? (BW+1)'(1) : '0);

      // Read data fills the oldest unfilled chunk.
      if (m_rvalid) begin
        if (m_rresp != 2'b00) q_err[q_fp[QW-1:0]] <= 1'b1;
        if (fill_cnt == q_beats[q_fp[QW-1:0]] - 6'd1) begin
          q_rdy[q_fp[QW-1:0]] <= 1'b1;
          q_fp     <= q_fp + 1'b1;
          fill_cnt <= 6'd0;
        end else begin
          fill_cnt <= fill_cnt + 6'd1;
        end
      end

      // Transmitter
      case (e_st)
        E_IDLE: begin
          e_beat <= 6'd0;
          if (msg_valid && bme)                         e_st <= E_MSG_H;
          else if (head_rdy && (q_err[hi] || r_err))   e_st <= E_DROP;
          else if (head_rdy && bme)                     e_st <= E_MWR_H;
          else if (can_mrd)                             e_st <= E_MRD_H;
        end
        E_MSG_H: if (tx_hs) e_st <= E_MSG_P;
        E_MSG_P: if (tx_hs) e_st <= E_IDLE;
        E_MWR_H: if (tx_hs) e_st <= E_MWR_P;
        E_MWR_P: begin
          if (wb_pop) e_beat <= e_beat + 6'd1;
          if (mwr_end) e_st <= E_IDLE;
        end
        E_MRD_H: if (tx_hs) e_st <= E_IDLE;
        default: begin  // E_DROP
          if (wb_pop) e_beat <= e_beat + 6'd1;
          if (drop_end) begin
            e_st <= E_IDLE;
            if (q_err[hi] && !r_err && r_act) r_cause <= 3'd2;
          end
        end
      endcase
      if (head_adv) begin
        q_rdy[hi] <= 1'b0;
        q_hp      <= q_hp + 1'b1;
      end
    end
  end

  // A chunk with a read error is dropped; its error was recorded from RRESP.
  assign idle = !r_act && (e_st == E_IDLE) && !ar_act && !ar_pend && q_empty && (wr_pend == 6'd0) &&
                !any_busy && (credit_used == '0);

  /* verilator lint_off UNUSEDSIGNAL */
  wire unused_ok = ^{m_rlast, wb_full, msg_addr[1:0], b_last[0]};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule : tl_bm

`default_nettype wire
