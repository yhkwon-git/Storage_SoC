`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// tl_rd
//
// Completer side of the transaction layer: inbound memory reads on AXI and
// every completion the endpoint sends.
//
// The dispatcher queues one completion job per non-posted request, in
// arrival order:
//   MEM     memory read through an inbound window; the data comes from AXI
//   DATA    CplD with one or two DWs from the job (configuration read,
//           MSI-X table read)
//   NODATA  Cpl with a status (configuration write, UR, CA)
// A MEM job is also queued for the read engine.
//
// Read engine (ARID 0): a job waits until every write accepted before it has
// its B (jobs_done reaches the job's fence), so a read never passes an
// earlier posted write. It then reads its range in bursts split at 128-byte
// boundaries, a one-DW read as a single 32-bit beat. A burst is issued only
// when the completion buffer has room for all its beats (credits), so RREADY
// is always high, and at most SUM_DEPTH bursts are outstanding. At each RLAST
// the burst's response (OR of its beats) goes into a summary FIFO.
//
// Completion generator, one job at a time in queue order: a MEM job becomes
// one CplD per burst, each sent once its burst has fully arrived. Completions
// split at 128-byte address boundaries, which are also 64-byte RCB
// boundaries, and are never longer than 128 bytes, the smallest Max_Payload
// _Size. Byte Count is the bytes left in the request including this
// completion; Lower Address is the address of its first byte. A burst with
// an error response ends the request: one Cpl with Completer Abort and the
// remaining Byte Count, and the request's remaining data is dropped as it
// arrives.
// -----------------------------------------------------------------------------

module tl_rd #(
  parameter int CJ_DEPTH  = 8,
  parameter int BUF_DEPTH = 64,
  parameter int SUM_DEPTH = 16
) (
  input  wire           clk,
  input  wire           rst_n,

  // Completion jobs
  input  wire           cj_valid,
  output logic          cj_ready,
  input  wire  [1:0]    cj_kind,
  input  wire  [2:0]    cj_status,
  input  wire  [15:0]   cj_req_id,
  input  wire  [7:0]    cj_tag,
  input  wire  [2:0]    cj_tc,
  input  wire  [1:0]    cj_attr,
  input  wire  [6:0]    cj_la,
  input  wire  [12:0]   cj_bc,
  input  wire  [10:0]   cj_len,
  input  wire  [63:0]   cj_data,
  input  wire  [31:2]   cj_axi,       // MEM: AXI DW address of the first DW
  input  wire  [7:0]    cj_fence,     // MEM: tl_wr jobs_acc when it arrived

  input  wire  [7:0]    wr_jobs_done,
  input  wire  [15:0]   my_id,

  // AXI4 read address and data (ARID 0, routed by the core)
  output logic          m_arvalid,
  input  wire           m_arready,
  output logic [31:0]   m_araddr,
  output logic [7:0]    m_arlen,
  output logic [2:0]    m_arsize,
  input  wire           m_rvalid,
  input  wire  [63:0]   m_rdata,
  input  wire  [1:0]    m_rresp,
  input  wire           m_rlast,

  // Completions, unpacked (tl_pkg)
  output logic          tx_valid,
  input  wire           tx_ready,
  output logic          tx_hdr,
  output logic [127:0]  tx_data,
  output logic [1:0]    tx_dwv,
  output logic          tx_last,

  output logic          ev_sig_ta,    // a Completer Abort completion was sent
  output logic          idle
);

  import tl_pkg::*;

  localparam logic [1:0] K_MEM = 2'd0, K_DATA = 2'd1, K_NODATA = 2'd2;
  localparam int BW = $clog2(BUF_DEPTH);
  localparam int SW = $clog2(SUM_DEPTH);

  // ---------------------------------------------------------------------------
  // Job queues
  // ---------------------------------------------------------------------------
  localparam int CW = 2 + 3 + 16 + 8 + 3 + 2 + 7 + 13 + 11 + 64;
  logic          cq_full, cq_empty, cq_pop;
  logic [CW-1:0] cq_out;
  logic          aq_full, aq_empty, aq_pop;
  logic [48:0]   aq_out;

  wire is_mem = (cj_kind == K_MEM);
  assign cj_ready = !cq_full && !(is_mem && aq_full);
  wire cj_hs = cj_valid && cj_ready;

  fifo_sync #(.WIDTH(CW), .DEPTH(CJ_DEPTH)) u_cq (
    .clk (clk), .rst_n (rst_n),
    .push (cj_hs), .din ({cj_kind, cj_status, cj_req_id, cj_tag, cj_tc, cj_attr, cj_la, cj_bc,
                          cj_len, cj_data}),
    .full (cq_full), .pop (cq_pop), .dout (cq_out), .empty (cq_empty)
  );

  fifo_sync #(.WIDTH(49), .DEPTH(CJ_DEPTH)) u_aq (
    .clk (clk), .rst_n (rst_n),
    .push (cj_hs && is_mem), .din ({cj_axi, cj_len, cj_fence}),
    .full (aq_full), .pop (aq_pop), .dout (aq_out), .empty (aq_empty)
  );

  // ---------------------------------------------------------------------------
  // Read engine
  // ---------------------------------------------------------------------------
  wire [29:0] a_dw0   = aq_out[48:19];
  wire [10:0] a_len   = aq_out[18:8];
  wire [7:0]  a_fence = aq_out[7:0];

  logic        a_act;          // the head job is being issued
  logic [29:0] a_dw;           // next DW to read
  logic [10:0] a_rem;          // DWs left to issue
  logic [BW:0] credit_used;    // beats reserved in the buffer
  logic [SW:0] bursts_out;     // bursts issued and not yet consumed
  logic        sum_push, sum_pop;

  wire [7:0]  fence_d   = wr_jobs_done - a_fence;
  wire        fence_ok  = !fence_d[7];
  wire [29:0] cur_dw    = a_act ? a_dw : a_dw0;
  wire [10:0] cur_rem   = a_act ? a_rem : a_len;
  wire [5:0]  to_bound  = 6'd32 - {1'b0, cur_dw[4:0]};
  wire [10:0] ch_dws    = (cur_rem < {5'd0, to_bound}) ? cur_rem : {5'd0, to_bound};
  wire [29:0] ch_end    = cur_dw + {19'd0, ch_dws} - 30'd1;
  wire [4:0]  ch_beats  = 5'(ch_end[29:1] - cur_dw[29:1]) + 5'd1;
  wire        narrow    = (a_len == 11'd1);
  wire        room      = (credit_used + (BW+1)'(ch_beats) <= (BW+1)'(BUF_DEPTH)) &&
                          (bursts_out != (SW+1)'(SUM_DEPTH));

  assign m_arvalid = !aq_empty && (a_act || fence_ok) && room;
  assign m_araddr  = narrow ? {cur_dw, 2'b00} : {cur_dw[29:1], 3'b000};
  assign m_arlen   = narrow ? 8'd0 : {3'd0, ch_beats - 5'd1};
  assign m_arsize  = narrow ? 3'd2 : 3'd3;

  wire ar_hs   = m_arvalid && m_arready;
  wire ar_last = (ch_dws == cur_rem);
  assign aq_pop = ar_hs && ar_last;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      a_act <= 1'b0;
      a_dw  <= 30'd0;
      a_rem <= 11'd0;
    end else if (ar_hs) begin
      a_act <= !ar_last;
      a_dw  <= cur_dw + {19'd0, ch_dws};
      a_rem <= cur_rem - ch_dws;
    end
  end

  // Completion buffer and burst summaries
  logic        cb_empty, cb_pop;
  logic [63:0] cb_out;
  logic        r_err_acc;
  logic        sum_empty, sum_out;
  logic        cb_full, sum_full;   // never set: credits and the burst limit keep both from filling

  wire r_hs = m_rvalid;   // RREADY is always high

  fifo_sync #(.WIDTH(64), .DEPTH(BUF_DEPTH)) u_cb (
    .clk (clk), .rst_n (rst_n),
    .push (r_hs), .din (m_rdata), .full (cb_full),
    .pop (cb_pop), .dout (cb_out), .empty (cb_empty)
  );

  assign sum_push = r_hs && m_rlast;

  fifo_sync #(.WIDTH(1), .DEPTH(SUM_DEPTH)) u_sum (
    .clk (clk), .rst_n (rst_n),
    .push (sum_push), .din (r_err_acc || (m_rresp != 2'b00)), .full (sum_full),
    .pop (sum_pop), .dout (sum_out), .empty (sum_empty)
  );

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)          r_err_acc <= 1'b0;
    else if (r_hs)       r_err_acc <= m_rlast ? 1'b0 : (r_err_acc || (m_rresp != 2'b00));
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      credit_used <= '0;
      bursts_out  <= '0;
    end else begin
      credit_used <= credit_used + (ar_hs ? (BW+1)'(ch_beats) : '0) - (cb_pop ? (BW+1)'(1) : '0);
      bursts_out  <= bursts_out + (ar_hs ? (SW+1)'(1) : '0) - (sum_pop ? (SW+1)'(1) : '0);
    end
  end

  // ---------------------------------------------------------------------------
  // Completion generator
  // ---------------------------------------------------------------------------
  wire [1:0]  q_kind   = cq_out[CW-1 -: 2];
  wire [2:0]  q_status = cq_out[CW-3 -: 3];
  wire [15:0] q_req    = cq_out[CW-6 -: 16];
  wire [7:0]  q_tag    = cq_out[CW-22 -: 8];
  wire [2:0]  q_tc     = cq_out[CW-30 -: 3];
  wire [1:0]  q_attr   = cq_out[CW-33 -: 2];
  wire [6:0]  q_la     = cq_out[CW-35 -: 7];
  wire [12:0] q_bc     = cq_out[CW-42 -: 13];
  wire [10:0] q_len    = cq_out[CW-55 -: 11];
  wire [63:0] q_data   = cq_out[63:0];

  typedef enum logic [2:0] {G_IDLE, G_HDR, G_PAY, G_DROP, G_DPAY} gst_t;
  gst_t        g_st;
  logic [4:0]  g_a;        // DW address bits 6:2 of the next chunk
  logic [10:0] g_rem;      // DWs left in the job
  logic [12:0] g_bc;       // bytes left
  logic        g_first, g_abort;
  logic [4:0]  g_beat;     // beat within the chunk
  logic        g_dbeat;    // DATA: second beat

  wire [5:0]  g_to_bound = 6'd32 - {1'b0, g_a};
  wire [10:0] g_ch       = (g_rem < {5'd0, g_to_bound}) ? g_rem : {5'd0, g_to_bound};
  wire [5:0]  g_end      = {1'b0, g_a} + g_ch[5:0] - 6'd1;          // last DW of the chunk
  wire [4:0]  g_beats    = 5'(g_end[5:1] - {1'b0, g_a[4:1]}) + 5'd1;
  wire [6:0]  g_la       = g_first ? q_la : {g_a, 2'b00};
  wire [12:0] g_ch_bytes = {g_ch, 2'b00} - (g_first ? {11'd0, q_la[1:0]} : 13'd0);
  wire        g_last_ch  = (g_ch == g_rem);
  wire        g_lastbeat = (g_beat == g_beats - 5'd1);

  // Header of the current completion.
  logic        hd_data;
  logic [2:0]  h_status;
  logic [10:0] hd_len;
  always_comb begin
    hd_data  = 1'b1;
    h_status = CS_SC;
    hd_len   = g_ch;
    case (q_kind)
      K_MEM: begin
        if (sum_out) begin
          hd_data  = 1'b0;
          h_status = CS_CA;
          hd_len   = 11'd0;
        end
      end
      K_DATA:  hd_len = q_len;
      default: begin
        hd_data  = 1'b0;
        h_status = q_status;
        hd_len   = 11'd0;
      end
    endcase
  end

  wire [31:0] h_dw0 = mk_dw0(hd_data ? FMT_3DW_D : FMT_3DW, TY_CPL, q_tc, q_attr, hd_len);
  wire [31:0] h_dw1 = {my_id, h_status, 1'b0, (q_kind == K_MEM) ? g_bc[11:0] : q_bc[11:0]};
  wire [31:0] h_dw2 = {q_req, q_tag, 1'b0, (q_kind == K_MEM) ? g_la : q_la};

  // MEM chunks need their burst summary before the header.
  wire mem_ready = !sum_empty;

  always_comb begin
    tx_valid = 1'b0;
    tx_hdr   = 1'b0;
    tx_data  = {32'd0, h_dw2, h_dw1, h_dw0};
    tx_dwv   = 2'b00;
    tx_last  = 1'b0;
    case (g_st)
      G_HDR: begin
        if (q_kind != K_MEM || (mem_ready && !g_abort)) begin
          tx_valid = 1'b1;
          tx_hdr   = 1'b1;
          tx_last  = !hd_data;
        end
      end
      G_PAY: begin
        tx_valid = !cb_empty;
        tx_data  = {64'd0, cb_out};
        tx_dwv   = {!(g_lastbeat && !g_end[0]), !(g_beat == 5'd0 && g_a[0])};
        tx_last  = g_lastbeat;
      end
      G_DPAY: begin
        tx_valid = 1'b1;
        if (!q_la[2]) begin
          tx_data = {64'd0, q_data};
          tx_dwv  = (q_len == 11'd2) ? 2'b11 : 2'b01;
          tx_last = 1'b1;
        end else if (!g_dbeat) begin
          tx_data = {64'd0, q_data[31:0], 32'd0};
          tx_dwv  = 2'b10;
          tx_last = (q_len == 11'd1);
        end else begin
          tx_data = {64'd0, 32'd0, q_data[63:32]};
          tx_dwv  = 2'b01;
          tx_last = 1'b1;
        end
      end
      default: ;
    endcase
  end

  wire tx_hs = tx_valid && tx_ready;

  assign cb_pop = ((g_st == G_PAY) && !cb_empty && tx_ready) || ((g_st == G_DROP) && !cb_empty);

  // Summary pop: with the header of a good chunk, with the CA header, or
  // when a dropped chunk starts.
  assign sum_pop = (g_st == G_HDR) && (q_kind == K_MEM) && mem_ready && (g_abort || tx_hs);

  // Chunk done: advance, or end the job.
  logic ch_done;
  always_comb begin
    ch_done = 1'b0;
    case (g_st)
      G_PAY:  ch_done = tx_hs && g_lastbeat;
      G_DROP: ch_done = cb_pop && g_lastbeat;
      default: ;
    endcase
  end

  assign cq_pop = ((g_st == G_HDR) && (q_kind == K_NODATA) && tx_hs) ||
                  ((g_st == G_DPAY) && tx_hs && tx_last) ||
                  (ch_done && g_last_ch);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      g_st      <= G_IDLE;
      g_a       <= 5'd0;
      g_rem     <= 11'd0;
      g_bc      <= 13'd0;
      g_first   <= 1'b0;
      g_abort   <= 1'b0;
      g_beat    <= 5'd0;
      g_dbeat   <= 1'b0;
      ev_sig_ta <= 1'b0;
    end else begin
      ev_sig_ta <= 1'b0;
      case (g_st)
        G_IDLE: if (!cq_empty) begin
          g_a     <= q_la[6:2];
          g_rem   <= q_len;
          g_bc    <= q_bc;
          g_first <= 1'b1;
          g_abort <= 1'b0;
          g_beat  <= 5'd0;
          g_dbeat <= 1'b0;
          g_st    <= G_HDR;
        end
        G_HDR: begin
          if (q_kind == K_MEM) begin
            if (mem_ready && g_abort) begin
              g_beat <= 5'd0;
              g_st   <= G_DROP;
            end else if (tx_hs) begin
              g_beat <= 5'd0;
              if (h_status == CS_CA) begin
                ev_sig_ta <= 1'b1;
                g_abort   <= 1'b1;
                g_st      <= G_DROP;
              end else begin
                g_st <= G_PAY;
              end
            end
          end else if (tx_hs) begin
            if (q_kind == K_DATA) begin
              g_st <= G_DPAY;
            end else begin
              if (q_status == CS_CA) ev_sig_ta <= 1'b1;
              g_st <= G_IDLE;
            end
          end
        end
        G_DPAY: if (tx_hs) begin
          g_dbeat <= 1'b1;
          if (tx_last) g_st <= G_IDLE;
        end
        default: begin  // G_PAY, G_DROP
          if ((g_st == G_PAY && tx_hs) || (g_st == G_DROP && cb_pop)) g_beat <= g_beat + 5'd1;
          if (ch_done) begin
            g_beat  <= 5'd0;
            g_first <= 1'b0;
            g_a     <= g_a + g_ch[4:0];
            g_rem   <= g_rem - g_ch;
            g_bc    <= g_bc - g_ch_bytes;
            g_st    <= g_last_ch ? G_IDLE : G_HDR;
          end
        end
      endcase
    end
  end

  assign idle = cq_empty && aq_empty && (g_st == G_IDLE) && (credit_used == '0) &&
                (bursts_out == '0);

  /* verilator lint_off UNUSEDSIGNAL */
  wire unused_ok = ^{cb_full, sum_full, fence_d[6:0], ch_end[0]};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule : tl_rd

`default_nettype wire
