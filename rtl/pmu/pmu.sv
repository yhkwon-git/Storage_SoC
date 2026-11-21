`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// pmu
//
// Power management unit in PD_AON, clocked by clk_aon (docs/01, sections 3
// and 4; docs/07_clock_reset_power.md). Registers: pmu_regs, generated from
// rtl/csr/rdl/soc_apb.rdl, reached from APB through apb_cdc.
//
// Reset controller. por_n resets PD_AON through a synchronizer. SYS_DELAY
// clk_aon cycles later the core reset is released, one cycle after that the
// NAND reset, and then the host reset as part of PD_HOST's power-up, which
// starts by itself after power-on (AUTO_UP; it raises no DONE interrupt, as
// it is part of the reset sequence, but a failure raises ERR). CHIP_RESET (key 0x5AFE_0001)
// asserts the core, NAND and host resets again and repeats the release order;
// PD_AON's registers and PD_HOST's power state are kept.
//
// PD_HOST sequencer (one state per step; every wait has the TIMEOUT limit,
// and a timeout ends in FAIL with PD_HOST powered down and isolated):
//
//   OFF       pwr_en 0, isolation on, PLL off, host resets asserted
//   UP_PWR    pwr_en 1, wait for pwr_ack
//   UP_PLL    PLL on, wait for lock
//   UP_RST    release the PD_HOST logic reset
//   UP_RESTORE  restore pulse (only if a save happened since the last reset),
//             then one quiet cycle
//   ON        isolation off, core-side FIFO halves out of reset
//   DN_ISO    refused unless the host path is idle; isolation on, core-side
//             FIFO halves back in reset
//   DN_SAVE   save pulse
//   DN_CLK    PLL off, wait for lock to drop
//   DN_RST    assert the PD_HOST logic reset
//   DN_PWR    pwr_en 0, wait for pwr_ack to drop, then OFF
//
// Every output is a flop, so no decode glitch reaches an asynchronous reset,
// a latch enable or the power switch. pwr_ack, pll_lock, host_idle and wake
// come from other domains and are synchronized here.
// -----------------------------------------------------------------------------

module pmu #(
  parameter int SYS_DELAY = 4,
  parameter bit AUTO_UP   = 1'b1
) (
  input  wire          clk_aon,
  input  wire          por_n,
  output logic         rst_aon_n,

  // APB slave (clk_aon), behind apb_cdc
  input  wire          psel,
  input  wire          penable,
  input  wire  [11:0]  paddr,
  input  wire          pwrite,
  input  wire  [31:0]  pwdata,
  input  wire  [3:0]   pstrb,
  output logic [31:0]  prdata,
  output logic         pready,
  output logic         pslverr,

  // Reset requests, each released through a rst_sync in its own clock
  output logic         sys_rst_req_n,
  output logic         nand_rst_req_n,
  output logic         host_rst_req_n,    // PD_HOST logic (pclk)
  output logic         hostq_rst_req_n,   // core-side halves of the host FIFOs (clk_sys)

  // PD_HOST control
  output logic         pwr_en,
  input  wire          pwr_ack,
  output logic         iso_en,
  output logic         save,
  output logic         restore,
  output logic         pll_en,
  input  wire          pll_lock,
  input  wire          host_idle,
  input  wire          wake,
  output logic         host_on,
  output logic         irq
);

  localparam logic [31:0] CHIP_KEY = 32'h5AFE_0001;

  localparam logic [1:0] RES_NONE    = 2'd0;
  localparam logic [1:0] RES_DONE    = 2'd1;
  localparam logic [1:0] RES_REFUSED = 2'd2;
  localparam logic [1:0] RES_TIMEOUT = 2'd3;

  typedef enum logic [3:0] {
    P_OFF        = 4'd0,
    P_UP_PWR     = 4'd1,
    P_UP_PLL     = 4'd2,
    P_UP_RST     = 4'd3,
    P_UP_RESTORE = 4'd4,
    P_ON         = 4'd5,
    P_DN_ISO     = 4'd6,
    P_DN_SAVE    = 4'd7,
    P_DN_CLK     = 4'd8,
    P_DN_RST     = 4'd9,
    P_DN_PWR     = 4'd10,
    P_FAIL       = 4'd11
  } p_state_e;

  // ---------------------------------------------------------------------------
  // PD_AON reset and input synchronizers
  // ---------------------------------------------------------------------------
  rst_sync u_rst_aon (.clk(clk_aon), .arst_n(por_n), .rst_n(rst_aon_n));

  logic pwr_ack_s, lock_s, idle_s, wake_s;
  cdc_sync_2ff #(.WIDTH(4)) u_in_sync (
    .clk       (clk_aon),
    .rst_n     (rst_aon_n),
    .din_async ({pwr_ack, pll_lock, host_idle, wake}),
    .dout      ({pwr_ack_s, lock_s, idle_s, wake_s})
  );

  // ---------------------------------------------------------------------------
  // Registers
  // ---------------------------------------------------------------------------
  pmu_regs_pkg::pmu_regs__in_t  hwif_in;
  pmu_regs_pkg::pmu_regs__out_t hwif_out;

  pmu_regs u_regs (
    .clk           (clk_aon),
    .arst_n        (rst_aon_n),
    .s_apb_psel    (psel),
    .s_apb_penable (penable),
    .s_apb_pwrite  (pwrite),
    .s_apb_pprot   (3'b000),
    .s_apb_paddr   (paddr),
    .s_apb_pwdata  (pwdata),
    .s_apb_pstrb   (pstrb),
    .s_apb_pready  (pready),
    .s_apb_prdata  (prdata),
    .s_apb_pslverr (pslverr),
    .hwif_in       (hwif_in),
    .hwif_out      (hwif_out)
  );

  // CHIP_RESET stores the written key on the edge that ends the write, so the
  // key is compared one clock later.
  logic key_wr;
  always_ff @(posedge clk_aon or negedge rst_aon_n) begin
    if (!rst_aon_n) key_wr <= 1'b0;
    else            key_wr <= hwif_out.CHIP_RESET.key.swmod;
  end
  wire chip_rst = key_wr && (hwif_out.CHIP_RESET.key.value == CHIP_KEY);

  // ---------------------------------------------------------------------------
  // Reset controller
  // ---------------------------------------------------------------------------
  logic [7:0] rcnt;
  logic       sys_rel, nand_rel, por_flag, auto_pend;

  always_ff @(posedge clk_aon or negedge rst_aon_n) begin
    if (!rst_aon_n) begin
      rcnt      <= 8'd0;
      sys_rel   <= 1'b0;
      nand_rel  <= 1'b0;
      por_flag  <= 1'b1;
      auto_pend <= AUTO_UP;
    end else begin
      por_flag <= 1'b0;
      if (chip_rst) begin
        rcnt     <= 8'd0;
        sys_rel  <= 1'b0;
        nand_rel <= 1'b0;
      end else if (!sys_rel) begin
        if (rcnt == 8'(SYS_DELAY - 1)) sys_rel <= 1'b1;
        else                           rcnt    <= rcnt + 8'd1;
      end else if (!nand_rel) begin
        nand_rel <= 1'b1;
      end
      if (nand_rel) auto_pend <= 1'b0;
    end
  end

  // ---------------------------------------------------------------------------
  // PD_HOST sequencer
  // ---------------------------------------------------------------------------
  p_state_e    p_state, p_next;
  logic [15:0] pcnt;
  logic [1:0]  result;
  logic        woke, saved, wake_q;
  logic        auto_seq;   // the running power-up is the automatic one after reset
  logic [15:0] pwr_cycles;
  logic        ev_done, ev_err, ev_refused, ev_timeout, by_wake;

  wire [15:0] tmo       = hwif_out.TIMEOUT.cycles.value;
  wire        timed_out = (pcnt >= tmo);
  wire        wake_rise = wake_s && !wake_q;
  wire        up_req    = hwif_out.PWR_CTRL.up.value || (auto_pend && nand_rel) ||
                          (wake_rise && hwif_out.PWR_CTRL.wake_en.value);
  wire        dn_req    = hwif_out.PWR_CTRL.down.value;

  always_comb begin
    p_next     = p_state;
    ev_done    = 1'b0;
    ev_refused = 1'b0;
    ev_timeout = 1'b0;
    by_wake    = 1'b0;
    case (p_state)
      P_OFF, P_FAIL: begin
        if (up_req) begin
          p_next  = P_UP_PWR;
          by_wake = !hwif_out.PWR_CTRL.up.value && !(auto_pend && nand_rel);
        end
      end
      P_UP_PWR: begin
        if (pwr_ack_s)      p_next = P_UP_PLL;
        else if (timed_out) begin p_next = P_FAIL; ev_timeout = 1'b1; end
      end
      P_UP_PLL: begin
        if (lock_s)         p_next = P_UP_RST;
        else if (timed_out) begin p_next = P_FAIL; ev_timeout = 1'b1; end
      end
      P_UP_RST:     p_next = P_UP_RESTORE;
      P_UP_RESTORE: if (pcnt == 16'd1) begin p_next = P_ON; ev_done = 1'b1; end
      P_ON: begin
        if (dn_req) begin
          if (idle_s) p_next = P_DN_ISO;
          else        ev_refused = 1'b1;
        end
      end
      P_DN_ISO:  p_next = P_DN_SAVE;
      P_DN_SAVE: p_next = P_DN_CLK;
      P_DN_CLK: begin
        if (!lock_s)        p_next = P_DN_RST;
        else if (timed_out) begin p_next = P_FAIL; ev_timeout = 1'b1; end
      end
      P_DN_RST: p_next = P_DN_PWR;
      P_DN_PWR: begin
        if (!pwr_ack_s)     begin p_next = P_OFF; ev_done = 1'b1; end
        else if (timed_out) begin p_next = P_FAIL; ev_timeout = 1'b1; end
      end
      default: p_next = P_FAIL;
    endcase
  end

  assign ev_err = ev_refused || ev_timeout;

  // Output decode of a state, registered below.
  function automatic logic [6:0] outs(p_state_e s);
    logic pe, pl, hr, qr, iso;
    pe  = (s >= P_UP_PWR) && (s <= P_DN_RST);
    pl  = (s >= P_UP_PLL) && (s <= P_DN_SAVE);
    hr  = (s >= P_UP_RST) && (s <= P_DN_CLK);
    qr  = (s == P_ON);
    iso = (s != P_ON);
    return {pe, pl, hr, qr, iso, (s == P_DN_SAVE), (s == P_ON)};
  endfunction

  logic host_rel, q_rel;
  logic nand_rel_d;   // the host reset follows the NAND reset by one cycle
  logic [6:0] o_next;
  assign o_next = outs(p_next);

  always_ff @(posedge clk_aon or negedge rst_aon_n) begin
    if (!rst_aon_n) begin
      nand_rel_d      <= 1'b0;
      auto_seq        <= 1'b0;
      p_state         <= P_OFF;
      pcnt            <= 16'd0;
      result          <= RES_NONE;
      woke            <= 1'b0;
      saved           <= 1'b0;
      wake_q          <= 1'b0;
      pwr_cycles      <= 16'd0;
      {pwr_en, pll_en, host_rel, q_rel, iso_en, save, host_on} <= 7'b0000100;
      restore         <= 1'b0;
      sys_rst_req_n   <= 1'b0;
      nand_rst_req_n  <= 1'b0;
      host_rst_req_n  <= 1'b0;
      hostq_rst_req_n <= 1'b0;
      irq             <= 1'b0;
    end else begin
      wake_q  <= wake_s;
      p_state <= p_next;
      pcnt    <= (p_next != p_state) ? 16'd0 : ((pcnt == 16'hFFFF) ? pcnt : pcnt + 16'd1);
      if (p_state == P_OFF && p_next == P_UP_PWR) woke <= by_wake;
      if (p_state == P_FAIL && p_next == P_UP_PWR) woke <= by_wake;
      if ((p_state == P_OFF || p_state == P_FAIL) && p_next == P_UP_PWR)
        auto_seq <= auto_pend && nand_rel && !hwif_out.PWR_CTRL.up.value;
      else if (ev_done || ev_timeout)
        auto_seq <= 1'b0;
      if (ev_done)    result <= RES_DONE;
      if (ev_refused) result <= RES_REFUSED;
      if (ev_timeout) result <= RES_TIMEOUT;
      if (p_next == P_DN_SAVE) saved <= 1'b1;
      if (chip_rst)            saved <= 1'b0;
      if (ev_done && p_state == P_DN_PWR) pwr_cycles <= pwr_cycles + 16'd1;

      {pwr_en, pll_en, host_rel, q_rel, iso_en, save, host_on} <= o_next;
      restore <= (p_next == P_UP_RESTORE) && (p_state != P_UP_RESTORE) && saved && !chip_rst;

      nand_rel_d      <= nand_rel && !chip_rst;
      sys_rst_req_n   <= sys_rel && !chip_rst;
      nand_rst_req_n  <= nand_rel && !chip_rst;
      host_rst_req_n  <= nand_rel_d && !chip_rst && o_next[4];
      hostq_rst_req_n <= sys_rel && !chip_rst && o_next[3];
      irq             <= hwif_out.PWR_IRQ.done.value || hwif_out.PWR_IRQ.err.value;
    end
  end

  // ---------------------------------------------------------------------------
  // Register inputs
  // ---------------------------------------------------------------------------
  always_comb begin
    hwif_in.PWR_STATUS.state.next  = p_state;
    hwif_in.PWR_STATUS.on.next     = host_on;
    hwif_in.PWR_STATUS.result.next = result;
    hwif_in.PWR_STATUS.woke.next   = woke;
    // The automatic power-up after reset is part of the reset sequence and
    // raises no DONE interrupt (firmware reads PWR_STATUS); its failure does
    // raise ERR.
    hwif_in.PWR_IRQ.done.hwset     = ev_done && !auto_seq;
    hwif_in.PWR_IRQ.err.hwset      = ev_err;
    hwif_in.RST_CAUSE.por.hwset    = por_flag;
    hwif_in.RST_CAUSE.chip.hwset   = chip_rst;
    hwif_in.PWR_CYCLES.count.next  = pwr_cycles;
  end

  /* verilator lint_off UNUSEDSIGNAL */
  wire unused_ok = ^{host_rel, q_rel};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule : pmu

`default_nettype wire
