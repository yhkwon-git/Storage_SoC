`timescale 1ns/1ps

// -----------------------------------------------------------------------------
// nand_pkg
//
// Types shared by the two halves of a NAND channel (step 3-1,
// docs/15_nand_channel.md): the command that crosses from clk_sys to the bus
// sequencer in clk_nand, with the timing it runs with, and the completion
// that comes back.
// -----------------------------------------------------------------------------

package nand_pkg;

  // Operations (CMD_GO.OP)
  localparam logic [2:0] OP_RESET  = 3'd0;   // FFh
  localparam logic [2:0] OP_ID     = 3'd1;   // 90h, one address byte, then LEN bytes
  localparam logic [2:0] OP_READ   = 3'd2;   // 00h, 5 address bytes, 30h, busy, then LEN bytes
  localparam logic [2:0] OP_PROG   = 3'd3;   // 80h, 5 address bytes, LEN bytes, 10h, busy, status
  localparam logic [2:0] OP_ERASE  = 3'd4;   // 60h, 3 row bytes, D0h, busy, status
  localparam logic [2:0] OP_STATUS = 3'd5;   // 70h, status
  localparam logic [2:0] OP_RDCOL  = 3'd6;   // 05h, 2 column bytes, E0h, then LEN bytes

  // Completion codes (CPL.CODE)
  localparam logic [1:0] CODE_OK   = 2'd0;
  localparam logic [1:0] CODE_FAIL = 2'd1;   // status bit 0 set
  localparam logic [1:0] CODE_TOUT = 2'd2;   // R/B# busy past TIMEOUT
  localparam logic [1:0] CODE_PROT = 2'd3;   // status bit 7 clear: write protected

  // A command as the sequencer runs it. The timing comes from TIMING0,
  // TIMING1 and TIMEOUT as they were when the command was dispatched.
  typedef struct packed {
    logic [2:0]  op;
    logic [7:0]  tag;
    logic [23:0] row;
    logic [12:0] col;
    logic [12:0] len;
    logic [3:0]  twp;
    logic [3:0]  twh;
    logic [3:0]  trp;
    logic [3:0]  treh;
    logic [5:0]  twb;
    logic [5:0]  twhr;
    logic [5:0]  tadl;
    logic [5:0]  trr;
    logic [15:0] tout;
  } cmd_t;

  typedef struct packed {
    logic [7:0]  tag;
    logic [1:0]  code;
    logic [7:0]  status;
    logic [23:0] busy;      // clk_nand clocks R/B# was busy (saturates)
  } cpl_t;

endpackage : nand_pkg
