`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// tl_rx_unpack
//
// Packed TLPs (tl_pkg) in, unpacked TLPs out: one header beat with DW0..DW3,
// then the payload in address-aligned beats. The input comes from tl_rx_buf,
// so every TLP is complete and its DW count matches its header.
//
// The header takes two input beats. With a 3DW header the second beat also
// carries payload DW 0, which goes to the aligner as a one-DW beat in lane 1.
// The aligner moves the payload from its packed lanes to lane0 = address
// bit 2 (tl_pkg::h_lane0).
// -----------------------------------------------------------------------------

module tl_rx_unpack (
  input  wire           clk,
  input  wire           rst_n,

  input  wire           in_valid,
  output logic          in_ready,
  input  wire  [63:0]   in_data,
  input  wire           in_eop,
  input  wire           in_ehalf,

  output logic          out_valid,
  input  wire           out_ready,
  output logic          out_hdr,      // this beat is the header
  output logic [127:0]  out_data,     // header DW0..DW3, or payload in [63:0]
  output logic [1:0]    out_dwv,
  output logic          out_last
);

  typedef enum logic [2:0] {S_H0, S_H1, S_HOUT, S_P0, S_PAY} st_t;
  st_t st;

  logic [127:0] hdr;
  logic [31:0]  pay0;
  logic         one_dw;     // a 3DW TLP whose payload is one DW, all in beat 1

  wire has_data = hdr[30];
  wire is_4dw   = hdr[29];

  // Aligner input: the held DW 0 (S_P0) or packed beats (S_PAY).
  logic        a_in_valid, a_in_ready, a_in_last;
  logic [63:0] a_in_data;
  logic [1:0]  a_in_dwv;
  logic        a_out_valid, a_out_ready, a_out_last;
  logic [63:0] a_out_data;
  logic [1:0]  a_out_dwv;

  always_comb begin
    a_in_valid = 1'b0;
    a_in_data  = in_data;
    a_in_dwv   = (in_eop && in_ehalf) ? 2'b01 : 2'b11;
    a_in_last  = in_eop;
    if (st == S_P0) begin
      a_in_valid = 1'b1;
      a_in_data  = {pay0, 32'd0};
      a_in_dwv   = 2'b10;
      a_in_last  = one_dw;
    end else if (st == S_PAY) begin
      a_in_valid = in_valid;
    end
  end

  tl_dw_align u_align (
    .clk       (clk),         .rst_n     (rst_n),
    .in_valid  (a_in_valid),  .in_ready  (a_in_ready), .in_data (a_in_data),
    .in_dwv    (a_in_dwv),    .in_last   (a_in_last),  .out_lane0 (tl_pkg::h_lane0(hdr)),
    .out_valid (a_out_valid), .out_ready (a_out_ready), .out_data (a_out_data),
    .out_dwv   (a_out_dwv),   .out_last  (a_out_last)
  );

  always_comb begin
    out_valid = 1'b0;
    out_hdr   = 1'b0;
    out_data  = {64'd0, a_out_data};
    out_dwv   = a_out_dwv;
    out_last  = a_out_last;
    case (st)
      S_HOUT: begin
        out_valid = 1'b1;
        out_hdr   = 1'b1;
        out_data  = hdr;
        out_dwv   = 2'b00;
        out_last  = !has_data;
      end
      S_PAY, S_P0: out_valid = a_out_valid;
      default: ;
    endcase
  end

  assign in_ready    = (st == S_H0) || (st == S_H1) || ((st == S_PAY) && a_in_ready);
  assign a_out_ready = ((st == S_PAY) || (st == S_P0)) && out_ready;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st     <= S_H0;
      hdr    <= 128'd0;
      pay0   <= 32'd0;
      one_dw <= 1'b0;
    end else begin
      case (st)
        S_H0: if (in_valid) begin
          hdr[63:0] <= in_data;
          st        <= S_H1;
        end
        S_H1: if (in_valid) begin
          hdr[127:64] <= in_data;
          pay0        <= in_data[63:32];
          one_dw      <= in_eop;
          st          <= S_HOUT;
        end
        S_HOUT: if (out_ready) begin
          if (!has_data)   st <= S_H0;
          else if (is_4dw) st <= S_PAY;
          else             st <= S_P0;
        end
        S_P0: if (a_in_ready) begin
          // DW 0 is in the aligner; the rest follows from the input. A
          // one-DW payload has left the aligner in this same clock.
          st <= one_dw ? S_H0 : S_PAY;
        end
        default: if (a_out_valid && out_ready && a_out_last) st <= S_H0;  // S_PAY
      endcase
    end
  end

endmodule : tl_rx_unpack

`default_nettype wire
