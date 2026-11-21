`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// soc_pwr
//
// Clocks, resets and power for soc_top (docs/07_clock_reset_power.md): the PMU
// in PD_AON behind its APB crossing, the core and NAND reset synchronizers,
// the PHY PLL model, the PD_HOST boundary and the core side of the host FIFOs.
// soc_top and the power testbench (dv/tb/tb_power.sv) both use this module,
// so they see the same wiring.
//
//   APB slot 1  PMU   (clk_sys -> apb_cdc -> clk_aon)
//   APB slot 5  HOST  (clk_sys)
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

  output logic         irq_pmu,         // clk_sys level (INTC source 10)

  output logic         host_pwr_en,
  input  wire          host_pwr_ack,
  input  wire          host_wake
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

  phy_pll_model u_pll (.ref_clk(pclk_in), .rst_n(por_n), .en(pll_en), .clk_out(pclk), .lock(pll_lock));

  pd_host u_pd_host (
    .pclk      (pclk),
    .pclk_in   (pclk_in),
    .pwr_ack   (host_pwr_ack),
    .rst_req_n (host_rst_req_n),
    .iso_en    (iso_en),
    .save      (save),
    .restore   (restore),
    .cmd_data  (cmd_data),
    .cmd_empty (cmd_empty),
    .cmd_pop   (cmd_pop),
    .rsp_data  (rsp_data),
    .rsp_push  (rsp_push),
    .rsp_full  (rsp_full),
    .rst_out_n (prst_n)
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
    .host_on         (host_on),
    .host_idle       (host_idle),
    .pclk            (pclk),
    .prst_req_n      (prst_n),
    .cmd_data        (cmd_data),
    .cmd_empty       (cmd_empty),
    .cmd_pop         (cmd_pop),
    .rsp_data        (rsp_data),
    .rsp_push        (rsp_push),
    .rsp_full        (rsp_full)
  );

endmodule : soc_pwr

`default_nettype wire
