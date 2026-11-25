`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// nand_checker
//
// Assertions on a NAND channel's bus sequencer (step 3-1,
// docs/15_nand_channel.md), bound into every nand_seq by
// dv/sva/nand_bind.sv. They count in clk_nand clocks what nand_model checks
// in ns:
//   - WE# and RE# are never low together, nor CLE and ALE high together;
//   - every WE# or RE# cycle is inside CE# low, and CE# is high while idle;
//   - DQ is driven through every write cycle and never during a read cycle;
//   - a WE# low phase lasts exactly tWP clocks and an RE# low phase exactly
//     tRP clocks of the command's timing; the high phase between two cycles
//     lasts at least tWH (tREH) clocks;
//   - a read byte is pushed only with room for it, and a program byte is
//     taken only when one is there.
// The rules across clocks are checked at each clock edge on the values before
// that edge's updates, against values kept from the clock before.
// -----------------------------------------------------------------------------

module nand_checker (
  input wire        clk,
  input wire        rst_n,
  input wire [3:0]  st,              // nand_seq state: 0 idle
  input wire        ce_n,
  input wire        cle,
  input wire        ale,
  input wire        we_n,
  input wire        re_n,
  input wire        dq_oe,
  input wire [3:0]  twp,
  input wire [3:0]  twh,
  input wire [3:0]  trp,
  input wire [3:0]  treh,
  input wire        rx_push,
  input wire        rx_ready,
  input wire        tx_pop,
  input wire        tx_valid
);

  default clocking cb @(posedge clk); endclocking
  default disable iff (!rst_n);

  a_we_re:   assert property (!(!we_n && !re_n)) else $error("[NAND-SVA] WE# and RE# low together");
  a_cle_ale: assert property (!(cle && ale))     else $error("[NAND-SVA] CLE and ALE high together");
  a_ce:      assert property ((!we_n || !re_n) |-> !ce_n) else $error("[NAND-SVA] bus cycle with CE# high");
  a_idle:    assert property ((st == 4'd0) |-> ce_n && we_n && re_n && !dq_oe)
               else $error("[NAND-SVA] bus not idle with the sequencer idle");
  a_dq_wr:   assert property (!we_n |-> dq_oe) else $error("[NAND-SVA] WE# low with DQ not driven");
  a_dq_rd:   assert property (!re_n |-> !dq_oe) else $error("[NAND-SVA] DQ driven during a read cycle");
  a_rx:      assert property (rx_push |-> rx_ready) else $error("[NAND-SVA] read byte pushed into a full FIFO");
  a_tx:      assert property (tx_pop |-> tx_valid) else $error("[NAND-SVA] program byte taken from an empty FIFO");

  function automatic int w1(input logic [3:0] v);
    return (v == 4'd0) ? 1 : int'(v);
  endfunction

  // Phase widths, in clocks
  int  we_lo, we_hi, re_lo, re_hi;
  bit  p_we_n, p_re_n, p_init;
  bit  we_cycled, re_cycled;           // a cycle ended, so a high phase is being measured

  always @(posedge clk) begin
    if (!rst_n) begin
      p_init    = 1'b0;
      we_cycled = 1'b0;
      re_cycled = 1'b0;
      we_lo = 0; we_hi = 0; re_lo = 0; re_hi = 0;
    end else begin
      if (p_init) begin
        if (!p_we_n) we_lo++;
        else         we_hi++;
        if (!p_re_n) re_lo++;
        else         re_hi++;
        // WE# rose: its low phase is complete.
        if (we_n && !p_we_n) begin
          a_twp: assert (we_lo == w1(twp))
            else $error("[NAND-SVA] WE# low %0d clocks, tWP %0d", we_lo, w1(twp));
          we_cycled = 1'b1;
          we_hi = 0;
        end
        // WE# fell after a cycle: the high phase between them is complete.
        if (!we_n && p_we_n) begin
          if (we_cycled && !ce_n)
            a_twh: assert (we_hi >= w1(twh))
              else $error("[NAND-SVA] WE# high %0d clocks, tWH %0d", we_hi, w1(twh));
          we_lo = 0;
        end
        if (re_n && !p_re_n) begin
          a_trp: assert (re_lo == w1(trp))
            else $error("[NAND-SVA] RE# low %0d clocks, tRP %0d", re_lo, w1(trp));
          re_cycled = 1'b1;
          re_hi = 0;
        end
        if (!re_n && p_re_n) begin
          if (re_cycled && !ce_n)
            a_treh: assert (re_hi >= w1(treh))
              else $error("[NAND-SVA] RE# high %0d clocks, tREH %0d", re_hi, w1(treh));
          re_lo = 0;
        end
        // A new command starts its own count.
        if (ce_n) begin
          we_cycled = 1'b0;
          re_cycled = 1'b0;
        end
      end
      p_we_n = we_n;
      p_re_n = re_n;
      p_init = 1'b1;
    end
  end

endmodule : nand_checker

`default_nettype wire
