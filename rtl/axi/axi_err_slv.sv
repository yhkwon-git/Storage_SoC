`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// axi_err_slv
//
// Default slave for one master: answers every transaction with DECERR.
// A write takes its AW, all W beats up to WLAST, then returns one B. A read
// takes its AR and returns ARLEN + 1 beats of zero data with RLAST on the
// last. One write and one read at a time.
// -----------------------------------------------------------------------------

module axi_err_slv #(
  parameter int IDW = 2,
  parameter int DW  = 64
) (
  input  wire            clk,
  input  wire            rst_n,

  input  wire [IDW-1:0]  awid,
  input  wire            awvalid,
  output wire            awready,
  input  wire            wlast,
  input  wire            wvalid,
  output wire            wready,
  output wire [IDW-1:0]  bid,
  output wire [1:0]      bresp,
  output wire            bvalid,
  input  wire            bready,

  input  wire [IDW-1:0]  arid,
  input  wire [7:0]      arlen,
  input  wire            arvalid,
  output wire            arready,
  output wire [IDW-1:0]  rid,
  output wire [DW-1:0]   rdata,
  output wire [1:0]      rresp,
  output wire            rlast,
  output wire            rvalid,
  input  wire            rready
);

  localparam logic [1:0] DECERR = 2'b11;

  typedef enum logic [1:0] {W_IDLE, W_DATA, W_RESP} wst_t;

  wst_t           wst;
  logic [IDW-1:0] wid_q;

  assign awready = (wst == W_IDLE);
  assign wready  = (wst == W_DATA);
  assign bvalid  = (wst == W_RESP);
  assign bid     = wid_q;
  assign bresp   = DECERR;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wst   <= W_IDLE;
      wid_q <= '0;
    end else begin
      case (wst)
        W_IDLE: if (awvalid) begin
          wid_q <= awid;
          wst   <= W_DATA;
        end
        W_DATA: if (wvalid && wlast) begin
          wst <= W_RESP;
        end
        W_RESP: if (bready) begin
          wst <= W_IDLE;
        end
        default: wst <= W_IDLE;
      endcase
    end
  end

  logic           r_busy;
  logic [IDW-1:0] rid_q;
  logic [7:0]     rlen_q;
  logic [7:0]     rcnt_q;

  assign arready = !r_busy;
  assign rvalid  = r_busy;
  assign rid     = rid_q;
  assign rdata   = '0;
  assign rresp   = DECERR;
  assign rlast   = (rcnt_q == rlen_q);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      r_busy <= 1'b0;
      rid_q  <= '0;
      rlen_q <= '0;
      rcnt_q <= '0;
    end else if (!r_busy) begin
      if (arvalid) begin
        r_busy <= 1'b1;
        rid_q  <= arid;
        rlen_q <= arlen;
        rcnt_q <= '0;
      end
    end else if (rready) begin
      if (rlast) begin
        r_busy <= 1'b0;
      end else begin
        rcnt_q <= rcnt_q + 1'b1;
      end
    end
  end

endmodule : axi_err_slv

`default_nettype wire
