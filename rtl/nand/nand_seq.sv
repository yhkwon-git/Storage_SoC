`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// nand_seq
//
// Bus sequencer of one NAND channel (step 3-1, docs/15_nand_channel.md), in
// clk_nand. It takes one command at a time (nand_pkg::cmd_t) and runs it on an
// 8-bit ONFI-style asynchronous interface as a list of steps:
//   CMD   a command cycle: CLE high and the byte on DQ while WE# is low for
//         tWP clocks, then WE# high for tWH clocks with both held
//   ADR   an address cycle: the same with ALE
//   DIN   LEN data cycles with program data from the clk_sys side
//   DOUT  LEN read cycles: RE# low for tRP clocks, DQ sampled at the clock
//         edge that raises RE#, then RE# high for tREH clocks
//   STAT  one read cycle into the status byte
//   WAIT  tWB, tWHR, tADL or tRR clocks
//   RB    until R/B# reads ready, counting the busy clocks, at most TIMEOUT
// The operations:
//   RESET               CMD FFh, WAIT tWB, RB
//   READ_ID             CMD 90h, ADR COL[7:0], WAIT tWHR, DOUT
//   READ                CMD 00h, ADR x5 (column, row), CMD 30h, WAIT tWB, RB,
//                       WAIT tRR, DOUT
//   PROGRAM             CMD 80h, ADR x5, WAIT tADL, DIN, CMD 10h, WAIT tWB,
//                       RB, CMD 70h, WAIT tWHR, STAT
//   ERASE               CMD 60h, ADR x3 (row), CMD D0h, WAIT tWB, RB,
//                       CMD 70h, WAIT tWHR, STAT
//   STATUS              CMD 70h, WAIT tWHR, STAT
//   CHANGE READ COLUMN  CMD 05h, ADR x2 (column), CMD E0h, WAIT tWHR, DOUT
// CE# is low from the first step to the last, and every output comes from a
// flop. The completion carries the status byte, the busy clocks and a code:
// after a program or an erase, write protected if status bit 7 is clear,
// failed if bit 0 is set; timeout if R/B# stayed busy past TIMEOUT x 256
// clocks (TIMEOUT 0: no limit). A timeout ends the command with CE# high and
// the device maybe still busy; firmware sends RESET.
//
// A data cycle starts only with a byte waiting (DIN) or room for one (DOUT),
// so the clk_sys side may fall behind without harm: WE# or RE# just stays
// high. Back-to-back data cycles take tWP + tWH (tRP + tREH) clocks; a command,
// address, wait or status step takes one clock more to start. A read byte goes
// into the receive FIFO at the clock edge that samples it.
// -----------------------------------------------------------------------------

module nand_seq (
  input  wire              clk,
  input  wire              rst_n,

  // Command, first-word fall-through
  input  wire              cmd_valid,
  input  nand_pkg::cmd_t   cmd,
  output logic             cmd_pop,

  // Program data, first-word fall-through
  input  wire              tx_valid,
  input  wire  [7:0]       tx_data,
  output logic             tx_pop,

  // Read data
  input  wire              rx_ready,
  output logic             rx_push,
  output logic [7:0]       rx_data,

  // Completion
  input  wire              cpl_ready,
  output logic             cpl_push,
  output nand_pkg::cpl_t   cpl,

  input  wire              wen_async,      // CTRL.WP clear, from clk_sys

  // Pins
  output logic             ce_n,
  output logic             cle,
  output logic             ale,
  output logic             we_n,
  output logic             re_n,
  output logic             wp_n,
  output logic [7:0]       dq_o,
  output logic             dq_oe,
  input  wire  [7:0]       dq_i,
  input  wire              rb_n            // asynchronous: 1 ready, 0 busy
);
  import nand_pkg::*;

  typedef enum logic [2:0] {K_CMD, K_ADR, K_WAIT, K_RB, K_DIN, K_DOUT, K_STAT, K_END} kind_t;
  typedef enum logic [3:0] {S_IDLE, S_STEP, S_WLO, S_WHI, S_RLO, S_RHI, S_WAIT, S_RB, S_CPL} st_t;

  cmd_t        c;
  st_t         st;
  logic [3:0]  k;          // step
  logic [12:0] n;          // data bytes left
  logic [5:0]  cnt;        // clocks left in a phase or a wait
  logic [23:0] busy;
  logic [7:0]  status;
  logic [1:0]  code;
  logic        rd_stat;    // the read cycle in flight is the status read

  // R/B# and the write enable, synchronized
  logic rb_s, wen_s;
  cdc_sync_2ff #(.WIDTH(2)) u_sync (
    .clk (clk), .rst_n (rst_n), .din_async ({rb_n, wen_async}), .dout ({rb_s, wen_s})
  );
  assign wp_n = wen_s;

  // ---------------------------------------------------------------------------
  // Steps of the operation
  // ---------------------------------------------------------------------------
  kind_t      sk;
  logic [7:0] sb;          // CMD or ADR byte
  logic [1:0] sw;          // WAIT: 0 tWB, 1 tWHR, 2 tADL, 3 tRR

  // The five address bytes of a page: column, then row.
  function automatic logic [7:0] addr5(input logic [12:0] col, input logic [23:0] row, input logic [3:0] i);
    case (i)
      4'd0:    return col[7:0];
      4'd1:    return {3'd0, col[12:8]};
      4'd2:    return row[7:0];
      4'd3:    return row[15:8];
      default: return row[23:16];
    endcase
  endfunction

  always_comb begin
    sk = K_END;
    sb = 8'h00;
    sw = 2'd0;
    case (c.op)
      OP_RESET: case (k)
        4'd0:    begin sk = K_CMD; sb = 8'hFF; end
        4'd1:    begin sk = K_WAIT; sw = 2'd0; end
        4'd2:    sk = K_RB;
        default: sk = K_END;
      endcase
      OP_ID: case (k)
        4'd0:    begin sk = K_CMD; sb = 8'h90; end
        4'd1:    begin sk = K_ADR; sb = c.col[7:0]; end
        4'd2:    begin sk = K_WAIT; sw = 2'd1; end
        4'd3:    sk = K_DOUT;
        default: sk = K_END;
      endcase
      OP_READ: case (k)
        4'd0:                         begin sk = K_CMD; sb = 8'h00; end
        4'd1, 4'd2, 4'd3, 4'd4, 4'd5: begin sk = K_ADR; sb = addr5(c.col, c.row, k - 4'd1); end
        4'd6:                         begin sk = K_CMD; sb = 8'h30; end
        4'd7:                         begin sk = K_WAIT; sw = 2'd0; end
        4'd8:                         sk = K_RB;
        4'd9:                         begin sk = K_WAIT; sw = 2'd3; end
        4'd10:                        sk = K_DOUT;
        default:                      sk = K_END;
      endcase
      OP_PROG: case (k)
        4'd0:                         begin sk = K_CMD; sb = 8'h80; end
        4'd1, 4'd2, 4'd3, 4'd4, 4'd5: begin sk = K_ADR; sb = addr5(c.col, c.row, k - 4'd1); end
        4'd6:                         begin sk = K_WAIT; sw = 2'd2; end
        4'd7:                         sk = K_DIN;
        4'd8:                         begin sk = K_CMD; sb = 8'h10; end
        4'd9:                         begin sk = K_WAIT; sw = 2'd0; end
        4'd10:                        sk = K_RB;
        4'd11:                        begin sk = K_CMD; sb = 8'h70; end
        4'd12:                        begin sk = K_WAIT; sw = 2'd1; end
        4'd13:                        sk = K_STAT;
        default:                      sk = K_END;
      endcase
      OP_ERASE: case (k)
        4'd0:             begin sk = K_CMD; sb = 8'h60; end
        4'd1, 4'd2, 4'd3: begin sk = K_ADR; sb = addr5(c.col, c.row, k + 4'd1); end
        4'd4:             begin sk = K_CMD; sb = 8'hD0; end
        4'd5:             begin sk = K_WAIT; sw = 2'd0; end
        4'd6:             sk = K_RB;
        4'd7:             begin sk = K_CMD; sb = 8'h70; end
        4'd8:             begin sk = K_WAIT; sw = 2'd1; end
        4'd9:             sk = K_STAT;
        default:          sk = K_END;
      endcase
      OP_STATUS: case (k)
        4'd0:    begin sk = K_CMD; sb = 8'h70; end
        4'd1:    begin sk = K_WAIT; sw = 2'd1; end
        4'd2:    sk = K_STAT;
        default: sk = K_END;
      endcase
      OP_RDCOL: case (k)
        4'd0:       begin sk = K_CMD; sb = 8'h05; end
        4'd1, 4'd2: begin sk = K_ADR; sb = addr5(c.col, c.row, k - 4'd1); end
        4'd3:       begin sk = K_CMD; sb = 8'hE0; end
        4'd4:       begin sk = K_WAIT; sw = 2'd1; end
        4'd5:       sk = K_DOUT;
        default:    sk = K_END;
      endcase
      default: sk = K_END;
    endcase
  end

  function automatic logic [5:0] w1(input logic [5:0] v);
    return (v == 6'd0) ? 6'd1 : v;
  endfunction

  logic [5:0] wv;
  always_comb begin
    case (sw)
      2'd0:    wv = c.twb;
      2'd1:    wv = c.twhr;
      2'd2:    wv = c.tadl;
      default: wv = c.trr;
    endcase
  end

  // Data cycles start in S_STEP, or straight from the high phase of the
  // previous one.
  wire last_ph  = (cnt == 6'd1);
  wire din_step = (st == S_STEP) && (sk == K_DIN) && (n != 13'd0) && tx_valid;
  wire din_next = (st == S_WHI) && last_ph && (sk == K_DIN) && (n != 13'd0) && tx_valid;
  wire dout_step = (st == S_STEP) && (sk == K_DOUT) && (n != 13'd0) && rx_ready;
  wire dout_next = (st == S_RHI) && last_ph && (sk == K_DOUT) && (n != 13'd0) && rx_ready;

  assign cmd_pop  = (st == S_IDLE) && cmd_valid;
  assign tx_pop   = din_step || din_next;
  assign rx_push  = (st == S_RLO) && last_ph && !rd_stat;
  assign rx_data  = dq_i;
  assign cpl_push = (st == S_CPL) && cpl_ready;
  assign cpl      = '{tag: c.tag, code: code, status: status, busy: busy};

  wire tout_hit = (c.tout != 16'd0) && (busy[23:8] >= c.tout);
  wire wr_op    = (c.op == OP_PROG) || (c.op == OP_ERASE);

  // ---------------------------------------------------------------------------
  // Sequencer
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st      <= S_IDLE;
      c       <= '0;
      k       <= 4'd0;
      n       <= 13'd0;
      cnt     <= 6'd0;
      busy    <= 24'd0;
      status  <= 8'h00;
      code    <= CODE_OK;
      rd_stat <= 1'b0;
      ce_n    <= 1'b1;
      cle     <= 1'b0;
      ale     <= 1'b0;
      we_n    <= 1'b1;
      re_n    <= 1'b1;
      dq_o    <= 8'h00;
      dq_oe   <= 1'b0;
    end else begin
      case (st)
        S_IDLE: if (cmd_valid) begin
          c      <= cmd;
          k      <= 4'd0;
          n      <= cmd.len;
          busy   <= 24'd0;
          status <= 8'h00;
          code   <= CODE_OK;
          ce_n   <= 1'b0;
          st     <= S_STEP;
        end

        S_STEP: begin
          case (sk)
            K_CMD, K_ADR: begin
              we_n  <= 1'b0;
              cle   <= (sk == K_CMD);
              ale   <= (sk == K_ADR);
              dq_o  <= sb;
              dq_oe <= 1'b1;
              cnt   <= w1({2'd0, c.twp});
              st    <= S_WLO;
            end
            K_DIN: begin
              if (n == 13'd0) begin
                k <= k + 4'd1;
              end else if (din_step) begin
                we_n  <= 1'b0;
                cle   <= 1'b0;
                ale   <= 1'b0;
                dq_o  <= tx_data;
                dq_oe <= 1'b1;
                n     <= n - 13'd1;
                cnt   <= w1({2'd0, c.twp});
                st    <= S_WLO;
              end
            end
            K_DOUT: begin
              if (n == 13'd0) begin
                k <= k + 4'd1;
              end else if (dout_step) begin
                re_n    <= 1'b0;
                cle     <= 1'b0;
                ale     <= 1'b0;
                dq_oe   <= 1'b0;
                rd_stat <= 1'b0;
                n       <= n - 13'd1;
                cnt     <= w1({2'd0, c.trp});
                st      <= S_RLO;
              end
            end
            K_STAT: begin
              re_n    <= 1'b0;
              cle     <= 1'b0;
              ale     <= 1'b0;
              dq_oe   <= 1'b0;
              rd_stat <= 1'b1;
              cnt     <= w1({2'd0, c.trp});
              st      <= S_RLO;
            end
            K_WAIT: begin
              cle   <= 1'b0;
              ale   <= 1'b0;
              dq_oe <= 1'b0;
              cnt   <= w1(wv);
              st    <= S_WAIT;
            end
            K_RB: begin
              cle   <= 1'b0;
              ale   <= 1'b0;
              dq_oe <= 1'b0;
              st    <= S_RB;
            end
            default: begin   // K_END
              ce_n  <= 1'b1;
              cle   <= 1'b0;
              ale   <= 1'b0;
              dq_oe <= 1'b0;
              if (wr_op) code <= !status[7] ? CODE_PROT : status[0] ? CODE_FAIL : CODE_OK;
              st    <= S_CPL;
            end
          endcase
        end

        S_WLO: begin
          if (last_ph) begin
            we_n <= 1'b1;
            cnt  <= w1({2'd0, c.twh});
            st   <= S_WHI;
          end else begin
            cnt <= cnt - 6'd1;
          end
        end

        S_WHI: begin
          if (din_next) begin
            we_n <= 1'b0;
            dq_o <= tx_data;
            n    <= n - 13'd1;
            cnt  <= w1({2'd0, c.twp});
            st   <= S_WLO;
          end else if (last_ph) begin
            // A data step with bytes left waits in S_STEP for the next one.
            if (sk != K_DIN || n == 13'd0) k <= k + 4'd1;
            st <= S_STEP;
          end else begin
            cnt <= cnt - 6'd1;
          end
        end

        S_RLO: begin
          if (last_ph) begin
            re_n <= 1'b1;
            if (rd_stat) status <= dq_i;
            cnt  <= w1({2'd0, c.treh});
            st   <= S_RHI;
          end else begin
            cnt <= cnt - 6'd1;
          end
        end

        S_RHI: begin
          if (dout_next) begin
            re_n <= 1'b0;
            n    <= n - 13'd1;
            cnt  <= w1({2'd0, c.trp});
            st   <= S_RLO;
          end else if (last_ph) begin
            if (sk != K_DOUT || n == 13'd0) k <= k + 4'd1;
            st <= S_STEP;
          end else begin
            cnt <= cnt - 6'd1;
          end
        end

        S_WAIT: begin
          if (last_ph) begin
            k  <= k + 4'd1;
            st <= S_STEP;
          end else begin
            cnt <= cnt - 6'd1;
          end
        end

        S_RB: begin
          if (busy != 24'hFF_FFFF) busy <= busy + 24'd1;
          if (rb_s) begin
            k  <= k + 4'd1;
            st <= S_STEP;
          end else if (tout_hit) begin
            code <= CODE_TOUT;
            ce_n <= 1'b1;
            st   <= S_CPL;
          end
        end

        default: begin   // S_CPL
          if (cpl_ready) st <= S_IDLE;
        end
      endcase
    end
  end

  // The byte count is taken from the command as it arrives (n).
  /* verilator lint_off UNUSEDSIGNAL */
  wire unused_ok = ^c.len;
  /* verilator lint_on UNUSEDSIGNAL */

endmodule : nand_seq

`default_nettype wire
