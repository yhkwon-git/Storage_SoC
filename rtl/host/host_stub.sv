`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// host_stub
//
// Placeholder for PD_HOST's logic until phase 2 (PHY, link layer, packet half
// of the transaction layer). It runs on pclk and has state of both kinds the
// real blocks will have: retained registers (as the link's sequence numbers
// and credits will be) and plain ones. One command from the command FIFO
// gives one response to the response FIFO:
//
//   cmd[31:28]  response                         effect
//   0 ECHO      {SEQ, cmd[15:0]}                 SEQ + 1, LAST = cmd[15:0]
//   1 CFG       {16'h1000, cmd[15:0]}            CFG = cmd[15:0]
//   2 STATE     {CFG, LAST}
//   3 SEQ       {16'h0000, SEQ}
//   other       {16'hF000, cmd[15:0]}
//
// SEQ and CFG are retention registers (ret_reg); LAST is not, so after a
// power cycle it is back at 0 while SEQ and CFG are restored.
// -----------------------------------------------------------------------------

module host_stub (
  input  wire          pclk,
  input  wire          rst_n,
  input  wire          save,       // asynchronous latch enable (ret_reg)
  input  wire          restore,    // synchronous to pclk

  input  wire  [31:0]  cmd_data,
  input  wire          cmd_empty,
  output logic         cmd_pop,

  output logic [31:0]  rsp_data,
  output logic         rsp_push,
  input  wire          rsp_full
);

  localparam logic [3:0] OP_ECHO  = 4'd0;
  localparam logic [3:0] OP_CFG   = 4'd1;
  localparam logic [3:0] OP_STATE = 4'd2;
  localparam logic [3:0] OP_SEQ   = 4'd3;

  logic [15:0] seq, cfg, last;

  wire       go = !cmd_empty && !rsp_full && !restore;
  wire [3:0] op = cmd_data[31:28];

  ret_reg #(.WIDTH(16)) u_seq (
    .clk (pclk), .rst_n (rst_n), .save (save), .restore (restore),
    .en (go && op == OP_ECHO), .d (seq + 16'd1), .q (seq)
  );

  ret_reg #(.WIDTH(16)) u_cfg (
    .clk (pclk), .rst_n (rst_n), .save (save), .restore (restore),
    .en (go && op == OP_CFG), .d (cmd_data[15:0]), .q (cfg)
  );

  always_ff @(posedge pclk or negedge rst_n) begin
    if (!rst_n)                    last <= 16'd0;
    else if (go && op == OP_ECHO)  last <= cmd_data[15:0];
  end

  always_comb begin
    case (op)
      OP_ECHO:  rsp_data = {seq, cmd_data[15:0]};
      OP_CFG:   rsp_data = {16'h1000, cmd_data[15:0]};
      OP_STATE: rsp_data = {cfg, last};
      OP_SEQ:   rsp_data = {16'h0000, seq};
      default:  rsp_data = {16'hF000, cmd_data[15:0]};
    endcase
  end

  assign cmd_pop  = go;
  assign rsp_push = go;

  // Command bits 27:16 are reserved.
  /* verilator lint_off UNUSEDSIGNAL */
  wire unused_ok = ^cmd_data[27:16];
  /* verilator lint_on UNUSEDSIGNAL */

endmodule : host_stub

`default_nettype wire
