`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// axi_id_tracker
//
// Outstanding transactions of one master in one direction (writes or reads).
// For each ID it keeps the number outstanding and the target they went to.
//
// allow is high when a request with req_id to req_tgt may go now:
//   * fewer than MAX_OUT transactions are outstanding, and
//   * req_id has nothing outstanding, or its outstanding ones went to req_tgt.
// The second rule keeps responses with the same ID in order without a reorder
// buffer: they all come from one target, and a target answers one ID in order.
// id_block is high when the second rule alone would hold the request.
//
// push: a request was accepted. done/done_id: a response finished (B, or the
// R beat with RLAST).
// -----------------------------------------------------------------------------

module axi_id_tracker #(
  parameter  int IDW     = 2,
  parameter  int TW      = 3,
  parameter  int MAX_OUT = 4,
  localparam int CW      = $clog2(MAX_OUT + 1)
) (
  input  wire            clk,
  input  wire            rst_n,
  input  wire [IDW-1:0]  req_id,
  input  wire [TW-1:0]   req_tgt,
  output wire            allow,
  output wire            id_block,
  input  wire            push,
  input  wire            done,
  input  wire [IDW-1:0]  done_id
);

  localparam int NID = 1 << IDW;

  logic [CW-1:0] cnt [NID];
  logic [TW-1:0] tgt [NID];
  logic [CW-1:0] total;

  assign id_block = (cnt[req_id] != '0) && (tgt[req_id] != req_tgt);
  assign allow    = (total < CW'(MAX_OUT)) && !id_block;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      total <= '0;
      for (int i = 0; i < NID; i++) begin
        cnt[i] <= '0;
        tgt[i] <= '0;
      end
    end else begin
      for (int i = 0; i < NID; i++) begin
        if (push && (req_id == IDW'(i)) && !(done && (done_id == IDW'(i)))) begin
          cnt[i] <= cnt[i] + 1'b1;
        end else if (done && (done_id == IDW'(i)) && !(push && (req_id == IDW'(i)))) begin
          cnt[i] <= cnt[i] - 1'b1;
        end
        if (push && (req_id == IDW'(i))) begin
          tgt[i] <= req_tgt;
        end
      end
      if (push && !done) begin
        total <= total + 1'b1;
      end else if (done && !push) begin
        total <= total - 1'b1;
      end
    end
  end

endmodule : axi_id_tracker

`default_nettype wire
