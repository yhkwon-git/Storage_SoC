`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// tl_msix
//
// MSI-X table and Pending Bit Array, in BAR0 at 0x2000 and 0x3000 (tl_cfg
// points the capability there). The host reads and writes them with memory
// requests that the dispatcher hands over one DW at a time.
//
//   table entry v at 0x2000 + 16v: message address low (bits 1:0 read 0),
//                                   address high, data, vector control
//                                   (bit 0 mask, set at reset)
//   PBA at 0x3000:                  pending bits of vectors 0..N_VEC-1
//
// A request for vector v, while MSI-X is enabled, sets its pending bit. The
// lowest pending vector that is not masked (function mask clear, vector mask
// clear) and may be sent (Bus Master Enable) is taken: its address and data
// are latched, its pending bit cleared, and the message goes to the bus
// master, which sends it as a one-DW memory write after the TLP it is
// sending. So a masked vector stays pending in the PBA and is sent when it
// is unmasked. Requests while MSI-X is disabled are dropped (req_drop).
// -----------------------------------------------------------------------------

module tl_msix #(
  parameter int N_VEC = 8
) (
  input  wire          clk,
  input  wire          rst_n,

  // Host access, one DW per clock
  input  wire          acc_we,
  input  wire          acc_pba,      // 0: table page, 1: PBA page
  input  wire  [9:0]   acc_dw,       // DW within the 4 KiB page
  input  wire  [3:0]   acc_be,
  input  wire  [31:0]  acc_wdata,
  output logic [31:0]  rd_dw0,       // DW acc_dw
  output logic [31:0]  rd_dw1,       // DW acc_dw + 1

  input  wire          en,
  input  wire          fmask,
  input  wire          bme,

  input  wire          req_valid,
  input  wire  [2:0]   req_vec,
  output logic         req_drop,

  output logic         msg_valid,
  input  wire          msg_ready,
  output logic [63:0]  msg_addr,
  output logic [31:0]  msg_data,

  output logic [N_VEC-1:0] pending,
  output logic         idle
);

  localparam int VW = (N_VEC > 1) ? $clog2(N_VEC) : 1;

  logic [31:0]      t_alo  [N_VEC];
  logic [31:0]      t_ahi  [N_VEC];
  logic [31:0]      t_data [N_VEC];
  logic [N_VEC-1:0] t_mask;

  function automatic logic [31:0] rd(input logic pba, input logic [9:0] dw,
                                     input logic [31:0] alo [N_VEC], input logic [31:0] ahi [N_VEC],
                                     input logic [31:0] dat [N_VEC], input logic [N_VEC-1:0] msk,
                                     input logic [N_VEC-1:0] pnd);
    logic [7:0] v;
    v = dw[9:2];
    if (pba) return (dw == 10'd0) ? 32'(pnd) : 32'd0;
    if (v >= 8'(N_VEC)) return 32'd0;
    case (dw[1:0])
      2'd0:    return alo[v[VW-1:0]];
      2'd1:    return ahi[v[VW-1:0]];
      2'd2:    return dat[v[VW-1:0]];
      default: return {31'd0, msk[v[VW-1:0]]};
    endcase
  endfunction

  assign rd_dw0 = rd(acc_pba, acc_dw,          t_alo, t_ahi, t_data, t_mask, pending);
  assign rd_dw1 = rd(acc_pba, acc_dw + 10'd1,  t_alo, t_ahi, t_data, t_mask, pending);

  wire [31:0] m  = {{8{acc_be[3]}}, {8{acc_be[2]}}, {8{acc_be[1]}}, {8{acc_be[0]}}};
  wire [7:0]    wv  = acc_dw[9:2];
  wire [VW-1:0] wvi = wv[VW-1:0];

  // Lowest pending vector that may be sent now.
  logic [N_VEC-1:0] ready_v;
  logic [2:0]       sel;
  logic             any;
  always_comb begin
    ready_v = pending & ~t_mask;
    sel     = 3'd0;
    any     = 1'b0;
    for (int i = N_VEC - 1; i >= 0; i--) begin
      if (ready_v[i]) begin
        sel = 3'(i);
        any = 1'b1;
      end
    end
  end

  wire take = any && en && !fmask && bme && (!msg_valid || msg_ready);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < N_VEC; i++) begin
        t_alo[i]  <= 32'd0;
        t_ahi[i]  <= 32'd0;
        t_data[i] <= 32'd0;
      end
      t_mask    <= '1;
      pending   <= '0;
      msg_valid <= 1'b0;
      msg_addr  <= 64'd0;
      msg_data  <= 32'd0;
      req_drop  <= 1'b0;
    end else begin
      req_drop <= req_valid && !en;
      if (acc_we && !acc_pba && (wv < 8'(N_VEC))) begin
        case (acc_dw[1:0])
          2'd0:    t_alo[wvi]  <= ((t_alo[wvi] & ~m) | (acc_wdata & m)) & 32'hFFFF_FFFC;
          2'd1:    t_ahi[wvi]  <= (t_ahi[wvi] & ~m) | (acc_wdata & m);
          2'd2:    t_data[wvi] <= (t_data[wvi] & ~m) | (acc_wdata & m);
          default: if (acc_be[0]) t_mask[wvi] <= acc_wdata[0];
        endcase
      end
      if (msg_valid && msg_ready) msg_valid <= 1'b0;
      if (take) begin
        msg_valid <= 1'b1;
        msg_addr  <= {t_ahi[sel], t_alo[sel]};
        msg_data  <= t_data[sel];
      end
      for (int i = 0; i < N_VEC; i++) begin
        if (take && (sel == 3'(i)))                     pending[i] <= 1'b0;
        else if (req_valid && en && (req_vec == 3'(i))) pending[i] <= 1'b1;
      end
    end
  end

  // Not idle while a message is out or one could be taken.
  assign idle = !msg_valid && !(any && en && !fmask && bme);

endmodule : tl_msix

`default_nettype wire
