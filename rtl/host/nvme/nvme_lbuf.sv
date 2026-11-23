`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// nvme_lbuf
//
// The NVMe controller's local buffer (step 2-3, docs/12_nvme_data.md): WORDS
// 64-bit words in flops, an AXI4 slave on the crossbar (S5, 0x5000_0000) and
// a side port for the controller's engines. The transaction layer's bus
// master reaches it like any memory: it writes PRP list entries fetched from
// the host into it, and reads completion queue entries from it to write them
// to the host.
//
//   words 0-7   PRP list entries (one fetch of up to 8)
//   words 8-9   completion queue entry being posted
//   words 10-15 spare
//
// The AXI side works like axi_mem: one write burst and one read burst at a
// time, read data registered. The word address is addr[3 +: log2(WORDS)];
// the window repeats above that. The side port reads combinationally and
// writes whole words; a side write and an AXI write to the same word in one
// clock leave the AXI data (the engines never do that: they write only the
// CQE words, which the bus master only reads).
// -----------------------------------------------------------------------------

module nvme_lbuf #(
  parameter int WORDS = 16,
  parameter int IDW   = 4,
  localparam int WA   = $clog2(WORDS)
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
  input  wire              s_rready,

  // Side port
  input  wire  [WA-1:0]    e_raddr,
  output logic [63:0]      e_rdata,
  input  wire              e_we,
  input  wire  [WA-1:0]    e_waddr,
  input  wire  [63:0]      e_wdata
);

  logic [63:0] mem [WORDS];

  // ---------------------------------------------------------------------------
  // Write path
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
        end
      end
    end
  end

  assign s_bresp = 2'b00;

  // Storage: no reset (data), side write first so that an AXI write to the
  // same word wins.
  always_ff @(posedge clk) begin
    if (e_we) mem[e_waddr] <= e_wdata;
    if (w_hs)
      for (int i = 0; i < 8; i++)
        if (s_wstrb[i]) mem[w_ptr][8*i +: 8] <= s_wdata[8*i +: 8];
  end

  assign e_rdata = mem[e_raddr];

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

  // Read data register: the word of a new AR, or the next word of the burst.
  always_ff @(posedge clk) begin
    if (ar_hs)                    s_rdata <= mem[s_araddr[3 +: WA]];
    else if (r_hs && !s_rlast)    s_rdata <= mem[r_ptr];
  end

  /* verilator lint_off UNUSEDSIGNAL */
  wire unused_ok = ^{s_awaddr, s_araddr, s_awlen};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule : nvme_lbuf

`default_nettype wire
