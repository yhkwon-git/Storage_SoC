`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// cdc_async_fifo
//
// Dual-clock FIFO with first-word fall-through: rd_data is the oldest word
// while rd_empty is low, and rd_en pops it. Each side moves one word per clock.
//
// Pointers are binary in their own clock and cross as Gray code through
// cdc_sync_2ff. The memory is written on the same wr_clk edge that advances
// the write pointer, so a word is in memory before its pointer can reach the
// read side (two rd_clk edges at the earliest), whatever the clock ratio.
//
// wr_full is registered in wr_clk from the next write pointer and the
// synchronized read pointer; rd_empty is registered in rd_clk the same way.
// Both are conservative: the writer sees a pop two wr_clk edges late and the
// reader sees a push two rd_clk edges late.
//
// rd_data is a DEPTH:1 mux on the binary read address. Its paths from the
// memory flops (wr_clk) into rd_clk logic need a max-delay constraint, like
// the Gray pointers (docs/02_common_blocks.md).
//
// DEPTH is a power of two and at least 4. wr_rst_n and rd_rst_n are asserted
// together and each released synchronously to its own clock.
//
// Same module name and ports as the axi-pcie-subsystem b64e36a FIFO, which it
// replaces; docs/02_common_blocks.md has the measurements behind the change.
// -----------------------------------------------------------------------------

module cdc_async_fifo #(
  parameter int WIDTH = 32,
  parameter int DEPTH = 16
) (
  input  wire                  wr_clk,
  input  wire                  wr_rst_n,
  input  wire                  wr_en,
  input  wire [WIDTH-1:0]      wr_data,
  output wire                  wr_full,

  input  wire                  rd_clk,
  input  wire                  rd_rst_n,
  input  wire                  rd_en,
  output wire [WIDTH-1:0]      rd_data,
  output wire                  rd_empty
);

  localparam int ADDR_W = $clog2(DEPTH);
  localparam int PTR_W  = ADDR_W + 1;

  generate
    if ((WIDTH < 1) || (DEPTH < 4) || (DEPTH != (1 << ADDR_W))) begin : g_illegal
      initial $error("cdc_async_fifo: WIDTH >= 1 and DEPTH must be a power of two >= 4");
    end
  endgenerate

  function automatic logic [PTR_W-1:0] bin2gray(input logic [PTR_W-1:0] bin);
    return bin ^ (bin >> 1);
  endfunction

  logic [WIDTH-1:0] mem [DEPTH];

  logic [PTR_W-1:0] wr_bin;
  logic [PTR_W-1:0] wr_gray;
  logic             wr_full_q;
  logic [PTR_W-1:0] rd_bin;
  logic [PTR_W-1:0] rd_gray;
  logic             rd_empty_q;

  wire  [PTR_W-1:0] rd_gray_in_wr;
  wire  [PTR_W-1:0] wr_gray_in_rd;

  cdc_sync_2ff #(.WIDTH(PTR_W)) u_sync_rd_to_wr (
    .clk       (wr_clk),
    .rst_n     (wr_rst_n),
    .din_async (rd_gray),
    .dout      (rd_gray_in_wr)
  );

  cdc_sync_2ff #(.WIDTH(PTR_W)) u_sync_wr_to_rd (
    .clk       (rd_clk),
    .rst_n     (rd_rst_n),
    .din_async (wr_gray),
    .dout      (wr_gray_in_rd)
  );

  // Write side.
  wire             wr_fire      = wr_en & ~wr_full_q;
  wire [PTR_W-1:0] wr_bin_next  = wr_bin + {{(PTR_W-1){1'b0}}, wr_fire};
  wire [PTR_W-1:0] wr_gray_next = bin2gray(wr_bin_next);
  // Full when the next write pointer equals the read pointer with its two
  // Gray MSBs inverted: the writer is one lap ahead.
  wire             wr_full_next = (wr_gray_next == {~rd_gray_in_wr[PTR_W-1:PTR_W-2],
                                                     rd_gray_in_wr[PTR_W-3:0]});

  always_ff @(posedge wr_clk or negedge wr_rst_n) begin
    if (!wr_rst_n) begin
      wr_bin    <= '0;
      wr_gray   <= '0;
      wr_full_q <= 1'b0;
    end else begin
      wr_bin    <= wr_bin_next;
      wr_gray   <= wr_gray_next;
      wr_full_q <= wr_full_next;
    end
  end

  always_ff @(posedge wr_clk) begin
    if (wr_fire) begin
      mem[wr_bin[ADDR_W-1:0]] <= wr_data;
    end
  end

  // Read side.
  wire             rd_fire       = rd_en & ~rd_empty_q;
  wire [PTR_W-1:0] rd_bin_next   = rd_bin + {{(PTR_W-1){1'b0}}, rd_fire};
  wire [PTR_W-1:0] rd_gray_next  = bin2gray(rd_bin_next);
  wire             rd_empty_next = (rd_gray_next == wr_gray_in_rd);

  always_ff @(posedge rd_clk or negedge rd_rst_n) begin
    if (!rd_rst_n) begin
      rd_bin     <= '0;
      rd_gray    <= '0;
      rd_empty_q <= 1'b1;
    end else begin
      rd_bin     <= rd_bin_next;
      rd_gray    <= rd_gray_next;
      rd_empty_q <= rd_empty_next;
    end
  end

  assign rd_data  = mem[rd_bin[ADDR_W-1:0]];
  assign wr_full  = wr_full_q;
  assign rd_empty = rd_empty_q;

endmodule : cdc_async_fifo

`default_nettype wire
