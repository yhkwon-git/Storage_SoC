`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// soc_pwr
//
// Clocks, resets and power for soc_top (docs/07_clock_reset_power.md): the PMU
// in PD_AON behind its APB crossing, the core and NAND reset synchronizers,
// the PHY PLL model, the PD_HOST boundary and the core side of the host
// interface (host_if: HOST registers, transaction layer, NVMe controller,
// FIFOs). soc_top and
// the power testbench (dv/tb/tb_power.sv) both use this module, so they see
// the same wiring.
//
//   APB slot 1  PMU   (clk_sys -> apb_cdc -> clk_aon)
//   APB slot 5  HOST  (clk_sys)
//   APB slot 8  NVME  (clk_sys)
//   AXI M3      transaction layer (clk_sys)
//   host_rx_*, host_tx_*  packed TLPs to and from the host, on pclk
//               (pclk_in while the PHY PLL runs)
// -----------------------------------------------------------------------------

module soc_pwr #(
  parameter int SYS_DELAY = 4,
  parameter bit AUTO_UP   = 1'b1
) (
  input  wire          clk_sys,
  input  wire          clk_aon,
  input  wire          clk_nand,
  input  wire          pclk_in,
  input  wire          por_n,

  output logic         rst_sys_n,
  output logic         rst_nand_n,
  output logic         sys_rst_req_n,   // for further synchronizers in clk_sys

  // APB, clk_sys: shared bus, one select per slot
  input  wire          psel_pmu,
  input  wire          psel_host,
  input  wire          psel_nvme,
  input  wire          penable,
  input  wire  [11:0]  paddr,
  input  wire          pwrite,
  input  wire  [31:0]  pwdata,
  input  wire  [3:0]   pstrb,
  output logic [31:0]  prdata_pmu,
  output logic         pready_pmu,
  output logic         pslverr_pmu,
  output logic [31:0]  prdata_host,
  output logic         pready_host,
  output logic         pslverr_host,
  output logic [31:0]  prdata_nvme,
  output logic         pready_nvme,
  output logic         pslverr_nvme,

  output logic         irq_pmu,         // clk_sys level (INTC source 10)
  output logic         irq_host_err,    // INTC source 5
  output logic         irq_host_bm,     // INTC source 12
  output logic         irq_nvme,        // INTC source 3

  output logic         host_pwr_en,
  input  wire          host_pwr_ack,
  input  wire          host_wake,

  // Host link: packed TLPs (rtl/host/tl/tl_pkg.sv)
  input  wire          host_rx_valid,
  output logic         host_rx_ready,
  input  wire  [63:0]  host_rx_data,
  input  wire          host_rx_sop,
  input  wire          host_rx_eop,
  input  wire          host_rx_ehalf,
  output logic         host_tx_valid,
  input  wire          host_tx_ready,
  output logic [63:0]  host_tx_data,
  output logic         host_tx_sop,
  output logic         host_tx_eop,
  output logic         host_tx_ehalf,

  // AXI4 master M3, 2-bit IDs
  output logic [1:0]   m_awid,
  output logic [31:0]  m_awaddr,
  output logic [7:0]   m_awlen,
  output logic [2:0]   m_awsize,
  output logic [1:0]   m_awburst,
  output logic         m_awvalid,
  input  wire          m_awready,
  output logic [63:0]  m_wdata,
  output logic [7:0]   m_wstrb,
  output logic         m_wlast,
  output logic         m_wvalid,
  input  wire          m_wready,
  input  wire  [1:0]   m_bid,
  input  wire  [1:0]   m_bresp,
  input  wire          m_bvalid,
  output logic         m_bready,
  output logic [1:0]   m_arid,
  output logic [31:0]  m_araddr,
  output logic [7:0]   m_arlen,
  output logic [2:0]   m_arsize,
  output logic [1:0]   m_arburst,
  output logic         m_arvalid,
  input  wire          m_arready,
  input  wire  [1:0]   m_rid,
  input  wire  [63:0]  m_rdata,
  input  wire  [1:0]   m_rresp,
  input  wire          m_rlast,
  input  wire          m_rvalid,
  output logic         m_rready
);

  // ---------------------------------------------------------------------------
  // PMU and its APB crossing
  // ---------------------------------------------------------------------------
  logic        rst_aon_n;
  logic        nand_rst_req_n, host_rst_req_n, hostq_rst_req_n;
  logic        iso_en, save, restore, pll_en, pll_lock, host_idle, host_on, irq_aon;
  logic        a_psel, a_penable, a_pwrite, a_pready, a_pslverr;
  logic [11:0] a_paddr;
  logic [31:0] a_pwdata, a_prdata;
  logic [3:0]  a_pstrb;

  apb_cdc #(.AW(12)) u_cdc (
    .clk_s     (clk_sys),    .rst_s_n   (rst_sys_n),
    .s_psel    (psel_pmu),   .s_penable (penable),    .s_paddr  (paddr),
    .s_pwrite  (pwrite),     .s_pwdata  (pwdata),     .s_pstrb  (pstrb),
    .s_prdata  (prdata_pmu), .s_pready  (pready_pmu), .s_pslverr(pslverr_pmu),
    .clk_d     (clk_aon),    .rst_d_n   (rst_aon_n),
    .m_psel    (a_psel),     .m_penable (a_penable),  .m_paddr  (a_paddr),
    .m_pwrite  (a_pwrite),   .m_pwdata  (a_pwdata),   .m_pstrb  (a_pstrb),
    .m_prdata  (a_prdata),   .m_pready  (a_pready),   .m_pslverr(a_pslverr)
  );

  pmu #(.SYS_DELAY(SYS_DELAY), .AUTO_UP(AUTO_UP)) u_pmu (
    .clk_aon         (clk_aon),
    .por_n           (por_n),
    .rst_aon_n       (rst_aon_n),
    .psel            (a_psel),
    .penable         (a_penable),
    .paddr           (a_paddr),
    .pwrite          (a_pwrite),
    .pwdata          (a_pwdata),
    .pstrb           (a_pstrb),
    .prdata          (a_prdata),
    .pready          (a_pready),
    .pslverr         (a_pslverr),
    .sys_rst_req_n   (sys_rst_req_n),
    .nand_rst_req_n  (nand_rst_req_n),
    .host_rst_req_n  (host_rst_req_n),
    .hostq_rst_req_n (hostq_rst_req_n),
    .pwr_en          (host_pwr_en),
    .pwr_ack         (host_pwr_ack),
    .iso_en          (iso_en),
    .save            (save),
    .restore         (restore),
    .pll_en          (pll_en),
    .pll_lock        (pll_lock),
    .host_idle       (host_idle),
    .wake            (host_wake),
    .host_on         (host_on),
    .irq             (irq_aon)
  );

  // ---------------------------------------------------------------------------
  // Core and NAND resets, PMU interrupt
  // ---------------------------------------------------------------------------
  rst_sync u_rst_sys  (.clk(clk_sys),  .arst_n(sys_rst_req_n),  .rst_n(rst_sys_n));
  rst_sync u_rst_nand (.clk(clk_nand), .arst_n(nand_rst_req_n), .rst_n(rst_nand_n));
  cdc_sync_2ff #(.WIDTH(1)) u_irq_sync (.clk(clk_sys), .rst_n(rst_sys_n), .din_async(irq_aon), .dout(irq_pmu));

  // ---------------------------------------------------------------------------
  // PHY PLL, PD_HOST, core side of the host FIFOs
  // ---------------------------------------------------------------------------
  logic        pclk;
  logic [31:0] cmd_data, rsp_data;
  logic        cmd_empty, cmd_pop, rsp_push, rsp_full, prst_n;
  logic        rxf_push, rxf_full, txf_pop, txf_empty, hold, hold_ack, fifo_ok;
  logic [66:0] rxf_data, txf_data;

  phy_pll_model u_pll (.ref_clk(pclk_in), .rst_n(por_n), .en(pll_en), .clk_out(pclk), .lock(pll_lock));

  pd_host u_pd_host (
    .pclk         (pclk),
    .pclk_in      (pclk_in),
    .pwr_ack      (host_pwr_ack),
    .rst_req_n    (host_rst_req_n),
    .iso_en       (iso_en),
    .save         (save),
    .restore      (restore),
    .cmd_data     (cmd_data),
    .cmd_empty    (cmd_empty),
    .cmd_pop      (cmd_pop),
    .rsp_data     (rsp_data),
    .rsp_push     (rsp_push),
    .rsp_full     (rsp_full),
    .rst_out_n    (prst_n),
    .rxf_push     (rxf_push),
    .rxf_data     (rxf_data),
    .rxf_full     (rxf_full),
    .txf_pop      (txf_pop),
    .txf_data     (txf_data),
    .txf_empty    (txf_empty),
    .hold         (hold),
    .fifo_ok      (fifo_ok),
    .hold_ack     (hold_ack),
    .pin_rx_valid (host_rx_valid),
    .pin_rx_ready (host_rx_ready),
    .pin_rx_data  (host_rx_data),
    .pin_rx_sop   (host_rx_sop),
    .pin_rx_eop   (host_rx_eop),
    .pin_rx_ehalf (host_rx_ehalf),
    .pin_tx_valid (host_tx_valid),
    .pin_tx_ready (host_tx_ready),
    .pin_tx_data  (host_tx_data),
    .pin_tx_sop   (host_tx_sop),
    .pin_tx_eop   (host_tx_eop),
    .pin_tx_ehalf (host_tx_ehalf)
  );

  host_if u_host_if (
    .clk             (clk_sys),
    .rst_n           (rst_sys_n),
    .hostq_rst_req_n (hostq_rst_req_n),
    .psel            (psel_host),
    .penable         (penable),
    .paddr           (paddr),
    .pwrite          (pwrite),
    .pwdata          (pwdata),
    .pstrb           (pstrb),
    .prdata          (prdata_host),
    .pready          (pready_host),
    .pslverr         (pslverr_host),
    .psel_nvme       (psel_nvme),
    .prdata_nvme     (prdata_nvme),
    .pready_nvme     (pready_nvme),
    .pslverr_nvme    (pslverr_nvme),
    .host_on         (host_on),
    .host_idle       (host_idle),
    .irq_err         (irq_host_err),
    .irq_bm          (irq_host_bm),
    .irq_nvme        (irq_nvme),
    .m_awid          (m_awid),
    .m_awaddr        (m_awaddr),
    .m_awlen         (m_awlen),
    .m_awsize        (m_awsize),
    .m_awburst       (m_awburst),
    .m_awvalid       (m_awvalid),
    .m_awready       (m_awready),
    .m_wdata         (m_wdata),
    .m_wstrb         (m_wstrb),
    .m_wlast         (m_wlast),
    .m_wvalid        (m_wvalid),
    .m_wready        (m_wready),
    .m_bid           (m_bid),
    .m_bresp         (m_bresp),
    .m_bvalid        (m_bvalid),
    .m_bready        (m_bready),
    .m_arid          (m_arid),
    .m_araddr        (m_araddr),
    .m_arlen         (m_arlen),
    .m_arsize        (m_arsize),
    .m_arburst       (m_arburst),
    .m_arvalid       (m_arvalid),
    .m_arready       (m_arready),
    .m_rid           (m_rid),
    .m_rdata         (m_rdata),
    .m_rresp         (m_rresp),
    .m_rlast         (m_rlast),
    .m_rvalid        (m_rvalid),
    .m_rready        (m_rready),
    .pclk            (pclk),
    .prst_req_n      (prst_n),
    .cmd_data        (cmd_data),
    .cmd_empty       (cmd_empty),
    .cmd_pop         (cmd_pop),
    .rsp_data        (rsp_data),
    .rsp_push        (rsp_push),
    .rsp_full        (rsp_full),
    .rxf_push        (rxf_push),
    .rxf_data        (rxf_data),
    .rxf_full        (rxf_full),
    .txf_pop         (txf_pop),
    .txf_data        (txf_data),
    .txf_empty       (txf_empty),
    .hold            (hold),
    .fifo_ok         (fifo_ok),
    .hold_ack        (hold_ack)
  );

endmodule : soc_pwr

`default_nettype wire
