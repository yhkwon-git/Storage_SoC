// ral_tb
//
// The APB blocks behind one APB bus, decoded by slot like the SoC's bridge
// does (paddr[15:12]: 0 SYS, 1 PMU, 2 INTC, 3 TIMER, 4 DMA, 5 HOST, 8 NVME;
// other slots answer PSLVERR), driven by the UVM register test in
// ral_test_pkg.
//
//   * PMU, HOST and NVME come with soc_pwr, as in soc_top: the PMU is reached
//     through its APB crossing into clk_aon, and soc_pwr's core reset is this
//     testbench's reset. PD_HOST does not power up by itself here (AUTO_UP 0);
//     a switch model acknowledges pwr_en 2 clk_aon cycles later.
//   * The DMA's AXI port sees a bus that never answers: the test starts it
//     only with a misaligned DESC_PTR, which ends with an error before any
//     bus request.
//   * INTC sources: 1 and 2 DMA DONE and ERR, 3 NVMe, 10 PMU, as in soc_top.

`timescale 1ns/1ps

module ral_tb;
  import uvm_pkg::*;
  import ral_test_pkg::*;

  logic clk     = 1'b0;
  logic clk_aon = 1'b0;
  logic pclk_in = 1'b0;
  logic por_n   = 1'b0;
  always #10  clk     = ~clk;
  always #500 clk_aon = ~clk_aon;
  always #8   pclk_in = ~pclk_in;

  wire rst_n;
  apb_if apb (.pclk(clk), .presetn(rst_n));

  wire [3:0] slot = apb.paddr[15:12];

  logic [31:0] rd_sys, rd_intc, rd_tmr, rd_dma, rd_pmu, rd_host, rd_nvme;
  logic        rdy_sys, rdy_intc, rdy_tmr, rdy_dma, rdy_pmu, rdy_host, rdy_nvme;
  logic        err_sys, err_intc, err_tmr, err_dma, err_pmu, err_host, err_nvme;
  logic        dma_done, dma_err, pmu_irq, nvme_irq;
  logic        console_valid, exit_valid;
  logic [7:0]  console_char;
  logic [31:0] exit_code;
  logic        soft_rst_dma, cg_cpu;

  apb_sys u_sys (
    .clk (clk), .rst_n (rst_n),
    .psel (apb.psel && slot == 4'd0), .penable (apb.penable), .paddr (apb.paddr[11:0]),
    .pwrite (apb.pwrite), .pwdata (apb.pwdata), .pstrb (apb.pstrb),
    .prdata (rd_sys), .pready (rdy_sys), .pslverr (err_sys),
    .console_valid (console_valid), .console_char (console_char),
    .exit_valid (exit_valid), .exit_code (exit_code),
    .soft_rst_dma (soft_rst_dma), .cg_cpu (cg_cpu), .cpu_sleep (1'b0)
  );

  apb_intc u_intc (
    .clk (clk), .rst_n (rst_n),
    .psel (apb.psel && slot == 4'd2), .penable (apb.penable), .paddr (apb.paddr[11:0]),
    .pwrite (apb.pwrite), .pwdata (apb.pwdata), .pstrb (apb.pstrb),
    .prdata (rd_intc), .pready (rdy_intc), .pslverr (err_intc),
    .src ({21'd0, pmu_irq, 6'd0, nvme_irq, dma_err, dma_done, 1'b0}), .irq (apb.irq_external)
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

  // PMU and HOST, with the core reset.
  logic pwr_en, pwr_ack = 1'b0;
  logic rst_nand_n, sys_rst_req_n;
  logic host_err_irq, host_bm_irq;

  soc_pwr #(.SYS_DELAY(4), .AUTO_UP(1'b0)) u_pwr (
    .clk_sys       (clk),
    .clk_aon       (clk_aon),
    .clk_nand      (clk),
    .pclk_in       (pclk_in),
    .por_n         (por_n),
    .rst_sys_n     (rst_n),
    .rst_nand_n    (rst_nand_n),
    .sys_rst_req_n (sys_rst_req_n),
    .psel_pmu      (apb.psel && slot == 4'd1),
    .psel_host     (apb.psel && slot == 4'd5),
    .psel_nvme     (apb.psel && slot == 4'd8),
    .penable       (apb.penable),
    .paddr         (apb.paddr[11:0]),
    .pwrite        (apb.pwrite),
    .pwdata        (apb.pwdata),
    .pstrb         (apb.pstrb),
    .prdata_pmu    (rd_pmu),
    .pready_pmu    (rdy_pmu),
    .pslverr_pmu   (err_pmu),
    .prdata_host   (rd_host),
    .pready_host   (rdy_host),
    .pslverr_host  (err_host),
    .prdata_nvme   (rd_nvme),
    .pready_nvme   (rdy_nvme),
    .pslverr_nvme  (err_nvme),
    // No traffic to the NVMe controller's local buffer here.
    .nb_awid (4'd0), .nb_awaddr (32'd0), .nb_awlen (8'd0), .nb_awvalid (1'b0), .nb_awready (),
    .nb_wdata (64'd0), .nb_wstrb (8'd0), .nb_wlast (1'b0), .nb_wvalid (1'b0), .nb_wready (),
    .nb_bid (), .nb_bresp (), .nb_bvalid (), .nb_bready (1'b1),
    .nb_arid (4'd0), .nb_araddr (32'd0), .nb_arlen (8'd0), .nb_arvalid (1'b0), .nb_arready (),
    .nb_rid (), .nb_rdata (), .nb_rresp (), .nb_rlast (), .nb_rvalid (), .nb_rready (1'b1),
    .irq_pmu       (pmu_irq),
    .irq_host_err  (host_err_irq),
    .irq_host_bm   (host_bm_irq),
    .irq_nvme      (nvme_irq),
    .host_pwr_en   (pwr_en),
    .host_pwr_ack  (pwr_ack),
    .host_wake     (1'b0),
    // No host link and no AXI traffic here: the register tests reach the
    // HOST and NVME blocks through APB only.
    .host_rx_valid (1'b0), .host_rx_ready (), .host_rx_data (64'd0), .host_rx_sop (1'b0),
    .host_rx_eop (1'b0), .host_rx_ehalf (1'b0),
    .host_tx_valid (), .host_tx_ready (1'b1), .host_tx_data (), .host_tx_sop (), .host_tx_eop (),
    .host_tx_ehalf (),
    .m_awid (), .m_awaddr (), .m_awlen (), .m_awsize (), .m_awburst (), .m_awvalid (),
    .m_awready (1'b1), .m_wdata (), .m_wstrb (), .m_wlast (), .m_wvalid (), .m_wready (1'b1),
    .m_bid (2'd0), .m_bresp (2'd0), .m_bvalid (1'b0), .m_bready (),
    .m_arid (), .m_araddr (), .m_arlen (), .m_arsize (), .m_arburst (), .m_arvalid (),
    .m_arready (1'b1), .m_rid (2'd0), .m_rdata (64'd0), .m_rresp (2'd0), .m_rlast (1'b0),
    .m_rvalid (1'b0), .m_rready ()
  );

  logic [1:0] sw_pipe = 2'b00;
  always @(posedge clk_aon) begin
    sw_pipe <= {sw_pipe[0], pwr_en};
    pwr_ack <= sw_pipe[1];
  end

  always_comb begin
    case (slot)
      4'd0:    begin apb.prdata = rd_sys;  apb.pready = rdy_sys;  apb.pslverr = err_sys;  end
      4'd1:    begin apb.prdata = rd_pmu;  apb.pready = rdy_pmu;  apb.pslverr = err_pmu;  end
      4'd2:    begin apb.prdata = rd_intc; apb.pready = rdy_intc; apb.pslverr = err_intc; end
      4'd3:    begin apb.prdata = rd_tmr;  apb.pready = rdy_tmr;  apb.pslverr = err_tmr;  end
      4'd4:    begin apb.prdata = rd_dma;  apb.pready = rdy_dma;  apb.pslverr = err_dma;  end
      4'd5:    begin apb.prdata = rd_host; apb.pready = rdy_host; apb.pslverr = err_host; end
      4'd8:    begin apb.prdata = rd_nvme; apb.pready = rdy_nvme; apb.pslverr = err_nvme; end
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
    #2000;
    por_n = 1'b1;
  end

  // Outputs this testbench does not look at.
  wire unused_ok = ^{soft_rst_dma, cg_cpu, rst_nand_n, sys_rst_req_n};
endmodule
