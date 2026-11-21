`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// iso_clamp
//
// Isolation cell for an output of the switchable domain PD_HOST: while iso_en
// is high, dout is CLAMP whatever din does. The cell sits on the always-on
// side of the boundary. Every instance must match a set_isolation entry in
// syn/upf/storage_soc.upf (flow/power/check_iso.py).
// -----------------------------------------------------------------------------

module iso_clamp #(
  parameter int   WIDTH = 1,
  parameter logic CLAMP = 1'b0
) (
  input  wire  [WIDTH-1:0] din,
  input  wire              iso_en,
  output logic [WIDTH-1:0] dout
);

  assign dout = iso_en ? {WIDTH{CLAMP}} : din;

endmodule : iso_clamp

`default_nettype wire
