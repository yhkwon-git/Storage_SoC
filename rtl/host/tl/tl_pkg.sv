`timescale 1ns/1ps

// -----------------------------------------------------------------------------
// tl_pkg
//
// TLP formats used by the transaction layer (rtl/host/tl/, docs/10_transaction_layer.md).
//
// Header DWs hold the fields as the base specification draws them, byte 0 of
// the header in bits 31:24 of DW0. Payload DWs hold bytes little-endian, the
// byte at the lowest address in bits 7:0, the same as the AXI data bus.
//
// Two stream shapes:
//   packed    the TLP's DWs in order, two per 64-bit beat, DW n in bits
//             32*(n%2) +: 32; sop on the first beat, eop on the last, ehalf
//             when the last beat holds one DW. This is the link side: the
//             pins in step 2-1, the data link layer from step 2-6.
//   unpacked  one header beat (DW0..DW3 in bits 127:0, DW3 unused for a 3DW
//             header) and then the payload in address-aligned 64-bit beats:
//             payload DW i sits in lane (lane0 + i) % 2 of beat
//             (lane0 + i) / 2, where lane0 is address bit 2 (DW2[2] for a
//             3DW header, DW3[2] for a 4DW one; for a completion this is
//             Lower Address bit 2). dwv marks the valid lanes. Payload
//             beats then map onto AXI beats without a shift when the AXI
//             address has the same bit 2.
// -----------------------------------------------------------------------------

package tl_pkg;

  // Field helpers take whole DWs, and not every constant is used by every
  // block.
  /* verilator lint_off UNUSEDSIGNAL */
  /* verilator lint_off UNUSEDPARAM */

  // fmt[2:0]
  localparam logic [2:0] FMT_3DW    = 3'b000;
  localparam logic [2:0] FMT_4DW    = 3'b001;
  localparam logic [2:0] FMT_3DW_D  = 3'b010;
  localparam logic [2:0] FMT_4DW_D  = 3'b011;

  // type[4:0]
  localparam logic [4:0] TY_MEM     = 5'b00000;
  localparam logic [4:0] TY_MEMLK   = 5'b00001;
  localparam logic [4:0] TY_IO      = 5'b00010;
  localparam logic [4:0] TY_CFG0    = 5'b00100;
  localparam logic [4:0] TY_CFG1    = 5'b00101;
  localparam logic [4:0] TY_CPL     = 5'b01010;
  localparam logic [4:0] TY_CPLLK   = 5'b01011;

  // Completion status
  localparam logic [2:0] CS_SC      = 3'b000;
  localparam logic [2:0] CS_UR      = 3'b001;
  localparam logic [2:0] CS_CRS     = 3'b010;
  localparam logic [2:0] CS_CA      = 3'b100;

  // Fields of DW0
  function automatic logic [2:0] h_fmt(input logic [31:0] dw0);  return dw0[31:29]; endfunction
  function automatic logic [4:0] h_type(input logic [31:0] dw0); return dw0[28:24]; endfunction
  function automatic logic [2:0] h_tc(input logic [31:0] dw0);   return dw0[22:20]; endfunction
  function automatic logic       h_td(input logic [31:0] dw0);   return dw0[15];    endfunction
  function automatic logic       h_ep(input logic [31:0] dw0);   return dw0[14];    endfunction
  function automatic logic [1:0] h_attr(input logic [31:0] dw0); return dw0[13:12]; endfunction

  // Length in DWs, 1..1024 (a length field of 0 means 1024).
  function automatic logic [10:0] h_len(input logic [31:0] dw0);
    return (dw0[9:0] == 10'd0) ? 11'd1024 : {1'b0, dw0[9:0]};
  endfunction

  function automatic logic h_4dw(input logic [31:0] dw0);  return dw0[29]; endfunction
  function automatic logic h_data(input logic [31:0] dw0); return dw0[30]; endfunction

  // Payload lane of the first payload DW (see the header comment).
  function automatic logic h_lane0(input logic [127:0] h);
    return h_4dw(h[31:0]) ? h[98] : h[66];
  endfunction

  // DW0 from its fields.
  function automatic logic [31:0] mk_dw0(input logic [2:0] fmt, input logic [4:0] ty,
                                         input logic [2:0] tc, input logic [1:0] attr,
                                         input logic [10:0] len);
    return {fmt, ty, 1'b0, tc, 4'b0000, 1'b0, 1'b0, attr, 2'b00, len[9:0]};
  endfunction

  // Byte offset of the first enabled byte, and bytes dropped after the last
  // enabled one (from the old bridge, AXI_PCIe_Subsystem b64e36a). With no
  // byte enabled (a zero-length read) the offset is 0, as Lower Address
  // bits 1:0 must be.
  function automatic logic [1:0] low_off(input logic [3:0] be);
    if (be[0])      return 2'd0;
    else if (be[1]) return 2'd1;
    else if (be[2]) return 2'd2;
    else if (be[3]) return 2'd3;
    else            return 2'd0;
  endfunction

  function automatic logic [1:0] high_drop(input logic [3:0] be);
    if (be[3])      return 2'd0;
    else if (be[2]) return 2'd1;
    else if (be[1]) return 2'd2;
    else            return 2'd3;
  endfunction

  // Byte count of a memory read request (the completion's Byte Count on its
  // first completion). A zero-length read (1 DW, First BE 0) counts 1.
  function automatic logic [12:0] req_bytes(input logic [10:0] len, input logic [3:0] fbe,
                                            input logic [3:0] lbe);
    logic [2:0] ones;
    ones = {2'b0, fbe[0]} + {2'b0, fbe[1]} + {2'b0, fbe[2]} + {2'b0, fbe[3]};
    if (len == 11'd1) return (fbe == 4'd0) ? 13'd1 : {10'd0, ones};
    return {len, 2'b00} - {11'd0, low_off(fbe)} - {11'd0, high_drop(lbe)};
  endfunction

  /* verilator lint_on UNUSEDPARAM */
  /* verilator lint_on UNUSEDSIGNAL */

endpackage : tl_pkg
