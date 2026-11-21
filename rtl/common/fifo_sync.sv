`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// fifo_sync
//
// Single-clock FIFO with first-word fall-through: dout is the oldest entry
// while empty is low, and pop removes it. A push to a full FIFO and a pop
// from an empty one are ignored. DEPTH is a power of two and at least 2.
// -----------------------------------------------------------------------------

module fifo_sync #(
  parameter int WIDTH = 8,
  parameter int DEPTH = 4
) (
  input  wire              clk,
  input  wire              rst_n,
  input  wire              push,
  input  wire [WIDTH-1:0]  din,
  output wire              full,
  input  wire              pop,
  output wire [WIDTH-1:0]  dout,
  output wire              empty
);

  localparam int AW = $clog2(DEPTH);

  generate
    if ((DEPTH < 2) || (DEPTH != (1 << AW))) begin : g_illegal
      initial $error("fifo_sync: DEPTH must be a power of two >= 2");
    end
  endgenerate

  logic [WIDTH-1:0] mem [DEPTH];
  logic [AW:0]      wp;
  logic [AW:0]      rp;

  wire do_push = push & ~full;
  wire do_pop  = pop & ~empty;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wp <= '0;
      rp <= '0;
    end else begin
      wp <= wp + {{AW{1'b0}}, do_push};
      rp <= rp + {{AW{1'b0}}, do_pop};
    end
  end

  always_ff @(posedge clk) begin
    if (do_push) begin
      mem[wp[AW-1:0]] <= din;
    end
  end

  assign empty = (wp == rp);
  assign full  = (wp[AW-1:0] == rp[AW-1:0]) && (wp[AW] != rp[AW]);
  assign dout  = mem[rp[AW-1:0]];

endmodule : fifo_sync

`default_nettype wire
