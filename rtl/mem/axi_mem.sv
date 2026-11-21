`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// axi_mem
//
// AXI4 slave memory of WORDS 64-bit words: the boot ROM (READ_ONLY = 1), the
// SRAM, and for now the NAND page-buffer windows.
//
// Reads and writes have separate paths, so a pending B never holds up R and
// the reverse. One read burst and one write burst are served at a time, and a
// read burst is never interleaved with another; a new AR is taken in the
// clock that delivers the previous RLAST, so bursts can run back to back.
// Read data is registered: the first beat follows the AR by one clock.
//
// The word address is addr[3 +: log2(WORDS)]; the crossbar has already
// decoded the window. A narrow 32-bit access reads or writes the word that
// holds it, with WSTRB selecting the bytes.
//
// READ_ONLY: W beats are accepted and dropped, and B answers SLVERR.
//
// Simulation only: if INIT_PLUSARG is not empty and +<INIT_PLUSARG>=<file> is
// given, the memory is loaded with $readmemh from that file (one 64-bit word
// per line). Synthesis treats the array as a black box (docs/01, section 9).
// -----------------------------------------------------------------------------

module axi_mem #(
  parameter int    WORDS        = 2048,
  parameter bit    READ_ONLY    = 1'b0,
  parameter int    IDW          = 4,
  parameter string INIT_PLUSARG = ""
) (
  input  wire              clk,
  input  wire              rst_n,

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
  input  wire              s_rready
);

  localparam int WA = $clog2(WORDS);

  logic [63:0] mem [WORDS];

`ifndef SYNTHESIS
  initial begin
    string f;
    if (INIT_PLUSARG != "" && $value$plusargs({INIT_PLUSARG, "=%s"}, f)) begin
      $readmemh(f, mem);
    end
  end
`endif

  // ---------------------------------------------------------------------------
  // Write path
  // ---------------------------------------------------------------------------
  logic           w_busy;
  logic [WA-1:0]  w_ptr;

  assign s_awready = !w_busy && (!s_bvalid || s_bready);
  assign s_wready  = w_busy;

  wire aw_hs = s_awvalid && s_awready;
  wire w_hs  = s_wvalid && s_wready;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      w_busy   <= 1'b0;
      w_ptr    <= '0;
      s_bid    <= '0;
      s_bresp  <= 2'b00;
      s_bvalid <= 1'b0;
    end else begin
      if (s_bvalid && s_bready) s_bvalid <= 1'b0;
      if (aw_hs) begin
        w_busy <= 1'b1;
        w_ptr  <= s_awaddr[3 +: WA];
        s_bid  <= s_awid;
      end
      if (w_hs) begin
        w_ptr <= w_ptr + 1'b1;
        if (s_wlast) begin
          w_busy   <= 1'b0;
          s_bvalid <= 1'b1;
          s_bresp  <= READ_ONLY ? 2'b10 : 2'b00;
        end
      end
    end
  end

  always_ff @(posedge clk) begin
    if (w_hs && !READ_ONLY) begin
      for (int i = 0; i < 8; i++) begin
        if (s_wstrb[i]) mem[w_ptr][i*8 +: 8] <= s_wdata[i*8 +: 8];
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Read path
  // ---------------------------------------------------------------------------
  logic [WA-1:0] r_ptr;
  logic [7:0]    r_left;

  assign s_rresp   = 2'b00;
  assign s_rlast   = (r_left == 8'd0);
  assign s_arready = !s_rvalid || (s_rready && s_rlast);

  wire ar_hs = s_arvalid && s_arready;
  wire r_hs  = s_rvalid && s_rready;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s_rvalid <= 1'b0;
      s_rid    <= '0;
      r_ptr    <= '0;
      r_left   <= '0;
    end else if (ar_hs) begin
      s_rvalid <= 1'b1;
      s_rid    <= s_arid;
      r_ptr    <= s_araddr[3 +: WA] + 1'b1;
      r_left   <= s_arlen;
    end else if (r_hs) begin
      if (s_rlast) begin
        s_rvalid <= 1'b0;
      end else begin
        r_ptr  <= r_ptr + 1'b1;
        r_left <= r_left - 1'b1;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (ar_hs) begin
      s_rdata <= mem[s_araddr[3 +: WA]];
    end else if (r_hs && !s_rlast) begin
      s_rdata <= mem[r_ptr];
    end
  end

  // Address bits above the window and below the word are decoded elsewhere;
  // the write burst ends on WLAST, so AWLEN is not needed.
  /* verilator lint_off UNUSEDSIGNAL */
  wire unused_ok = ^{s_awaddr, s_araddr, s_awlen};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule : axi_mem

`default_nettype wire
