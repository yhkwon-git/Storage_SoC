// apb_if
//
// APB4 bus for the UVM register tests: 16-bit address over the APB window
// (slot = paddr[15:12]), 32-bit data. The two counters are filled by the
// testbench top from the SYS block's console and exit events, so the test
// can check that a CONSOLE or EXIT write produced exactly one event.

`timescale 1ns/1ps

interface apb_if (input logic pclk, input logic presetn);
  logic        psel;
  logic        penable;
  logic        pwrite;
  logic [15:0] paddr;
  logic [31:0] pwdata;
  logic [3:0]  pstrb;
  logic [2:0]  pprot;
  logic [31:0] prdata;
  logic        pready;
  logic        pslverr;

  int          console_events;
  int          exit_events;
  logic [7:0]  last_char;
  logic [31:0] last_code;
  logic        irq_timer;
  logic        irq_external;
  logic        dma_bus_req;   // the DMA raised AWVALID or ARVALID
endinterface
