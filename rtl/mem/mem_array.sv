`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// mem_array
//
// Storage of axi_mem: WORDS 64-bit words, one write port with byte enables
// and one read port with a registered output (rdata changes on the clock
// after re). A read and a write of the same word in one clock read the old
// value.
//
// Simulation: an array, loaded from +<INIT_PLUSARG>=<file> with $readmemh
// when INIT_PLUSARG is not empty.
//
// Synthesis (SYNTHESIS defined): one SRAM macro per size, sram_<WORDS>x64,
// black boxes whose timing comes from syn/lib/sram_macros.lib. Their numbers
// are assumptions, not a generated SRAM (docs/09_timing.md). The boot ROM uses
// the same macro with its write port tied off.
// -----------------------------------------------------------------------------

module mem_array #(
  parameter int    WORDS        = 2048,
  parameter string INIT_PLUSARG = ""
) (
  input  wire                      clk,
  input  wire  [7:0]               we,
  input  wire  [$clog2(WORDS)-1:0] waddr,
  input  wire  [63:0]              wdata,
  input  wire                      re,
  input  wire  [$clog2(WORDS)-1:0] raddr,
  output logic [63:0]              rdata
);

`ifndef SYNTHESIS
  logic [63:0] mem [WORDS];

  initial begin
    string f;
    if (INIT_PLUSARG != "" && $value$plusargs({INIT_PLUSARG, "=%s"}, f)) begin
      $readmemh(f, mem);
    end
  end

  always_ff @(posedge clk) begin
    for (int i = 0; i < 8; i++) begin
      if (we[i]) mem[waddr][i*8 +: 8] <= wdata[i*8 +: 8];
    end
  end

  always_ff @(posedge clk) begin
    if (re) rdata <= mem[raddr];
  end
`else
  if (WORDS == 2048) begin : g_2k
    sram_2048x64 u_sram (.CLK(clk), .WE(we), .WA(waddr), .D(wdata), .RE(re), .RA(raddr), .Q(rdata));
  end else if (WORDS == 8192) begin : g_8k
    sram_8192x64 u_sram (.CLK(clk), .WE(we), .WA(waddr), .D(wdata), .RE(re), .RA(raddr), .Q(rdata));
  end else if (WORDS == 1024) begin : g_1k
    sram_1024x64 u_sram (.CLK(clk), .WE(we), .WA(waddr), .D(wdata), .RE(re), .RA(raddr), .Q(rdata));
  end
`endif

endmodule : mem_array

`default_nettype wire
