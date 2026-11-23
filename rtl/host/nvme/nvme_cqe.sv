`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// nvme_cqe
//
// Completion queue entry poster of the NVMe controller (step 2-3,
// docs/12_nvme_data.md). Firmware posts {CQ, CID, SQ, status, DW0}; up to 4
// wait in a FIFO. For the oldest one:
//   - its completion queue must be enabled, or the entry is dropped;
//   - while the queue is full (tail + 1 = head, the head from the host's
//     doorbell) it waits;
//   - the 16-byte entry is built in the local buffer (words 8 and 9): DW0,
//     DW1 0, DW2 {SQID, SQ head}, DW3 {status, phase tag, CID}, with the SQ
//     head and the phase of this moment;
//   - the bus master writes it to CQ base + 16 x tail, and the tail moves on
//     (cq_adv; the controller toggles the phase at the wrap);
//   - with the queue's interrupts enabled, its MSI-X vector is requested,
//     and acknowledged, before the next entry, so the message follows the
//     entry on the link.
// A failed write drops the entry (werr). quit (a controller reset) empties
// the FIFO once no write is in flight; a post during it is dropped.
// -----------------------------------------------------------------------------

module nvme_cqe #(
  parameter logic [31:0] LBUF_BASE = 32'h5000_0000
) (
  input  wire           clk,
  input  wire           rst_n,

  input  wire           post,          // pulse
  input  wire  [2:0]    p_cqid,
  input  wire  [15:0]   p_cid,
  input  wire  [2:0]    p_sqid,
  input  wire  [14:0]   p_status,      // DW3 bits 31:17
  input  wire  [31:0]   p_dw0,
  input  wire           quit,

  // The oldest entry's queues, and the state the controller keeps for them
  output logic [2:0]    cur_cq,
  output logic [2:0]    cur_sq,
  input  wire           cq_en,
  input  wire  [63:12]  cq_base,
  input  wire  [11:0]   cq_size,       // entries - 1
  input  wire  [11:0]   cq_head,
  input  wire  [11:0]   cq_tail,
  input  wire           cq_phase,
  input  wire           cq_ien,
  input  wire  [2:0]    cq_iv,
  input  wire  [11:0]   sq_head,
  output logic          cq_adv,        // the tail of cur_cq moves on at this edge

  // Bus-master requests
  output logic          bm_valid,
  input  wire           bm_ready,
  output logic [63:2]   bm_haddr,
  output logic [31:2]   bm_laddr,
  input  wire           bm_done,
  input  wire  [2:0]    bm_cause,

  // Local buffer side port: words 8 and 9
  output logic          e_we,
  output logic [3:0]    e_waddr,
  output logic [63:0]   e_wdata,

  output logic          msix_req,      // level until msix_ack
  output logic [2:0]    msix_vec,
  input  wire           msix_ack,

  output logic [2:0]    count,
  output logic          full,
  output logic          cq_wait,       // the oldest entry waits for room
  output logic          drop,          // pulse
  output logic          werr,          // pulse
  output logic          active         // an entry is being written or signalled
);

  // ---------------------------------------------------------------------------
  // FIFO of 4: {cqid, cid, sqid, status, dw0}
  // ---------------------------------------------------------------------------
  localparam int EW = 3 + 16 + 3 + 15 + 32;
  logic [EW-1:0] q_mem [4];
  logic [2:0]    q_wp, q_rp;
  wire  [2:0]    q_n     = q_wp - q_rp;
  wire           q_empty = (q_n == 3'd0);
  wire  [EW-1:0] q_head  = q_mem[q_rp[1:0]];
  logic          pop;

  assign full  = (q_n == 3'd4);
  assign count = q_n;

  wire push = post && !full && !quit;

  always_ff @(posedge clk) if (push) q_mem[q_wp[1:0]] <= {p_cqid, p_cid, p_sqid, p_status, p_dw0};

  wire [2:0]  h_cq     = q_head[EW-1 -: 3];
  wire [15:0] h_cid    = q_head[EW-4 -: 16];
  wire [2:0]  h_sq     = q_head[EW-20 -: 3];
  wire [14:0] h_status = q_head[46:32];
  wire [31:0] h_dw0    = q_head[31:0];

  assign cur_cq = h_cq;
  assign cur_sq = h_sq;

  // ---------------------------------------------------------------------------
  // Poster
  // ---------------------------------------------------------------------------
  typedef enum logic [2:0] {S_IDLE, S_W0, S_W1, S_REQ, S_WAIT, S_MSIX} st_t;
  st_t st;

  wire [11:0] tail_next = (cq_tail == cq_size) ? 12'd0 : cq_tail + 12'd1;
  wire        q_full    = (tail_next == cq_head);

  logic [63:2] w_haddr;
  logic        w_ien;
  logic [2:0]  w_iv;

  assign cq_wait  = (st == S_IDLE) && !q_empty && cq_en && q_full && !quit;
  assign bm_valid = (st == S_REQ);
  assign bm_haddr = w_haddr;
  assign bm_laddr = LBUF_BASE[31:2] + 30'd16;   // word 8
  assign msix_req = (st == S_MSIX);
  assign msix_vec = w_iv;
  assign active   = (st != S_IDLE);

  always_comb begin
    e_we    = 1'b0;
    e_waddr = 4'd8;
    e_wdata = {32'd0, h_dw0};
    if (st == S_W0) e_we = 1'b1;
    if (st == S_W1) begin
      e_we    = 1'b1;
      e_waddr = 4'd9;
      e_wdata = {h_status, cq_phase, h_cid, 13'd0, h_sq, 4'd0, sq_head};
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st      <= S_IDLE;
      q_wp    <= 3'd0;
      q_rp    <= 3'd0;
      w_haddr <= '0;
      w_ien   <= 1'b0;
      w_iv    <= 3'd0;
      drop    <= 1'b0;
      werr    <= 1'b0;
    end else begin
      drop   <= post && (full || quit);
      werr   <= 1'b0;
      if (push) q_wp <= q_wp + 3'd1;
      if (pop)  q_rp <= q_rp + 3'd1;

      case (st)
        S_IDLE: if (quit) begin
          q_rp <= q_wp;                  // empty the FIFO
        end else if (!q_empty) begin
          if (!cq_en) begin
            drop <= 1'b1;
          end else if (!q_full) begin
            st <= S_W0;
          end
        end

        S_W0: st <= quit ? S_IDLE : S_W1;

        S_W1: begin
          // {CQ base, 12 bits} + 16 x tail, in DWs
          w_haddr <= {cq_base, 10'd0} + {48'd0, cq_tail, 2'b00};
          w_ien   <= cq_ien;
          w_iv    <= cq_iv;
          st      <= quit ? S_IDLE : S_REQ;
        end

        S_REQ: if (bm_ready)  st <= S_WAIT;
               else if (quit) st <= S_IDLE;

        S_WAIT: if (bm_done) begin
          if (bm_cause != 3'd0) begin
            werr <= 1'b1;
            st   <= S_IDLE;
          end else begin
            st     <= w_ien ? S_MSIX : S_IDLE;
          end
        end

        default: if (msix_ack || quit) st <= S_IDLE;   // S_MSIX
      endcase
    end
  end

  // The tail moves in the clock the write ends, so the next entry sees it.
  assign cq_adv = (st == S_WAIT) && bm_done && (bm_cause == 3'd0);

  // The oldest entry leaves when it is dropped or its write has ended.
  assign pop = ((st == S_IDLE) && !quit && !q_empty && !cq_en) || ((st == S_WAIT) && bm_done);

endmodule : nvme_cqe

`default_nettype wire
