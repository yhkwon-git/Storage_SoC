// axi4_if
//
// One AXI4 port for the testbenches: 32-bit address, 64-bit data, 4-bit IDs.
// Master-side ports of the crossbar use the low 2 ID bits and tie the upper
// two to 0; slave-side ports carry the master index in the upper two bits.

`timescale 1ns/1ps

interface axi4_if (input logic clk, input logic rst_n);
  logic [3:0]  awid;
  logic [31:0] awaddr;
  logic [7:0]  awlen;
  logic [2:0]  awsize;
  logic [1:0]  awburst;
  logic [2:0]  awprot;
  logic [3:0]  awcache;
  logic [3:0]  awqos;
  logic        awvalid;
  logic        awready;

  logic [63:0] wdata;
  logic [7:0]  wstrb;
  logic        wlast;
  logic        wvalid;
  logic        wready;

  logic [3:0]  bid;
  logic [1:0]  bresp;
  logic        bvalid;
  logic        bready;

  logic [3:0]  arid;
  logic [31:0] araddr;
  logic [7:0]  arlen;
  logic [2:0]  arsize;
  logic [1:0]  arburst;
  logic [2:0]  arprot;
  logic [3:0]  arcache;
  logic [3:0]  arqos;
  logic        arvalid;
  logic        arready;

  logic [3:0]  rid;
  logic [63:0] rdata;
  logic [1:0]  rresp;
  logic        rlast;
  logic        rvalid;
  logic        rready;
endinterface
