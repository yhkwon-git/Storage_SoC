`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// SRAM macros for synthesis: black boxes (no body), one per size used by
// soc_top. Timing for STA is in syn/lib/sram_macros.lib. Only read when
// SYNTHESIS is defined (flow/syn/run_syn.sh); simulation uses mem_array's
// array instead.
// -----------------------------------------------------------------------------

(* blackbox *)
module sram_2048x64 (
  input  wire        CLK,
  input  wire [7:0]  WE,
  input  wire [10:0] WA,
  input  wire [63:0] D,
  input  wire        RE,
  input  wire [10:0] RA,
  output wire [63:0] Q
);
endmodule

(* blackbox *)
module sram_8192x64 (
  input  wire        CLK,
  input  wire [7:0]  WE,
  input  wire [12:0] WA,
  input  wire [63:0] D,
  input  wire        RE,
  input  wire [12:0] RA,
  output wire [63:0] Q
);
endmodule

(* blackbox *)
module sram_1024x64 (
  input  wire        CLK,
  input  wire [7:0]  WE,
  input  wire [9:0]  WA,
  input  wire [63:0] D,
  input  wire        RE,
  input  wire [9:0]  RA,
  output wire [63:0] Q
);
endmodule

`default_nettype wire
