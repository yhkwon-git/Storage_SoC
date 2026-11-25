// Binds nand_checker (dv/sva/nand_checker.sv) into every nand_seq.

bind nand_seq nand_checker u_nand_chk (
  .clk (clk), .rst_n (rst_n), .st (st), .ce_n (ce_n), .cle (cle), .ale (ale),
  .we_n (we_n), .re_n (re_n), .dq_oe (dq_oe),
  .twp (c.twp), .twh (c.twh), .trp (c.trp), .treh (c.treh),
  .rx_push (rx_push), .rx_ready (rx_ready), .tx_pop (tx_pop), .tx_valid (tx_valid)
);
