// Yosys techmap: positive-enable latches (ret_reg's retention shadows) onto
// the Sky130 HD latch, which dfflibmap does not map.
module \$_DLATCH_P_ (input E, input D, output Q);
  sky130_fd_sc_hd__dlxtp_1 _TECHMAP_REPLACE_ (.GATE(E), .D(D), .Q(Q));
endmodule
