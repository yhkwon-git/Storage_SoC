// axi4_checker
//
// Protocol assertions for one AXI4 port of this SoC (docs/01_soc_architecture.md,
// section 5):
//   * VALID and its payload stay unchanged from VALID until the handshake, on
//     all five channels
//   * AW and AR: INCR bursts of 64-bit beats, at most 16 beats, address aligned
//     to 8 bytes, and the burst does not cross a 4 KB boundary
// Cover points count stalls and back-to-back transfers.
// Needs --assert under Verilator.

`timescale 1ns/1ps

module axi4_checker #(
  parameter string KIND = "M",   // M: crossbar port toward a master, S: toward a slave
  parameter int    IDX  = 0
) (
  axi4_if a
);

  string NAME;
  initial NAME = $sformatf("%s%0d", KIND, IDX);

  // Bytes from the start address to the end of the burst, 13 bits wide so
  // that 4096 itself can be represented.
  wire [12:0] aw_end = {1'b0, a.awaddr[11:0]} + {2'b00, ({3'b000, a.awlen} + 11'd1) << 3};
  wire [12:0] ar_end = {1'b0, a.araddr[11:0]} + {2'b00, ({3'b000, a.arlen} + 11'd1) << 3};

  a_aw_hold: assert property (@(posedge a.clk) disable iff (!a.rst_n)
    (a.awvalid && !a.awready) |=> (a.awvalid && $stable({a.awid, a.awaddr, a.awlen, a.awsize,
                                   a.awburst, a.awprot, a.awcache, a.awqos})))
    else $error("%s: AW dropped or changed before its handshake", NAME);

  a_w_hold: assert property (@(posedge a.clk) disable iff (!a.rst_n)
    (a.wvalid && !a.wready) |=> (a.wvalid && $stable({a.wdata, a.wstrb, a.wlast})))
    else $error("%s: W dropped or changed before its handshake", NAME);

  a_b_hold: assert property (@(posedge a.clk) disable iff (!a.rst_n)
    (a.bvalid && !a.bready) |=> (a.bvalid && $stable({a.bid, a.bresp})))
    else $error("%s: B dropped or changed before its handshake", NAME);

  a_ar_hold: assert property (@(posedge a.clk) disable iff (!a.rst_n)
    (a.arvalid && !a.arready) |=> (a.arvalid && $stable({a.arid, a.araddr, a.arlen, a.arsize,
                                   a.arburst, a.arprot, a.arcache, a.arqos})))
    else $error("%s: AR dropped or changed before its handshake", NAME);

  a_r_hold: assert property (@(posedge a.clk) disable iff (!a.rst_n)
    (a.rvalid && !a.rready) |=> (a.rvalid && $stable({a.rid, a.rdata, a.rresp, a.rlast})))
    else $error("%s: R dropped or changed before its handshake", NAME);

  a_aw_burst: assert property (@(posedge a.clk) disable iff (!a.rst_n)
    a.awvalid |-> (a.awburst == 2'b01 && a.awsize == 3'd3 && a.awlen <= 8'd15 &&
                   a.awaddr[2:0] == 3'b000 && aw_end <= 13'h1000))
    else $error("%s: AW burst outside the SoC rules (addr %h len %0d)", NAME, a.awaddr, a.awlen);

  a_ar_burst: assert property (@(posedge a.clk) disable iff (!a.rst_n)
    a.arvalid |-> (a.arburst == 2'b01 && a.arsize == 3'd3 && a.arlen <= 8'd15 &&
                   a.araddr[2:0] == 3'b000 && ar_end <= 13'h1000))
    else $error("%s: AR burst outside the SoC rules (addr %h len %0d)", NAME, a.araddr, a.arlen);

  c_aw_stall: cover property (@(posedge a.clk) disable iff (!a.rst_n) a.awvalid && !a.awready);
  c_w_b2b:    cover property (@(posedge a.clk) disable iff (!a.rst_n)
                              (a.wvalid && a.wready) [*4]);
  c_r_stall:  cover property (@(posedge a.clk) disable iff (!a.rst_n) a.rvalid && !a.rready);
  c_r_b2b:    cover property (@(posedge a.clk) disable iff (!a.rst_n)
                              (a.rvalid && a.rready) [*4]);

endmodule
