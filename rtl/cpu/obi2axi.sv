`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// obi2axi
//
// One Ibex memory port (request, grant, response valid) to one AXI4 master
// port on the 64-bit fabric.
//
// Each request becomes a single narrow AXI transfer: AxSIZE = 2 (32 bit),
// AxLEN = 0, the address aligned to 4 bytes. Write data is placed on the
// byte lanes of its address (WSTRB from the byte enables); read data is taken
// from the lanes of its address.
//
// Ordering. All transfers use ID 0, so the fabric returns reads in order and
// writes in order. Reads and writes are separate AXI channels with no order
// between them, so a read is not issued while a write is outstanding, nor a
// write while a read is outstanding. That keeps responses in request order
// for the core, and a load after a store to the same address sees the store.
//
// A write is granted once both its AW and its W have been accepted. Responses
// reach the core in the same clock as the R or B handshake; SLVERR and DECERR
// become an error response (an access fault in the core).
//
// MAX_OUT transfers may be outstanding (a power of two). READ_ONLY drops the
// write path for the instruction port.
// -----------------------------------------------------------------------------

module obi2axi #(
  parameter bit READ_ONLY = 1'b0,
  parameter int MAX_OUT   = 2,
  parameter int IDW       = 2
) (
  input  wire              clk,
  input  wire              rst_n,

  input  wire              req,
  output logic             gnt,
  input  wire              we,
  input  wire  [3:0]       be,
  input  wire  [31:0]      addr,
  input  wire  [31:0]      wdata,
  output logic             rvalid,
  output logic [31:0]      rdata,
  output logic             err,

  output logic [IDW-1:0]   m_awid,
  output logic [31:0]      m_awaddr,
  output logic [7:0]       m_awlen,
  output logic [2:0]       m_awsize,
  output logic [1:0]       m_awburst,
  output logic             m_awvalid,
  input  wire              m_awready,
  output logic [63:0]      m_wdata,
  output logic [7:0]       m_wstrb,
  output logic             m_wlast,
  output logic             m_wvalid,
  input  wire              m_wready,
  input  wire  [IDW-1:0]   m_bid,
  input  wire  [1:0]       m_bresp,
  input  wire              m_bvalid,
  output logic             m_bready,
  output logic [IDW-1:0]   m_arid,
  output logic [31:0]      m_araddr,
  output logic [7:0]       m_arlen,
  output logic [2:0]       m_arsize,
  output logic [1:0]       m_arburst,
  output logic             m_arvalid,
  input  wire              m_arready,
  input  wire  [IDW-1:0]   m_rid,
  input  wire  [63:0]      m_rdata,
  input  wire  [1:0]       m_rresp,
  input  wire              m_rlast,
  input  wire              m_rvalid,
  output logic             m_rready
);

  // Outstanding transfers in order: {is_write, upper lane}.
  logic       q_full, q_empty;
  logic [1:0] q_head;
  logic       q_push, q_pop;
  wire        head_write = q_head[1];
  wire        head_lane  = q_head[0];

  fifo_sync #(.WIDTH(2), .DEPTH(MAX_OUT)) u_order (
    .clk   (clk),
    .rst_n (rst_n),
    .push  (q_push),
    .din   ({we && !READ_ONLY, addr[2]}),
    .full  (q_full),
    .pop   (q_pop),
    .dout  (q_head),
    .empty (q_empty)
  );

  wire can_read  = !q_full && (q_empty || !head_write);
  wire can_write = !q_full && (q_empty || head_write);

  // Read requests.
  assign m_arid    = '0;
  assign m_araddr  = {addr[31:2], 2'b00};
  assign m_arlen   = 8'd0;
  assign m_arsize  = 3'd2;
  assign m_arburst = 2'b01;
  assign m_arvalid = req && (!we || READ_ONLY) && can_read;
  wire   rd_gnt    = m_arvalid && m_arready;

  // Write requests: AW and W may be accepted in different clocks.
  logic aw_done, w_done;
  wire  wr_req    = req && we && !READ_ONLY && can_write;
  assign m_awid    = '0;
  assign m_awaddr  = {addr[31:2], 2'b00};
  assign m_awlen   = 8'd0;
  assign m_awsize  = 3'd2;
  assign m_awburst = 2'b01;
  assign m_awvalid = wr_req && !aw_done;
  assign m_wdata   = {wdata, wdata};
  assign m_wstrb   = addr[2] ? {be, 4'b0000} : {4'b0000, be};
  assign m_wlast   = 1'b1;
  assign m_wvalid  = wr_req && !w_done;
  wire   aw_ok     = aw_done || (m_awvalid && m_awready);
  wire   w_ok      = w_done || (m_wvalid && m_wready);
  wire   wr_gnt    = wr_req && aw_ok && w_ok;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      aw_done <= 1'b0;
      w_done  <= 1'b0;
    end else if (wr_gnt) begin
      aw_done <= 1'b0;
      w_done  <= 1'b0;
    end else begin
      if (m_awvalid && m_awready) aw_done <= 1'b1;
      if (m_wvalid && m_wready)   w_done  <= 1'b1;
    end
  end

  assign gnt    = rd_gnt || wr_gnt;
  assign q_push = gnt;

  // Responses, taken only for the transfer at the head of the order.
  assign m_rready = !q_empty && !head_write;
  assign m_bready = !q_empty && head_write;
  wire   r_hs     = m_rvalid && m_rready;
  wire   b_hs     = m_bvalid && m_bready;
  assign q_pop    = r_hs || b_hs;

  assign rvalid = r_hs || b_hs;
  assign rdata  = head_lane ? m_rdata[63:32] : m_rdata[31:0];
  assign err    = r_hs ? m_rresp[1] : m_bresp[1];

  // One ID, one beat: the response IDs and RLAST carry nothing new. The two
  // low address bits are covered by the byte enables.
  /* verilator lint_off UNUSEDSIGNAL */
  wire unused_ok = ^{m_rid, m_bid, m_rlast, m_rresp[0], m_bresp[0], addr[1:0]};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule : obi2axi

`default_nettype wire
