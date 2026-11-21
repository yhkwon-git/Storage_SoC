`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// apb_timer
//
// RISC-V machine timer (APB slot 3, 0x4000_3000).
//
//   0x000 MTIME_LO     RW  mtime[31:0]
//   0x004 MTIME_HI     RW  mtime[63:32]
//   0x008 MTIMECMP_LO  RW  mtimecmp[31:0]   (reset: all ones)
//   0x00C MTIMECMP_HI  RW  mtimecmp[63:32]  (reset: all ones)
//   0x010 CTRL         RW  [0] count enable (reset 1), [15:8] prescale (reset 0)
// Other offsets answer PSLVERR.
//
// With counting enabled, mtime advances by one every PRESCALE + 1 clocks.
// irq is high while mtime >= mtimecmp, the level the core's timer input
// expects; software moves mtimecmp to clear it.
// -----------------------------------------------------------------------------

module apb_timer (
  input  wire          clk,
  input  wire          rst_n,
  input  wire          psel,
  input  wire          penable,
  input  wire  [11:0]  paddr,
  input  wire          pwrite,
  input  wire  [31:0]  pwdata,
  input  wire  [3:0]   pstrb,
  output logic [31:0]  prdata,
  output logic         pready,
  output logic         pslverr,
  output logic         irq
);

  logic [63:0] mtime;
  logic [63:0] mtimecmp;
  logic        enable;
  logic [7:0]  prescale;
  logic [7:0]  pre_cnt;

  wire access = psel && penable;
  wire wr     = access && pwrite;

  assign pready = 1'b1;
  assign irq    = (mtime >= mtimecmp);

  always_comb begin
    prdata  = 32'd0;
    pslverr = 1'b0;
    case (paddr)
      12'h000: prdata = mtime[31:0];
      12'h004: prdata = mtime[63:32];
      12'h008: prdata = mtimecmp[31:0];
      12'h00C: prdata = mtimecmp[63:32];
      12'h010: prdata = {16'd0, prescale, 7'd0, enable};
      default: pslverr = 1'b1;
    endcase
  end

  function automatic logic [31:0] merge(input logic [31:0] old, input logic [31:0] nw,
                                        input logic [3:0] strb);
    logic [31:0] r;
    r = old;
    for (int i = 0; i < 4; i++) if (strb[i]) r[i*8 +: 8] = nw[i*8 +: 8];
    return r;
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mtime    <= 64'd0;
      mtimecmp <= '1;
      enable   <= 1'b1;
      prescale <= 8'd0;
      pre_cnt  <= 8'd0;
    end else begin
      if (enable) begin
        if (pre_cnt == prescale) begin
          pre_cnt <= 8'd0;
          mtime   <= mtime + 64'd1;
        end else begin
          pre_cnt <= pre_cnt + 8'd1;
        end
      end
      if (wr) begin
        case (paddr)
          12'h000: mtime[31:0]     <= merge(mtime[31:0], pwdata, pstrb);
          12'h004: mtime[63:32]    <= merge(mtime[63:32], pwdata, pstrb);
          12'h008: mtimecmp[31:0]  <= merge(mtimecmp[31:0], pwdata, pstrb);
          12'h00C: mtimecmp[63:32] <= merge(mtimecmp[63:32], pwdata, pstrb);
          12'h010: begin
            if (pstrb[0]) enable   <= pwdata[0];
            if (pstrb[1]) prescale <= pwdata[15:8];
          end
          default: ;
        endcase
      end
    end
  end

endmodule : apb_timer

`default_nettype wire
