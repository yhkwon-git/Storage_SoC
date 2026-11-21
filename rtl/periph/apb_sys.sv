`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// apb_sys
//
// SYS register block (APB slot 0, 0x4000_0000).
//
//   0x000 ID       RO  0x5353_4F43 ("SSOC")
//   0x004 VERSION  RO  VERSION parameter
//   0x008 SCRATCH  RW  32 bits, byte strobes honored
//   0x010 CONSOLE  WO  bits [7:0]: one character to the simulation console
//   0x014 EXIT     WO  ends the simulation; 0 means pass
// Other offsets answer PSLVERR. Every access completes in one ACCESS cycle.
//
// CONSOLE and EXIT drive console_* and exit_* for one clock; the testbench
// watches them. They stay in the synthesized design as ordinary registers.
// -----------------------------------------------------------------------------

module apb_sys #(
  parameter logic [31:0] VERSION = 32'h0001_0004
) (
  input  wire          clk,
  input  wire          rst_n,
  input  wire          psel,
  input  wire          penable,
  input  wire  [11:0]  paddr,
  input  wire          pwrite,
  input  wire  [31:0]  pwdata,
  input  wire  [3:0]   pstrb,
  output logic [31:0]  prdata,
  output logic         pready,
  output logic         pslverr,

  output logic         console_valid,
  output logic [7:0]   console_char,
  output logic         exit_valid,
  output logic [31:0]  exit_code
);

  localparam logic [31:0] ID = 32'h5353_4F43;

  logic [31:0] scratch;

  wire access = psel && penable;
  wire wr     = access && pwrite;

  assign pready = 1'b1;

  always_comb begin
    prdata  = 32'd0;
    pslverr = 1'b0;
    case (paddr)
      12'h000: prdata = ID;
      12'h004: prdata = VERSION;
      12'h008: prdata = scratch;
      12'h010, 12'h014: prdata = 32'd0;
      default: pslverr = 1'b1;
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      scratch       <= 32'd0;
      console_valid <= 1'b0;
      console_char  <= 8'd0;
      exit_valid    <= 1'b0;
      exit_code     <= 32'd0;
    end else begin
      console_valid <= wr && (paddr == 12'h010);
      exit_valid    <= wr && (paddr == 12'h014);
      if (wr && paddr == 12'h010) console_char <= pwdata[7:0];
      if (wr && paddr == 12'h014) exit_code    <= pwdata;
      if (wr && paddr == 12'h008) begin
        for (int i = 0; i < 4; i++) if (pstrb[i]) scratch[i*8 +: 8] <= pwdata[i*8 +: 8];
      end
    end
  end

endmodule : apb_sys

`default_nettype wire
