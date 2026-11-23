`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// tl_wr
//
// AXI4 write engine of the transaction layer. It writes TLP payloads into the
// SoC: inbound memory writes (owner 0) and the data of completions for the
// bus master's reads (owner 1). One job at a time, one AWID (0), so B
// responses come back in job order.
//
// A job is a DW-aligned AXI byte address, a length in DWs and the first and
// last byte enables of the TLP; the payload's first beat shows its lane.
// Bursts are INCR of 64-bit beats split at 128-byte boundaries (16 beats); a
// one-DW job is a single 32-bit beat, so a register behind the APB bridge
// sees one word.
// Jobs never cross a 4 KiB boundary (the dispatcher and the bus master make
// sure). The payload passes an aligner from its TLP lane to the AXI address's
// lane. Strobes: First BE on the first DW, Last BE on the last (when there
// are two or more), all bytes between.
//
// The burst addresses do not depend on the data, so AW can run ahead of W.
// W follows AW at the crossbar, and the payload is already complete in the
// receive buffer, so a burst does not hold the W channel waiting for data.
//
// Every AW pushes {owner, tag, last burst of the job} into a FIFO that B
// responses pop; when a job's last B returns, done_* reports the job with
// the OR of its responses. jobs_acc and jobs_done count jobs accepted and
// finished (8 bits, wrapping); inbound reads wait on them (tl_rd).
// -----------------------------------------------------------------------------

module tl_wr #(
  parameter int B_DEPTH = 8
) (
  input  wire          clk,
  input  wire          rst_n,

  // Job
  input  wire          job_valid,
  output logic         job_ready,
  input  wire  [31:0]  job_addr,
  input  wire  [10:0]  job_len,
  input  wire  [3:0]   job_fbe,
  input  wire  [3:0]   job_lbe,

  input  wire          job_owner,
  input  wire  [3:0]   job_tag,

  // Payload of the current job, unpacked (tl_pkg)
  input  wire          pay_valid,
  output logic         pay_ready,
  input  wire  [63:0]  pay_data,
  input  wire  [1:0]   pay_dwv,
  input  wire          pay_last,

  // AXI4 write channels (M3, AWID 0)
  output logic [31:0]  m_awaddr,
  output logic [7:0]   m_awlen,
  output logic [2:0]   m_awsize,
  output logic         m_awvalid,
  input  wire          m_awready,
  output logic [63:0]  m_wdata,
  output logic [7:0]   m_wstrb,
  output logic         m_wlast,
  output logic         m_wvalid,
  input  wire          m_wready,
  input  wire  [1:0]   m_bresp,
  input  wire          m_bvalid,
  output logic         m_bready,

  // Results
  output logic         done_valid,   // pulse: a job's last B
  output logic         done_owner,
  output logic [3:0]   done_tag,
  output logic         done_err,
  output logic [7:0]   jobs_acc,
  output logic [7:0]   jobs_done,
  output logic         idle
);

  // ---------------------------------------------------------------------------
  // Current job
  // ---------------------------------------------------------------------------
  logic        busy, aw_done, w_done;
  logic [31:0] addr;
  logic [10:0] len;
  logic [3:0]  fbe, lbe;
  logic        owner;
  logic [3:0]  tag;

  // QW (8-byte) indexes of the first and last beat.

  wire [29:0] dw_last  = addr[31:2] + {19'd0, len} - 30'd1;   // bit 0 unused
  wire [28:0] qw_last  = dw_last[29:1];
  wire        narrow   = (len == 11'd1);

  assign job_ready = !busy;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      busy  <= 1'b0;
      addr  <= 32'd0;
      len   <= 11'd0;
      fbe   <= 4'd0;
      lbe   <= 4'd0;
      owner <= 1'b0;
      tag   <= 4'd0;
      jobs_acc <= 8'd0;
    end else if (job_valid && job_ready) begin
      busy  <= 1'b1;
      addr  <= job_addr;
      len   <= job_len;
      fbe   <= job_fbe;
      lbe   <= job_lbe;
      owner <= job_owner;
      tag   <= job_tag;
      jobs_acc <= jobs_acc + 8'd1;
    end else if (busy && aw_done && w_done) begin
      busy <= 1'b0;
    end
  end

  // ---------------------------------------------------------------------------
  // AW
  // ---------------------------------------------------------------------------
  logic [28:0] aw_qw;      // first beat of the next burst
  logic        b_full;

  wire [28:0] aw_end  = ((aw_qw | 29'd15) < qw_last) ? (aw_qw | 29'd15) : qw_last;
  wire        aw_lastb = (aw_end == qw_last);

  assign m_awvalid = busy && !aw_done && !b_full;
  assign m_awaddr  = narrow ? {addr[31:2], 2'b00} : {aw_qw, 3'b000};
  assign m_awlen   = narrow ? 8'd0 : 8'(aw_end - aw_qw);
  assign m_awsize  = narrow ? 3'd2 : 3'd3;

  wire aw_hs = m_awvalid && m_awready;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      aw_qw   <= 29'd0;
      aw_done <= 1'b1;
    end else if (job_valid && job_ready) begin
      aw_qw   <= job_addr[31:3];
      aw_done <= 1'b0;
    end else if (aw_hs) begin
      aw_qw <= aw_end + 29'd1;
      if (aw_lastb) aw_done <= 1'b1;
    end
  end

  // ---------------------------------------------------------------------------
  // W: aligner to the AXI lane, strobes, WLAST at burst ends
  // ---------------------------------------------------------------------------
  logic        a_valid, a_ready, a_last;
  logic [63:0] a_data;
  logic [1:0]  a_dwv;
  logic [10:0] w_dw;       // DWs written so far
  logic [28:0] w_qw;       // QW index of the next beat

  tl_dw_align u_align (
    .clk       (clk),       .rst_n     (rst_n),
    .in_valid  (pay_valid && busy && !w_done), .in_ready (pay_ready), .in_data (pay_data),
    .in_dwv    (pay_dwv),   .in_last   (pay_last),  .out_lane0 (addr[2]),
    .out_valid (a_valid),   .out_ready (a_ready),   .out_data  (a_data),
    .out_dwv   (a_dwv),     .out_last  (a_last)
  );

  // DW index of each lane in this beat, and its byte enables.
  wire [10:0] idx0 = w_dw;
  wire [10:0] idx1 = w_dw + (a_dwv[0] ? 11'd1 : 11'd0);

  function automatic logic [3:0] be_of(input logic [10:0] i, input logic [10:0] n,
                                       input logic [3:0] f, input logic [3:0] l);
    if (i == 11'd0)     return f;
    if (i == n - 11'd1) return l;
    return 4'hF;
  endfunction

  assign m_wvalid = a_valid;
  assign a_ready  = m_wready;
  assign m_wdata  = a_data;
  assign m_wstrb  = {a_dwv[1] ? be_of(idx1, len, fbe, lbe) : 4'h0,
                     a_dwv[0] ? be_of(idx0, len, fbe, lbe) : 4'h0};
  assign m_wlast  = narrow || (w_qw == qw_last) || (w_qw[3:0] == 4'hF);

  wire w_hs = m_wvalid && m_wready;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      w_dw   <= 11'd0;
      w_qw   <= 29'd0;
      w_done <= 1'b1;
    end else if (job_valid && job_ready) begin
      w_dw   <= 11'd0;
      w_qw   <= job_addr[31:3];
      w_done <= 1'b0;
    end else if (w_hs) begin
      w_dw <= w_dw + {9'd0, 1'b0, a_dwv[0]} + {9'd0, 1'b0, a_dwv[1]};
      w_qw <= w_qw + 29'd1;
      if (a_last) w_done <= 1'b1;
    end
  end

  // ---------------------------------------------------------------------------
  // B
  // ---------------------------------------------------------------------------
  logic       bq_empty;
  logic [5:0] bq_out;
  logic       b_err_acc;

  fifo_sync #(.WIDTH(6), .DEPTH(B_DEPTH)) u_bq (
    .clk   (clk),    .rst_n (rst_n),
    .push  (aw_hs),  .din   ({owner, tag, aw_lastb}), .full (b_full),
    .pop   (m_bvalid && m_bready), .dout (bq_out),   .empty (bq_empty)
  );

  assign m_bready = !bq_empty;

  wire b_hs  = m_bvalid && m_bready;
  wire b_err = (m_bresp != 2'b00);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      b_err_acc  <= 1'b0;
      done_valid <= 1'b0;
      done_owner <= 1'b0;
      done_tag   <= 4'd0;
      done_err   <= 1'b0;
      jobs_done  <= 8'd0;
    end else begin
      done_valid <= 1'b0;
      if (b_hs) begin
        if (bq_out[0]) begin
          done_valid <= 1'b1;
          done_owner <= bq_out[5];
          done_tag   <= bq_out[4:1];
          done_err   <= b_err_acc || b_err;
          b_err_acc  <= 1'b0;
          jobs_done  <= jobs_done + 8'd1;
        end else begin
          b_err_acc <= b_err_acc || b_err;
        end
      end
    end
  end

  assign idle = !busy && bq_empty;

  /* verilator lint_off UNUSEDSIGNAL */
  wire unused_ok = ^{addr[1:0], dw_last[0]};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule : tl_wr

`default_nettype wire
