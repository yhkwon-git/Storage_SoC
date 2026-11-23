`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// tl_rx_buf
//
// Store-and-forward receive buffer for packed TLPs (tl_pkg). A TLP becomes
// visible to the reader only after its last beat has arrived and its size
// matches its header, so the transaction layer never acts on part of a TLP.
// A TLP that fails is removed as a whole (the write pointer goes back to the
// end of the last committed TLP) and reported:
//
//   malformed   first beat without sop (a run of such beats counts once); sop
//               inside a TLP; DW count different from the header (3 or 4
//               header DWs plus Length for a TLP with data); payload longer
//               than MAX_PAY_DW; a TLP prefix (fmt 100); TD = 1 (an ECRC
//               digest, not supported here)
//   discarded   in_bad on the last beat: the link layer (step 2-6) found the
//               TLP corrupt. Not an error of the transaction layer, so it is
//               only counted.
//
// A TLP that is known to fail from its first beat, or that has grown past
// its expected size, is not stored: the rest of it is taken and dropped until
// eop. A sop inside a TLP ends that TLP and the one it starts. The buffer
// holds DEPTH beats and the largest TLP accepted must fit, so the writer can
// always finish one.
// -----------------------------------------------------------------------------

module tl_rx_buf #(
  parameter int DEPTH      = 64,
  parameter int MAX_PAY_DW = 64
) (
  input  wire          clk,
  input  wire          rst_n,

  input  wire          in_valid,
  output logic         in_ready,
  input  wire  [63:0]  in_data,
  input  wire          in_sop,
  input  wire          in_eop,
  input  wire          in_ehalf,
  input  wire          in_bad,

  output logic         out_valid,
  input  wire          out_ready,
  output logic [63:0]  out_data,
  output logic         out_sop,
  output logic         out_eop,
  output logic         out_ehalf,

  output logic         malformed,
  output logic         discarded
);

  localparam int AW = $clog2(DEPTH);

  generate
    if ((DEPTH != (1 << AW)) || (DEPTH < ((4 + MAX_PAY_DW + 1) / 2))) begin : g_illegal
      initial $error("tl_rx_buf: DEPTH must be a power of two that holds the largest TLP");
    end
  endgenerate

  logic [66:0] mem [DEPTH];
  logic [AW:0] wp, cp, rp;

  // Between TLPs, storing one, dropping one until eop, dropping stray beats
  // until a sop.
  typedef enum logic [1:0] {S_IDLE, S_STORE, S_DROP, S_STRAY} st_t;
  st_t         st;
  logic [10:0] dw_cnt;    // DWs of the current TLP so far
  logic [10:0] dw_exp;    // DWs it should have

  wire [AW:0] used  = wp - rp;
  wire        space = (used != (AW+1)'(DEPTH));

  // A first beat: what its header says.
  wire [31:0] dw0      = in_data[31:0];
  wire [2:0]  fmt      = dw0[31:29];
  wire [10:0] len      = (dw0[9:0] == 10'd0) ? 11'd1024 : {1'b0, dw0[9:0]};
  wire        has_data = fmt[1];
  wire [10:0] exp_dws  = (fmt[0] ? 11'd4 : 11'd3) + (has_data ? len : 11'd0);
  wire        bad_hdr  = fmt[2] || dw0[15] || (has_data && (len > 11'(MAX_PAY_DW))) || in_eop;
  wire [1:0]  beat_dws = (in_eop && in_ehalf) ? 2'd1 : 2'd2;

  wire at_start = (st == S_IDLE) || ((st == S_STRAY) && in_sop);
  wire start_ok = at_start && in_sop && !bad_hdr;
  wire storing  = (st == S_STORE) || start_ok;

  assign in_ready = !storing || space;
  wire   take     = in_valid && in_ready;

  wire [10:0] cnt_now = dw_cnt + {9'd0, beat_dws};

  always_ff @(posedge clk) begin
    if (take && storing) mem[wp[AW-1:0]] <= {in_ehalf, in_eop, in_sop, in_data};
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st        <= S_IDLE;
      wp        <= '0;
      cp        <= '0;
      dw_cnt    <= 11'd0;
      dw_exp    <= 11'd0;
      malformed <= 1'b0;
      discarded <= 1'b0;
    end else begin
      malformed <= 1'b0;
      discarded <= 1'b0;
      if (take) begin
        if (at_start) begin
          if (start_ok) begin
            wp     <= wp + 1'b1;
            dw_cnt <= {9'd0, beat_dws};
            dw_exp <= exp_dws;
            st     <= S_STORE;
          end else if (!in_sop) begin
            // Stray beat between TLPs; one report per run.
            if (st == S_IDLE) malformed <= 1'b1;
            st <= in_eop ? S_IDLE : S_STRAY;
          end else begin
            malformed <= 1'b1;
            st        <= in_eop ? S_IDLE : S_DROP;
          end
        end else begin
          case (st)
            S_STORE: begin
              if (in_sop || (cnt_now > dw_exp) || (in_eop && (cnt_now != dw_exp))) begin
                malformed <= 1'b1;
                wp        <= cp;
                st        <= in_eop ? S_IDLE : S_DROP;
              end else if (in_eop) begin
                if (in_bad) begin
                  discarded <= 1'b1;
                  wp        <= cp;
                end else begin
                  wp <= wp + 1'b1;
                  cp <= wp + 1'b1;
                end
                st <= S_IDLE;
              end else begin
                wp     <= wp + 1'b1;
                dw_cnt <= cnt_now;
              end
            end
            S_DROP:  if (in_eop) st <= S_IDLE;
            default: if (in_eop) st <= S_IDLE;  // S_STRAY: a stray eop
          endcase
        end
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Reader: committed TLPs only
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)                      rp <= '0;
    else if (out_valid && out_ready) rp <= rp + 1'b1;
  end

  assign out_valid = (rp != cp);
  assign {out_ehalf, out_eop, out_sop, out_data} = mem[rp[AW-1:0]];

  // DW0 fields other than fmt, TD and Length.
  /* verilator lint_off UNUSEDSIGNAL */
  wire unused_ok = ^{dw0[28:16], dw0[14:10]};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule : tl_rx_buf

`default_nettype wire
