`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// rr_arb
//
// Round-robin arbiter with a grant lock.
//
// gnt/idx pick the first requester at or after the priority pointer. When the
// owner raises keep, the current grant is held for the next cycle whatever
// req does; the owner uses this while its output VALID waits for READY, or
// for the rest of a burst. fire marks a completed transfer and moves the
// priority pointer to the requester after the one served.
// -----------------------------------------------------------------------------

module rr_arb #(
  parameter  int N  = 4,
  localparam int IW = (N > 1) ? $clog2(N) : 1
) (
  input  wire           clk,
  input  wire           rst_n,
  input  wire [N-1:0]   req,
  input  wire           keep,
  input  wire           fire,
  output logic [N-1:0]  gnt,
  output logic [IW-1:0] idx
);

  logic          locked_q;
  logic [N-1:0]  gnt_q;
  logic [IW-1:0] idx_q;
  logic [IW-1:0] prio_q;
  logic [N-1:0]  rr_gnt;
  logic [IW-1:0] rr_idx;

  always_comb begin
    logic found;
    int   j;
    found  = 1'b0;
    rr_gnt = '0;
    rr_idx = '0;
    for (int k = 0; k < N; k++) begin
      j = int'(prio_q) + k;
      if (j >= N) j = j - N;
      if (!found && req[j]) begin
        found     = 1'b1;
        rr_gnt[j] = 1'b1;
        rr_idx    = IW'(j);
      end
    end
  end

  assign gnt = locked_q ? gnt_q : rr_gnt;
  assign idx = locked_q ? idx_q : rr_idx;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      locked_q <= 1'b0;
      gnt_q    <= '0;
      idx_q    <= '0;
      prio_q   <= '0;
    end else begin
      locked_q <= keep;
      if (keep) begin
        gnt_q <= gnt;
        idx_q <= idx;
      end
      if (fire) begin
        prio_q <= (idx == IW'(N - 1)) ? '0 : idx + 1'b1;
      end
    end
  end

endmodule : rr_arb

`default_nettype wire
