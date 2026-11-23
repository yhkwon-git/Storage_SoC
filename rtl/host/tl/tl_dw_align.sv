`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// tl_dw_align
//
// Moves a packet of DWs, carried two per 64-bit beat, to a new starting lane.
// The input's DWs are in order: lane 0 before lane 1 in a beat, and dwv marks
// the valid lanes (01, 10 or 11; only the first beat may start at lane 1 and
// only the last may end at lane 0). The output carries the same DWs with the
// first one in lane out_lane0 (sampled with the packet's first beat), and
// every output beat but the last is filled up to lane 1.
//
// Used to unpack and pack TLPs (header DW count against the payload's address
// lane) and between a TLP payload's lane and an AXI address's lane.
//
// At most one DW waits in the holding register, so an output beat needs at
// most one input beat besides it. When the packet's last input beat leaves a
// DW in the holding register, one more output beat follows. Throughput is
// one beat per clock either way; the output is combinational from the input
// and the holding register.
// -----------------------------------------------------------------------------

module tl_dw_align (
  input  wire          clk,
  input  wire          rst_n,

  input  wire          in_valid,
  output logic         in_ready,
  input  wire  [63:0]  in_data,
  input  wire  [1:0]   in_dwv,
  input  wire          in_last,
  input  wire          out_lane0,

  output logic         out_valid,
  input  wire          out_ready,
  output logic [63:0]  out_data,
  output logic [1:0]   out_dwv,
  output logic         out_last
);

  logic        hv;       // a DW is held
  logic [31:0] hd;
  logic        opos;     // lane of the next output DW
  logic        sop;      // the next input beat starts a packet
  logic        tail;     // the input packet has ended; hd is its last DW

  // Input DWs in order.
  wire        n2   = (in_dwv == 2'b11);
  wire [31:0] in_a = in_dwv[0] ? in_data[31:0] : in_data[63:32];
  wire [31:0] in_b = in_data[63:32];
  wire        pos  = sop ? out_lane0 : opos;

  // DWs available this clock: held first, then input. hv implies pos = 0
  // (an output beat is always filled to lane 1 unless it is the last), so
  // need is 2 whenever hv is set and the leftover is never more than one.
  wire [31:0] l0   = hv ? hd   : in_a;
  wire [31:0] l1   = hv ? in_a : in_b;
  wire [31:0] l2   = in_b;
  wire [1:0]  cnt  = {1'b0, hv} + (n2 ? 2'd2 : 2'd1);
  wire [1:0]  need = pos ? 2'd1 : 2'd2;
  wire        full_beat = (cnt >= need);
  wire [1:0]  left = cnt - need;  // valid when full_beat

  // Output beat. (READY is computed apart from VALID so that no block reads
  // its own consumer's READY.)
  always_comb begin
    out_valid = 1'b0;
    out_data  = 64'd0;
    out_dwv   = 2'b00;
    out_last  = 1'b0;
    if (tail) begin
      out_valid = 1'b1;
      out_data  = {hd, hd};
      out_dwv   = opos ? 2'b10 : 2'b01;
      out_last  = 1'b1;
    end else if (in_valid) begin
      if (full_beat) begin
        out_valid = 1'b1;
        if (pos) begin
          out_data = {l0, 32'd0};
          out_dwv  = 2'b10;
        end else begin
          out_data = {l1, l0};
          out_dwv  = 2'b11;
        end
        out_last = in_last && (left == 2'd0);
      end else if (in_last) begin
        // One DW left in all, starting at lane 0.
        out_valid = 1'b1;
        out_data  = {32'd0, l0};
        out_dwv   = 2'b01;
        out_last  = 1'b1;
      end
    end
  end

  // An input beat is taken with its output beat, or alone into the holding
  // register when it does not fill one.
  assign in_ready = !tail && in_valid && ((full_beat || in_last) ? out_ready : 1'b1);

  // The DW left over after a full output beat.
  wire [31:0] left_dw = pos ? l1 : l2;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      hv   <= 1'b0;
      hd   <= 32'd0;
      opos <= 1'b0;
      sop  <= 1'b1;
      tail <= 1'b0;
    end else if (tail) begin
      if (out_ready) begin
        tail <= 1'b0;
        hv   <= 1'b0;
        sop  <= 1'b1;
      end
    end else if (in_valid && in_ready) begin
      if (full_beat) begin
        opos <= 1'b0;
        if (left != 2'd0) begin
          hv <= 1'b1;
          hd <= left_dw;
          if (in_last) begin
            tail <= 1'b1;
            sop  <= 1'b0;
          end else begin
            sop <= 1'b0;
          end
        end else begin
          hv  <= 1'b0;
          sop <= in_last;
        end
      end else if (in_last) begin
        hv   <= 1'b0;
        opos <= 1'b0;
        sop  <= 1'b1;
      end else begin
        hv   <= 1'b1;
        hd   <= l0;
        opos <= pos;
        sop  <= 1'b0;
      end
    end
  end

endmodule : tl_dw_align

`default_nettype wire
