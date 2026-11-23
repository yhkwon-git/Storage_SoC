`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// tl_cfg
//
// Type 0 configuration space of the endpoint (docs/10_transaction_layer.md,
// section 4): the header, a PCI Express capability at 0x40 and an MSI-X
// capability at 0x80. 256 bytes; the extended space reads 0 (no extended
// capabilities) and ignores writes. Register DW n is at byte 4n.
//
//   0x10/0x14  BAR0/1  64-bit memory, not prefetchable, 16 KiB (BAR0_LOG2)
//   0x18/0x1C  BAR2/3  64-bit memory, prefetchable, 32 KiB (BAR2_LOG2)
//   0x48       Device Control: MPS (128 or 256 bytes supported), MRRS
//   0x68       Device Control 2: completion timeout disable
//   0x80       MSI-X: 8 vectors, table at BAR0 + 0x2000, PBA at BAR0 + 0x3000
//
// Status bits are set by the transaction layer (the ev_* inputs) and
// cleared by writing 1, as the specification draws them. One access per
// clock; rdata is combinational from idx. The ID used in requests and
// completions is captured from every configuration write (bus and device;
// function 0).
//
// Vendor and device IDs are parameters with placeholder defaults, not IDs
// assigned to anyone.
// -----------------------------------------------------------------------------

module tl_cfg #(
  parameter logic [15:0] VENDOR_ID = 16'h0000,
  parameter logic [15:0] DEVICE_ID = 16'h0001,
  parameter int          BAR0_LOG2 = 14,
  parameter int          BAR2_LOG2 = 15,
  parameter int          N_VEC     = 8
) (
  input  wire           clk,
  input  wire           rst_n,

  // Access from the dispatcher (CfgRd0 / CfgWr0 to function 0)
  input  wire           acc,
  input  wire           wr,
  input  wire  [9:0]    idx,          // {extended register, register}
  input  wire  [3:0]    be,
  input  wire  [31:0]   wdata,
  input  wire  [15:0]   wr_id,        // bus and device of the write (DW2[31:16])
  output logic [31:0]   rdata,

  // Settings
  output logic          mse,
  output logic          bme,
  output logic [63:0]   bar0,         // base, low BAR0_LOG2 bits zero
  output logic [63:0]   bar2,
  output logic          mps256,       // Max_Payload_Size 256 bytes (else 128)
  output logic [2:0]    mrrs,         // Max_Read_Request_Size code: 128 << mrrs
  output logic          msix_en,
  output logic          msix_fmask,
  output logic          cto_dis,      // completion timeout disabled
  output logic [15:0]   my_id,

  // Events (single-clock pulses)
  input  wire           ev_sig_ta,    // sent a Completer Abort completion
  input  wire           ev_rcv_ta,    // received a Completer Abort completion
  input  wire           ev_rcv_ma,    // received an Unsupported Request completion
  input  wire           ev_par,       // received a poisoned TLP
  input  wire           ev_ur,        // received an unsupported request
  input  wire           ev_nonfatal,  // non-fatal error detected
  input  wire           ev_fatal,     // fatal error detected (malformed TLP)
  input  wire           tx_pending    // the bus master has requests outstanding
);

  localparam logic [10:0] TBL_SIZE = 11'(N_VEC - 1);

  // RW state
  logic        c_mse, c_bme, c_per, c_serr, c_intd;
  logic [7:0]  c_cls, c_intl;
  logic        s_mdpe, s_sta, s_rta, s_rma, s_sse, s_dpe;
  logic [31:BAR0_LOG2] b0_lo;
  logic [31:0] b0_hi;
  logic [31:BAR2_LOG2] b2_lo;
  logic [31:0] b2_hi;
  logic [3:0]  d_rep;        // error reporting enables
  logic        d_ro, d_ns;
  logic [2:0]  d_mps, d_mrrs;
  logic        ds_ced, ds_nfed, ds_fed, ds_urd;
  logic [1:0]  l_aspm;
  logic        l_rcb, l_ccc, l_es;
  logic [3:0]  d2_ctv;
  logic        d2_ctd;
  logic [3:0]  l2_tls;
  logic        x_fmask, x_en;
  logic [15:0] id_q;

  assign mse        = c_mse;
  assign bme        = c_bme;
  assign bar0       = {b0_hi, b0_lo, {BAR0_LOG2{1'b0}}};
  assign bar2       = {b2_hi, b2_lo, {BAR2_LOG2{1'b0}}};
  assign mps256     = (d_mps != 3'd0);
  assign mrrs       = (d_mrrs > 3'd5) ? 3'd5 : d_mrrs;
  assign msix_en    = x_en;
  assign msix_fmask = x_fmask;
  assign cto_dis    = d2_ctd;
  assign my_id      = id_q;

  // ---------------------------------------------------------------------------
  // Read
  // ---------------------------------------------------------------------------
  always_comb begin
    rdata = 32'd0;
    case (idx)
      10'd0:  rdata = {DEVICE_ID, VENDOR_ID};
      10'd1:  rdata = {s_dpe, s_sse, s_rma, s_rta, s_sta, 2'b00, s_mdpe, 3'b000, 1'b1, 4'b0000,
                       5'b00000, c_intd, 1'b0, c_serr, 1'b0, c_per, 3'b000, c_bme, c_mse, 1'b0};
      10'd2:  rdata = 32'h0108_0201;            // class 01:08:02 (NVM Express), revision 1
      10'd3:  rdata = {8'h00, 8'h00, 8'h00, c_cls};
      10'd4:  rdata = {b0_lo, {(BAR0_LOG2-4){1'b0}}, 4'b0100};
      10'd5:  rdata = b0_hi;
      10'd6:  rdata = {b2_lo, {(BAR2_LOG2-4){1'b0}}, 4'b1100};
      10'd7:  rdata = b2_hi;
      10'd11: rdata = {DEVICE_ID, VENDOR_ID};   // subsystem IDs
      10'd13: rdata = 32'h0000_0040;            // capabilities pointer
      10'd15: rdata = {16'h0000, 8'h00, c_intl}; // no INTx pin
      // PCI Express capability, version 2, endpoint
      10'd16: rdata = {16'h0002, 8'h80, 8'h10};
      10'd17: rdata = 32'h0000_8FC1;            // MPSS 256 B, RBER, L0s/L1 latency no limit
      10'd18: rdata = {10'd0, tx_pending, 1'b0, ds_urd, ds_fed, ds_nfed, ds_ced,
                       1'b0, d_mrrs, d_ns, 3'b000, d_mps, d_ro, d_rep};
      10'd19: rdata = 32'h0001_0821;            // 2.5 GT/s, x2, ASPM L1, L1 exit 2-4 us
      10'd20: rdata = {16'h1021, 8'h00, l_es, l_ccc, 2'b00, l_rcb, 1'b0, l_aspm};
      10'd25: rdata = 32'h0000_0011;            // completion timeout range A, disable supported
      10'd26: rdata = {16'h0000, 11'd0, d2_ctd, d2_ctv};
      10'd27: rdata = 32'h0000_0002;            // supported speeds: 2.5 GT/s
      10'd28: rdata = {16'h0000, 12'd0, l2_tls};
      // MSI-X
      10'd32: rdata = {x_en, x_fmask, 3'b000, TBL_SIZE, 8'h00, 8'h11};
      10'd33: rdata = 32'h0000_2000;            // table: BAR0 + 0x2000
      10'd34: rdata = 32'h0000_3000;            // PBA:   BAR0 + 0x3000
      default: rdata = 32'd0;
    endcase
  end

  // ---------------------------------------------------------------------------
  // Write
  // ---------------------------------------------------------------------------
  wire        w    = acc && wr;
  wire [31:0] m    = {{8{be[3]}}, {8{be[2]}}, {8{be[1]}}, {8{be[0]}}};
  wire [31:0] wd   = wdata & m;    // bits written
  wire [31:0] w1c  = wdata & m;    // write-1-to-clear bits

  // New value of a field under the byte enables.
  function automatic logic [31:0] upd(input logic [31:0] old, input logic [31:0] nw,
                                      input logic [31:0] msk);
    return (old & ~msk) | (nw & msk);
  endfunction

  logic [31:0] b0_lo_full, b2_lo_full;
  assign b0_lo_full = upd({b0_lo, {BAR0_LOG2{1'b0}}}, wdata, m);
  assign b2_lo_full = upd({b2_lo, {BAR2_LOG2{1'b0}}}, wdata, m);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      c_mse <= 1'b0; c_bme <= 1'b0; c_per <= 1'b0; c_serr <= 1'b0; c_intd <= 1'b0;
      c_cls <= 8'd0; c_intl <= 8'd0;
      s_mdpe <= 1'b0; s_sta <= 1'b0; s_rta <= 1'b0; s_rma <= 1'b0; s_sse <= 1'b0; s_dpe <= 1'b0;
      b0_lo <= '0; b0_hi <= 32'd0; b2_lo <= '0; b2_hi <= 32'd0;
      d_rep <= 4'd0; d_ro <= 1'b1; d_ns <= 1'b1; d_mps <= 3'd0; d_mrrs <= 3'd2;
      ds_ced <= 1'b0; ds_nfed <= 1'b0; ds_fed <= 1'b0; ds_urd <= 1'b0;
      l_aspm <= 2'd0; l_rcb <= 1'b0; l_ccc <= 1'b0; l_es <= 1'b0;
      d2_ctv <= 4'd0; d2_ctd <= 1'b0; l2_tls <= 4'd1;
      x_fmask <= 1'b0; x_en <= 1'b0;
      id_q <= 16'd0;
    end else begin
      if (w) id_q <= {wr_id[15:3], 3'b000};
      if (w) begin
        case (idx)
          10'd1: begin
            if (be[0]) begin c_mse <= wdata[1]; c_bme <= wdata[2]; c_per <= wdata[6]; end
            if (be[1]) begin c_serr <= wdata[8]; c_intd <= wdata[10]; end
          end
          10'd3:  if (be[0]) c_cls <= wdata[7:0];
          10'd4:  b0_lo <= b0_lo_full[31:BAR0_LOG2];
          10'd5:  b0_hi <= upd(b0_hi, wdata, m);
          10'd6:  b2_lo <= b2_lo_full[31:BAR2_LOG2];
          10'd7:  b2_hi <= upd(b2_hi, wdata, m);
          10'd15: if (be[0]) c_intl <= wdata[7:0];
          10'd18: begin
            if (be[0]) begin d_rep <= wdata[3:0]; d_ro <= wdata[4]; d_mps <= {2'b00, wdata[5]}; end
            if (be[1]) begin d_ns <= wdata[11]; d_mrrs <= wdata[14:12]; end
          end
          10'd20: if (be[0]) begin
            l_aspm <= wdata[1:0]; l_rcb <= wdata[3]; l_ccc <= wdata[6]; l_es <= wdata[7];
          end
          10'd26: if (be[0]) begin d2_ctv <= wdata[3:0]; d2_ctd <= wdata[4]; end
          10'd28: if (be[0]) l2_tls <= wdata[3:0];
          10'd32: if (be[3]) begin x_fmask <= wdata[30]; x_en <= wdata[31]; end
          default: ;
        endcase
      end

      // Status: set by events, cleared by writing 1. An event in the same
      // clock as the clear wins.
      s_sta   <= ev_sig_ta   || (s_sta   && !(w && idx == 10'd1 && w1c[27]));
      s_rta   <= ev_rcv_ta   || (s_rta   && !(w && idx == 10'd1 && w1c[28]));
      s_rma   <= ev_rcv_ma   || (s_rma   && !(w && idx == 10'd1 && w1c[29]));
      s_dpe   <= ev_par      || (s_dpe   && !(w && idx == 10'd1 && w1c[31]));
      s_mdpe  <= (ev_par && c_per) || (s_mdpe && !(w && idx == 10'd1 && w1c[24]));
      s_sse   <= (ev_fatal && c_serr) || (s_sse && !(w && idx == 10'd1 && w1c[30]));
      ds_urd  <= ev_ur       || (ds_urd  && !(w && idx == 10'd18 && w1c[19]));
      ds_nfed <= ev_nonfatal || (ds_nfed && !(w && idx == 10'd18 && w1c[17]));
      ds_fed  <= ev_fatal    || (ds_fed  && !(w && idx == 10'd18 && w1c[18]));
      ds_ced  <= ds_ced && !(w && idx == 10'd18 && w1c[16]);
    end
  end

  // Bits of the write data that no register uses.
  /* verilator lint_off UNUSEDSIGNAL */
  wire unused_ok = ^{wd, d2_ctv, l2_tls[3:0], b0_lo_full[BAR0_LOG2-1:0], b2_lo_full[BAR2_LOG2-1:0],
                     wr_id[2:0], w1c[26:25], w1c[23:20], w1c[15:0]};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule : tl_cfg

`default_nettype wire
