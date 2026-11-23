// tlp_if
//
// The two packed TLP streams (rtl/host/tl/tl_pkg.sv) between the host model
// and the device: rx_* host to device, tx_* device to host.

`timescale 1ns/1ps

interface tlp_if (input logic clk, input logic rst_n);
  logic        rx_valid;
  logic        rx_ready;
  logic [63:0] rx_data;
  logic        rx_sop;
  logic        rx_eop;
  logic        rx_ehalf;
  logic        rx_bad;

  logic        tx_valid;
  logic        tx_ready;
  logic [63:0] tx_data;
  logic        tx_sop;
  logic        tx_eop;
  logic        tx_ehalf;
endinterface
