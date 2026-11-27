`default_nettype none

// -----------------------------------------------------------------------------
// bch_enc
//
// BCH encoder of the NAND channels (step 3-3): the 13 parity bytes of a
// 516-byte message, one message byte a clock. The remainder of m(x) x^104 by
// g(x) is an LFSR stepped 8 bits a clock, bit 7 of a byte first (the bit
// order of flow/bch/bch.py). After the last message byte PARITY shows the
// first parity byte; each SHIFT moves the next one up.
// -----------------------------------------------------------------------------

module bch_enc
  import bch_pkg::*;
(
  input  wire        clk,
  input  wire        rst_n,
  input  wire        en,       // din is a message byte
  input  wire        first,    // ... the first of a codeword
  input  wire  [7:0] din,
  input  wire        shift,    // the byte on PARITY was taken
  output logic [7:0] parity
);

  logic [R-1:0] rem;

  function automatic logic [R-1:0] step(logic [R-1:0] r, logic [7:0] b);
    logic fb;
    for (int i = 7; i >= 0; i--) begin
      fb = r[R-1] ^ b[i];
      r  = {r[R-2:0], 1'b0} ^ (fb ? G : {R{1'b0}});
    end
    return r;
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)     rem <= '0;
    else if (en)    rem <= step(first ? {R{1'b0}} : rem, din);
    else if (shift) rem <= {rem[R-9:0], 8'h00};
  end

  assign parity = rem[R-1 -: 8];

endmodule : bch_enc

`default_nettype wire
