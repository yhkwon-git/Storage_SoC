`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// tl_tx_pack
//
// Unpacked TLPs in (a header beat, then address-aligned payload beats; the
// source puts payload DW 0 in lane tl_pkg::h_lane0 of its header), packed
// TLPs out (tl_pkg). The inverse of tl_rx_unpack.
//
//   4DW header   {DW1, DW0}, {DW3, DW2}, then the payload from lane 0
//   3DW header   {DW1, DW0}, then {payload DW 0, DW2} and the rest of the
//                payload from lane 0, or {-, DW2} alone when there is none
//
// The aligner moves the payload to lane 0 (4DW) or lane 1 (3DW); for a 3DW
// header its first output beat holds only lane 1, and DW2 fills lane 0.
// -----------------------------------------------------------------------------

module tl_tx_pack (
  input  wire           clk,
  input  wire           rst_n,

  input  wire           in_valid,
  output logic          in_ready,
  input  wire           in_hdr,
  input  wire  [127:0]  in_data,
  input  wire  [1:0]    in_dwv,
  input  wire           in_last,

  output logic          out_valid,
  input  wire           out_ready,
  output logic [63:0]   out_data,
  output logic          out_sop,
  output logic          out_eop,
  output logic          out_ehalf
);

  typedef enum logic [1:0] {S_HDR, S_B0, S_B1, S_PAY} st_t;
  st_t st;

  logic [127:0] hdr;
  logic         first;    // the next aligner beat is the payload's first
  wire          has_data = hdr[30];
  wire          is_4dw   = hdr[29];

  logic        a_in_valid, a_in_ready;
  logic        a_out_valid, a_out_ready, a_out_last;
  logic [63:0] a_out_data;
  logic [1:0]  a_out_dwv;

  assign a_in_valid = (st == S_PAY) && in_valid && !in_hdr;

  tl_dw_align u_align (
    .clk       (clk),         .rst_n     (rst_n),
    .in_valid  (a_in_valid),  .in_ready  (a_in_ready), .in_data (in_data[63:0]),
    .in_dwv    (in_dwv),      .in_last   (in_last),    .out_lane0 (!is_4dw),
    .out_valid (a_out_valid), .out_ready (a_out_ready), .out_data (a_out_data),
    .out_dwv   (a_out_dwv),   .out_last  (a_out_last)
  );

  assign in_ready    = (st == S_HDR) || ((st == S_PAY) && a_in_ready);
  assign a_out_ready = (st == S_PAY) && out_ready;

  always_comb begin
    out_valid   = 1'b0;
    out_data    = a_out_data;
    out_sop     = 1'b0;
    out_eop     = a_out_last;
    out_ehalf   = a_out_last && (a_out_dwv == 2'b01);
    case (st)
      S_HDR: ;
      S_B0: begin
        out_valid = 1'b1;
        out_data  = hdr[63:0];
        out_sop   = 1'b1;
        out_eop   = 1'b0;
        out_ehalf = 1'b0;
      end
      S_B1: begin
        // 4DW header, or 3DW without payload.
        out_valid = 1'b1;
        out_data  = hdr[127:64];
        out_eop   = !has_data;
        out_ehalf = !has_data && !is_4dw;
      end
      default: begin  // S_PAY
        out_valid = a_out_valid;
        if (first && !is_4dw) out_data = {a_out_data[63:32], hdr[95:64]};
      end
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st    <= S_HDR;
      hdr   <= 128'd0;
      first <= 1'b0;
    end else begin
      case (st)
        S_HDR: if (in_valid) begin
          // A payload beat here would be a source error; it is taken as a
          // header all the same.
          hdr <= in_data;
          st  <= S_B0;
        end
        S_B0: if (out_ready) begin
          first <= 1'b1;
          st    <= (is_4dw || !has_data) ? S_B1 : S_PAY;
        end
        S_B1: if (out_ready) st <= has_data ? S_PAY : S_HDR;
        default: if (a_out_valid && out_ready) begin
          first <= 1'b0;
          if (a_out_last) st <= S_HDR;
        end
      endcase
    end
  end

  /* verilator lint_off UNUSEDSIGNAL */
  wire unused_ok = ^{in_data[127:64]};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule : tl_tx_pack

`default_nettype wire
