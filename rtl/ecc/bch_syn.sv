`default_nettype none

// -----------------------------------------------------------------------------
// bch_syn
//
// Syndromes of a received BCH codeword (step 3-3), one byte a clock: the odd
// syndromes S_1, S_3, ..., S_15, each the received polynomial at alpha^j by
// Horner's rule, 8 bits a clock with bit 7 first. The even ones follow by
// squaring (bch_bm). S holds the codeword's syndromes from the clock after
// its last byte until the first byte of the next.
// -----------------------------------------------------------------------------

module bch_syn
  import bch_pkg::*;
(
  input  wire         clk,
  input  wire         rst_n,
  input  wire         en,        // din is a codeword byte
  input  wire         first,     // ... the first of a codeword
  input  wire  [7:0]  din,
  output logic [12:0] s [T]      // S_(2j+1)
);

  function automatic logic [12:0] step(logic [12:0] v, logic [12:0] a, logic [7:0] b);
    for (int i = 7; i >= 0; i--) v = gf_mul(v, a) ^ {12'd0, b[i]};
    return v;
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int j = 0; j < T; j++) s[j] <= '0;
    end else if (en) begin
      for (int j = 0; j < T; j++) s[j] <= step(first ? 13'd0 : s[j], SYN_A[j], din);
    end
  end

endmodule : bch_syn

`default_nettype wire
