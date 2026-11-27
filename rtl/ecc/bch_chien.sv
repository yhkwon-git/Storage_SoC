`default_nettype none

// -----------------------------------------------------------------------------
// bch_chien
//
// Chien search for the BCH decoder (step 3-3), eight codeword bits a clock:
// over N_BYTES clocks it gives, for each byte of the codeword, the bits whose
// position makes the error locator zero (chien8 in flow/bch/bch.py). R_i
// starts at sigma_i alpha^(-i(N-1)) and is multiplied by alpha^(8i) after
// each clock; bit m of the clock (bit 7 - m of the byte) is in error when
// the sum over i of R_i alpha^(i m) is 0.
// -----------------------------------------------------------------------------

module bch_chien
  import bch_pkg::*;
(
  input  wire         clk,
  input  wire         rst_n,
  input  wire         start,          // sig: the error locator
  input  wire  [12:0] sig [T+1],
  output logic        busy,           // mask and idx are a byte's
  output logic [9:0]  idx,            // byte of the codeword, 0 .. N_BYTES - 1
  output logic [7:0]  mask,           // its bits in error, bit 7 first
  output logic        last
);

  logic [12:0] r [T+1];
  logic [12:0] v [8];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      busy <= 1'b0;
      idx  <= '0;
      for (int n = 0; n <= T; n++) r[n] <= '0;
    end else if (start && !busy) begin
      busy <= 1'b1;
      idx  <= '0;
      for (int n = 0; n <= T; n++) r[n] <= gf_mul(sig[n], CH_INIT[n]);
    end else if (busy) begin
      for (int n = 0; n <= T; n++) r[n] <= gf_mul(r[n], CH_STEP[n]);
      idx <= idx + 10'd1;
      if (idx == 10'(N_BYTES - 1)) busy <= 1'b0;
    end
  end

  always_comb begin
    for (int m = 0; m < 8; m++) begin
      v[m] = 13'd0;
      for (int n = 0; n <= T; n++) v[m] = v[m] ^ gf_mul(r[n], CH_POS[m][n]);
      mask[7 - m] = busy && (v[m] == 13'd0);
    end
  end

  assign last = busy && (idx == 10'(N_BYTES - 1));

endmodule : bch_chien

`default_nettype wire
