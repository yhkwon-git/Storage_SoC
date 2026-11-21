// ral_tb
//
// The four APB blocks behind one APB bus, decoded by slot like the SoC's
// bridge does (paddr[15:12]: 0 SYS, 2 INTC, 3 TIMER, 4 DMA; other slots
// answer PSLVERR), driven by the UVM register test in ral_test_pkg. The DMA's
// AXI port sees a bus that never answers: the test starts it only with a
// misaligned DESC_PTR, which ends with an error before any bus request. Its
// DONE and ERR feed INTC sources 1 and 2, as in soc_top.

`timescale 1ns/1ps

module ral_tb;
  import uvm_pkg::*;
  import ral_test_pkg::*;

  logic clk   = 1'b0;
  logic rst_n = 1'b0;
  always #10 clk = ~clk;

  apb_if apb (.pclk(clk), .presetn(rst_n));

  wire [3:0] slot = apb.paddr[15:12];

  logic [31:0] rd_sys, rd_intc, rd_tmr, rd_dma;
  logic        rdy_sys, rdy_intc, rdy_tmr, rdy_dma;
  logic        err_sys, err_intc, err_tmr, err_dma;
  logic        dma_done, dma_err;
  logic        console_valid, exit_valid;
  logic [7:0]  console_char;
  logic [31:0] exit_code;

  apb_sys u_sys (
    .clk (clk), .rst_n (rst_n),
    .psel (apb.psel && slot == 4'd0), .penable (apb.penable), .paddr (apb.paddr[11:0]),
    .pwrite (apb.pwrite), .pwdata (apb.pwdata), .pstrb (apb.pstrb),
    .prdata (rd_sys), .pready (rdy_sys), .pslverr (err_sys),
    .console_valid (console_valid), .console_char (console_char),
    .exit_valid (exit_valid), .exit_code (exit_code)
  );

  apb_intc u_intc (
    .clk (clk), .rst_n (rst_n),
    .psel (apb.psel && slot == 4'd2), .penable (apb.penable), .paddr (apb.paddr[11:0]),
    .pwrite (apb.pwrite), .pwdata (apb.pwdata), .pstrb (apb.pstrb),
    .prdata (rd_intc), .pready (rdy_intc), .pslverr (err_intc),
    .src ({29'd0, dma_err, dma_done, 1'b0}), .irq (apb.irq_external)
  );

  apb_timer u_tmr (
    .clk (clk), .rst_n (rst_n),
    .psel (apb.psel && slot == 4'd3), .penable (apb.penable), .paddr (apb.paddr[11:0]),
    .pwrite (apb.pwrite), .pwdata (apb.pwdata), .pstrb (apb.pstrb),
    .prdata (rd_tmr), .pready (rdy_tmr), .pslverr (err_tmr),
    .irq (apb.irq_timer)
  );

  // AXI outputs of the DMA, unused: the bus never answers.
  logic [1:0]  m_awid, m_arid, m_awburst, m_arburst;
  logic [31:0] m_awaddr, m_araddr;
  logic [7:0]  m_awlen, m_arlen, m_wstrb;
  logic [2:0]  m_awsize, m_arsize, m_awprot, m_arprot;
  logic [3:0]  m_awcache, m_arcache, m_awqos, m_arqos;
  logic [63:0] m_wdata;
  logic        m_awvalid, m_wlast, m_wvalid, m_bready, m_arvalid, m_rready;

  dma u_dma (
    .clk (clk), .rst_n (rst_n),
    .psel (apb.psel && slot == 4'd4), .penable (apb.penable), .paddr (apb.paddr[11:0]),
    .pwrite (apb.pwrite), .pwdata (apb.pwdata), .pstrb (apb.pstrb),
    .prdata (rd_dma), .pready (rdy_dma), .pslverr (err_dma),
    .m_awid (m_awid), .m_awaddr (m_awaddr), .m_awlen (m_awlen), .m_awsize (m_awsize),
    .m_awburst (m_awburst), .m_awprot (m_awprot), .m_awcache (m_awcache), .m_awqos (m_awqos),
    .m_awvalid (m_awvalid), .m_awready (1'b0),
    .m_wdata (m_wdata), .m_wstrb (m_wstrb), .m_wlast (m_wlast), .m_wvalid (m_wvalid),
    .m_wready (1'b0),
    .m_bid (2'd0), .m_bresp (2'd0), .m_bvalid (1'b0), .m_bready (m_bready),
    .m_arid (m_arid), .m_araddr (m_araddr), .m_arlen (m_arlen), .m_arsize (m_arsize),
    .m_arburst (m_arburst), .m_arprot (m_arprot), .m_arcache (m_arcache), .m_arqos (m_arqos),
    .m_arvalid (m_arvalid), .m_arready (1'b0),
    .m_rid (2'd0), .m_rdata (64'd0), .m_rresp (2'd0), .m_rlast (1'b0), .m_rvalid (1'b0),
    .m_rready (m_rready),
    .irq_done (dma_done), .irq_err (dma_err)
  );
  assign apb.dma_bus_req = m_awvalid || m_arvalid;

  always_comb begin
    case (slot)
      4'd0:    begin apb.prdata = rd_sys;  apb.pready = rdy_sys;  apb.pslverr = err_sys;  end
      4'd2:    begin apb.prdata = rd_intc; apb.pready = rdy_intc; apb.pslverr = err_intc; end
      4'd3:    begin apb.prdata = rd_tmr;  apb.pready = rdy_tmr;  apb.pslverr = err_tmr;  end
      4'd4:    begin apb.prdata = rd_dma;  apb.pready = rdy_dma;  apb.pslverr = err_dma;  end
      default: begin apb.prdata = 32'd0;   apb.pready = 1'b1;     apb.pslverr = 1'b1;     end
    endcase
  end

  initial begin
    apb.console_events = 0;
    apb.exit_events    = 0;
  end

  always @(posedge clk) begin
    if (console_valid) begin
      apb.console_events++;
      apb.last_char = console_char;
    end
    if (exit_valid) begin
      apb.exit_events++;
      apb.last_code = exit_code;
    end
  end

  initial begin
    uvm_config_db #(virtual apb_if)::set(null, "*", "vif", apb);
    run_test("ral_test");
  end

  initial begin
    repeat (5) @(posedge clk);
    rst_n = 1'b1;
  end
endmodule
