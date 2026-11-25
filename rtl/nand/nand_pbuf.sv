`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// nand_pbuf
//
// Page buffer of one NAND channel (step 3-1, docs/15_nand_channel.md): WORDS
// 64-bit words in mem_array, an AXI4 slave on the crossbar (S3 or S4) and a
// stream port for the channel's data mover.
//
// The AXI side works exactly like axi_mem: separate read and write paths, one
// burst of each at a time, read data one clock after the address. The stream
// port takes a memory port only in a clock the AXI side leaves it free:
//   - a stream read when the AXI read path neither reads a word this clock nor
//     holds a beat the master has not taken (that beat's data is the memory's
//     output, which a stream read would replace);
//   - a stream write when no W beat is written this clock.
// So AXI timing is unchanged, and the stream waits for a burst in progress.
// A stream read's word is on x_rdata in the clock after the grant.
// -----------------------------------------------------------------------------

module nand_pbuf #(
  parameter int WORDS = 1024,
  parameter int IDW   = 4,
  localparam int WA   = $clog2(WORDS)
) (
  input  wire              clk,
  input  wire              rst_n,

  // AXI4 slave
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
  input  wire              s_rready,

  // Stream port
  input  wire              x_re,
  input  wire  [WA-1:0]    x_raddr,
  output logic             x_rgnt,
  output logic [63:0]      x_rdata,
  input  wire  [7:0]       x_we,
  input  wire  [WA-1:0]    x_waddr,
  input  wire  [63:0]      x_wdata,
  output logic             x_wgnt
);

  logic [7:0]    m_we;
  logic [WA-1:0] m_waddr;
  logic [63:0]   m_wdata;
  logic          m_re;
  logic [WA-1:0] m_raddr;
  logic [63:0]   m_rdata;

  // ---------------------------------------------------------------------------
  // AXI write path (as axi_mem)
  // ---------------------------------------------------------------------------
  logic          w_busy;
  logic [WA-1:0] w_ptr;

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
          s_bresp  <= 2'b00;
        end
      end
    end
  end

  // ---------------------------------------------------------------------------
  // AXI read path (as axi_mem)
  // ---------------------------------------------------------------------------
  logic [WA-1:0] r_ptr;
  logic [7:0]    r_left;

  assign s_rresp   = 2'b00;
  assign s_rlast   = (r_left == 8'd0);
  assign s_arready = !s_rvalid || (s_rready && s_rlast);
  assign s_rdata   = m_rdata;

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

  wire axi_re = ar_hs || (r_hs && !s_rlast);

  // ---------------------------------------------------------------------------
  // Memory ports: the AXI side first, the stream in the clocks left over
  // ---------------------------------------------------------------------------
  assign x_rgnt  = x_re && !axi_re && !(s_rvalid && !s_rready);
  assign x_wgnt  = (x_we != 8'd0) && !w_hs;
  assign x_rdata = m_rdata;

  assign m_re    = axi_re || x_rgnt;
  assign m_raddr = axi_re ? (ar_hs ? s_araddr[3 +: WA] : r_ptr) : x_raddr;
  assign m_we    = w_hs ? s_wstrb : (x_wgnt ? x_we : 8'd0);
  assign m_waddr = w_hs ? w_ptr : x_waddr;
  assign m_wdata = w_hs ? s_wdata : x_wdata;

  mem_array #(.WORDS(WORDS)) u_array (
    .clk   (clk),
    .we    (m_we),
    .waddr (m_waddr),
    .wdata (m_wdata),
    .re    (m_re),
    .raddr (m_raddr),
    .rdata (m_rdata)
  );

  // Address bits above the window and below the word are decoded elsewhere;
  // the write burst ends on WLAST.
  /* verilator lint_off UNUSEDSIGNAL */
  wire unused_ok = ^{s_awaddr, s_araddr, s_awlen};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule : nand_pbuf

`default_nettype wire
