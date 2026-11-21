// tb_power
//
// Power-aware testbench for soc_pwr: PMU, APB crossing, PD_HOST boundary,
// host FIFOs (docs/07_clock_reset_power.md). Runs on Verilator, where an
// unpowered PD_HOST drives random values, and on xsim with PA_XPROP, where it
// drives X (dv/run_power.sh, dv/run_power_x.ps1).
//
//   +test=directed   power-on reset order, host commands, refused power-down,
//                    power cycles with retention, wake pin, switch timeout,
//                    chip reset, APB crossing stress
//   +test=pll_stuck  run with +pll_stuck: the power-up after reset ends in FAIL
//
// Checked all the time:
//   * sequencing (every clk_aon cycle): isolated whenever power is not good,
//     PD_HOST logic in reset whenever power is not good, save and restore only
//     with power, clock and isolation in place, isolation released only with
//     power, lock and reset release
//   * isolation (every pclk_in and clk_sys clock): PD_HOST's outputs are 0
//     while isolated, and nothing on the core side is X
//   * the off-state model really produced garbage while PD_HOST was off
//
// Output lines start with [PWR].

`timescale 1ns/1ps

module tb_power;

  logic clk_sys  = 1'b0;
  logic clk_aon  = 1'b0;
  logic clk_nand = 1'b0;
  logic pclk_in  = 1'b0;
  logic por_n    = 1'b0;

  always #10  clk_sys = ~clk_sys;    // 50 MHz
  always #500 clk_aon = ~clk_aon;    // 1 MHz
  always #8   pclk_in = ~pclk_in;    // 62.5 MHz
  initial begin
    #3;
    forever #10 clk_nand = ~clk_nand;
  end

  logic        psel_pmu  = 1'b0;
  logic        psel_host = 1'b0;
  logic        penable   = 1'b0;
  logic        pwrite    = 1'b0;
  logic [11:0] paddr     = 12'd0;
  logic [31:0] pwdata    = 32'd0;
  logic [3:0]  pstrb     = 4'd0;
  wire  [31:0] prdata_pmu, prdata_host;
  wire         pready_pmu, pready_host, pslverr_pmu, pslverr_host;
  wire         rst_sys_n, rst_nand_n, sys_rst_req_n, irq_pmu, host_pwr_en;
  logic        host_pwr_ack = 1'b0;
  logic        host_wake    = 1'b0;

  soc_pwr #(.SYS_DELAY(4), .AUTO_UP(1'b1)) dut (
    .clk_sys       (clk_sys),
    .clk_aon       (clk_aon),
    .clk_nand      (clk_nand),
    .pclk_in       (pclk_in),
    .por_n         (por_n),
    .rst_sys_n     (rst_sys_n),
    .rst_nand_n    (rst_nand_n),
    .sys_rst_req_n (sys_rst_req_n),
    .psel_pmu      (psel_pmu),
    .psel_host     (psel_host),
    .penable       (penable),
    .paddr         (paddr),
    .pwrite        (pwrite),
    .pwdata        (pwdata),
    .pstrb         (pstrb),
    .prdata_pmu    (prdata_pmu),
    .pready_pmu    (pready_pmu),
    .pslverr_pmu   (pslverr_pmu),
    .prdata_host   (prdata_host),
    .pready_host   (pready_host),
    .pslverr_host  (pslverr_host),
    .irq_pmu       (irq_pmu),
    .host_pwr_en   (host_pwr_en),
    .host_pwr_ack  (host_pwr_ack),
    .host_wake     (host_wake)
  );

  int errors = 0;

  function automatic void err(string s);
    errors++;
    if (errors <= 20) $display("[PWR] ERROR at %0t: %s", $time, s);
  endfunction

  // A string variable, not a ?: between literals (Verilator pads the latter).
  function automatic string verdict(int e);
    string s;
    s = (e == 0) ? "ok" : "FAIL";
    return s;
  endfunction

  // ---------------------------------------------------------------------------
  // Power switch: pwr_ack follows pwr_en after sw_delay clk_aon cycles, unless
  // it is stuck
  // ---------------------------------------------------------------------------
  int unsigned sw_delay = 3;
  bit          sw_stuck = 1'b0;
  int unsigned sw_cnt   = 0;

  always @(posedge clk_aon) begin
    if (!sw_stuck && host_pwr_ack != host_pwr_en) begin
      sw_cnt = sw_cnt + 1;
      if (sw_cnt >= sw_delay) begin
        host_pwr_ack <= host_pwr_en;
        sw_cnt = 0;
      end
    end else begin
      sw_cnt = 0;
    end
  end

  // ---------------------------------------------------------------------------
  // Reset release times
  // ---------------------------------------------------------------------------
  realtime t_aon, t_sys, t_nand, t_host;
  always @(posedge dut.rst_aon_n)       t_aon  = $realtime;
  always @(posedge rst_sys_n)           t_sys  = $realtime;
  always @(posedge rst_nand_n)          t_nand = $realtime;
  always @(posedge dut.u_pd_host.rst_n) t_host = $realtime;

  // ---------------------------------------------------------------------------
  // Sequencing rules, sampled between clk_aon edges
  // ---------------------------------------------------------------------------
  int n_seq_checks = 0;
  always @(negedge clk_aon) begin
    if (dut.rst_aon_n === 1'b1) begin
      n_seq_checks++;
      if (!host_pwr_ack && !dut.iso_en)         err("power not good and isolation off");
      if (!host_pwr_ack && dut.host_rst_req_n)  err("power not good and PD_HOST reset released");
      if (dut.save && !(dut.iso_en && host_pwr_ack && dut.pll_en))
        err("save without isolation, power or clock");
      if (dut.restore && !(dut.iso_en && host_pwr_ack && dut.pll_lock && dut.host_rst_req_n))
        err("restore without isolation, power, lock or reset release");
      // A chip reset holds PD_HOST's logic in reset with isolation off: a
      // domain in reset drives idle outputs (docs/01, section 3).
      if (!dut.iso_en && !(host_pwr_ack && dut.pll_lock))
        err("isolation off without power or lock");
    end
  end

  // ---------------------------------------------------------------------------
  // Isolation and X checks
  // ---------------------------------------------------------------------------
  int n_iso_checks = 0;
  int n_garbage    = 0;
  always @(posedge pclk_in) begin
    if (dut.rst_aon_n === 1'b1) begin
      if (dut.iso_en === 1'b1) begin
        n_iso_checks++;
        if ({dut.cmd_pop, dut.rsp_push, dut.rsp_data, dut.prst_n} !== '0)
          err("PD_HOST output not clamped to 0 while isolated");
      end
      // Unpowered, the reset output would be 0 without the off-state model
      // (the logic sits in reset), so anything else is the model at work.
      if (!host_pwr_ack && dut.u_pd_host.pa_rst_n !== 1'b0)
        n_garbage++;
    end
  end

  always @(posedge clk_sys) begin
    if (rst_sys_n === 1'b1) begin
      if ($isunknown({dut.u_host_if.tx_full, dut.u_host_if.rx_empty, dut.u_host_if.host_idle,
                      dut.u_host_if.pending, dut.u_host_if.qrst_n, irq_pmu,
                      dut.cmd_pop, dut.rsp_push, dut.prst_n}))
        err("X on the core side of PD_HOST");
    end
  end

  // ---------------------------------------------------------------------------
  // APB in clk_sys: SETUP on a falling edge, ACCESS on the next, PREADY sampled
  // on falling edges
  // ---------------------------------------------------------------------------
  localparam logic [11:0] P_CTRL = 12'h000, P_STATUS = 12'h004, P_IRQ = 12'h008, P_TMO = 12'h00C,
                          P_CHIP = 12'h010, P_CAUSE  = 12'h014, P_SCR = 12'h018, P_CYC = 12'h01C;
  localparam logic [11:0] H_TX = 12'h000, H_RX = 12'h004, H_STATUS = 12'h008;
  localparam logic [3:0]  S_OFF = 4'd0, S_ON = 4'd5, S_FAIL = 4'd11;

  int n_apb = 0;

  task automatic apb(bit pmu, bit wr, logic [11:0] a, logic [31:0] d, output logic [31:0] rd);
    int w = 0;
    @(negedge clk_sys);
    psel_pmu = pmu; psel_host = !pmu; penable = 1'b0; pwrite = wr; paddr = a; pwdata = d; pstrb = 4'hF;
    @(negedge clk_sys);
    penable = 1'b1;
    while ((pmu ? pready_pmu : pready_host) !== 1'b1) begin
      @(negedge clk_sys);
      w++;
      if (w > 2000) begin
        $display("[PWR] ERROR: APB access to %s %h never completed", pmu ? "PMU" : "HOST", a);
        $fatal(1, "[PWR] FAIL: hang");
      end
    end
    rd = pmu ? prdata_pmu : prdata_host;
    if ((pmu ? pslverr_pmu : pslverr_host) === 1'b1) err($sformatf("PSLVERR at %h", a));
    @(negedge clk_sys);
    psel_pmu = 1'b0; psel_host = 1'b0; penable = 1'b0; pwrite = 1'b0;
    n_apb++;
  endtask

  task automatic pmu_wr(logic [11:0] a, logic [31:0] d);
    logic [31:0] u;
    apb(1'b1, 1'b1, a, d, u);
  endtask

  task automatic pmu_rd(logic [11:0] a, output logic [31:0] d);
    apb(1'b1, 1'b0, a, 32'd0, d);
  endtask

  task automatic host_wr(logic [11:0] a, logic [31:0] d);
    logic [31:0] u;
    apb(1'b0, 1'b1, a, d, u);
  endtask

  task automatic host_rd(logic [11:0] a, output logic [31:0] d);
    apb(1'b0, 1'b0, a, 32'd0, d);
  endtask

  task automatic expect_eq(string what, logic [31:0] got, logic [31:0] want);
    if (got !== want) err($sformatf("%s: %h, expected %h", what, got, want));
  endtask

  // Wait for the sequencer to reach a state, polling PWR_STATUS.
  task automatic wait_state(logic [3:0] s, string what);
    logic [31:0] st;
    int n = 0;
    do begin
      pmu_rd(P_STATUS, st);
      n++;
      if (n > 400) begin
        $display("[PWR] ERROR: %s: state %0d, waiting for %0d", what, st[3:0], s);
        $fatal(1, "[PWR] FAIL: hang");
      end
    end while (st[3:0] != s);
  endtask

  // One host command and its response.
  task automatic host_cmd(logic [31:0] cmd, output logic [31:0] rsp);
    logic [31:0] st;
    int n = 0;
    host_wr(H_TX, cmd);
    do begin
      host_rd(H_STATUS, st);
      n++;
      if (n > 200) begin
        err($sformatf("no response to command %h", cmd));
        break;
      end
    end while (!st[0]);
    host_rd(H_RX, rsp);
  endtask

  task automatic expect_rsp(string what, logic [31:0] cmd, logic [31:0] want);
    logic [31:0] r;
    host_cmd(cmd, r);
    expect_eq(what, r, want);
  endtask

  task automatic wait_aon(int n);
    repeat (n) @(posedge clk_aon);
  endtask

  // Clear and check PWR_IRQ.
  task automatic expect_irq(string what, logic [1:0] want);
    logic [31:0] v;
    pmu_rd(P_IRQ, v);
    expect_eq({what, ": PWR_IRQ"}, v, {30'd0, want});
    pmu_wr(P_IRQ, 32'h3);
  endtask

  realtime t0;
  int      i_seq = 0;

  task automatic power_down(string what, bit wake_en = 1'b1);
    logic [31:0] st;
    t0 = $realtime;
    pmu_wr(P_CTRL, {23'd0, wake_en, 8'h02});
    wait_state(S_OFF, what);
    pmu_rd(P_STATUS, st);
    expect_eq({what, ": result"}, {30'd0, st[17:16]}, 32'd1);
    expect_irq(what, 2'b01);
  endtask

  task automatic power_up(string what);
    t0 = $realtime;
    pmu_wr(P_CTRL, 32'h101);
    wait_state(S_ON, what);
    expect_irq(what, 2'b01);
  endtask

  // ---------------------------------------------------------------------------
  // Directed test
  // ---------------------------------------------------------------------------
  task automatic t_directed();
    logic [31:0] v, st;
    int g0;
    realtime t_dn, t_up;

    // Power-on: reset order and the automatic power-up.
    wait (rst_sys_n === 1'b1);
    wait_state(S_ON, "power-on");
    if (!(t_aon < t_sys && t_sys < t_nand && t_nand < t_host))
      err($sformatf("power-on release order: AON %0t, core %0t, NAND %0t, host %0t", t_aon, t_sys, t_nand, t_host));
    $display("[PWR] power-on release: AON %0.1f us, core %0.1f us, NAND %0.1f us, PD_HOST %0.1f us",
             t_aon / 1000.0, t_sys / 1000.0, t_nand / 1000.0, t_host / 1000.0);
    pmu_rd(P_CAUSE, v);
    expect_eq("RST_CAUSE after power-on", v, 32'h1);
    pmu_wr(P_CAUSE, 32'h3);
    // The automatic power-up is part of the reset sequence: no interrupt.
    if (irq_pmu !== 1'b0) err("PMU interrupt after the automatic power-up");
    expect_irq("power-on", 2'b00);

    // Host commands.
    expect_rsp("CFG",   32'h1000_ABCD, 32'h1000_ABCD);
    expect_rsp("ECHO 1", 32'h0000_0011, 32'h0000_0011);
    expect_rsp("ECHO 2", 32'h0000_0022, 32'h0001_0022);
    expect_rsp("ECHO 3", 32'h0000_0033, 32'h0002_0033);
    expect_rsp("STATE", 32'h2000_0000, 32'hABCD_0033);
    $display("[PWR] host commands: CFG, 3 ECHO, STATE: %s", verdict(errors));

    // A power-down while a response is unread is refused.
    host_wr(H_TX, 32'h0000_0044);
    repeat (20) @(posedge clk_sys);
    host_rd(H_STATUS, st);
    if (st[3]) err("STATUS.IDLE with a response unread");
    pmu_wr(P_CTRL, 32'h102);
    wait_aon(4);
    pmu_rd(P_STATUS, st);
    expect_eq("state after a refused power-down", {28'd0, st[3:0]}, {28'd0, S_ON});
    expect_eq("result after a refused power-down", {30'd0, st[17:16]}, 32'd2);
    expect_irq("refused power-down", 2'b10);
    host_rd(H_RX, v);
    expect_eq("ECHO 4", v, 32'h0003_0044);
    $display("[PWR] power-down refused while a response was unread: %s", verdict(errors));

    // Power cycle with retention.
    g0 = n_garbage;
    power_down("power-down 1");
    t_dn = $realtime - t0;
    host_wr(H_TX, 32'h0000_0099);
    host_rd(H_STATUS, st);
    if (!st[8] || st[2]) err($sformatf("TX while off: STATUS %h, expected TX_DROP and not ON", st));
    host_wr(H_STATUS, 32'h100);
    wait_aon(20);
    if (n_garbage == g0) err("the off-state model produced no garbage while PD_HOST was off");
    power_up("power-up 1");
    t_up = $realtime - t0;
    expect_rsp("STATE after power-up", 32'h2000_0000, 32'hABCD_0000);
    expect_rsp("SEQ after power-up",   32'h3000_0000, 32'h0000_0004);
    expect_rsp("ECHO 5",               32'h0000_0055, 32'h0004_0055);
    pmu_rd(P_CYC, v);
    expect_eq("PWR_CYCLES", v, 32'd1);
    $display("[PWR] power cycle: down %0.1f us, up %0.1f us (APB polling included); CFG and SEQ restored, LAST reset, %0d garbage clocks off: %s",
             t_dn / 1000.0, t_up / 1000.0, n_garbage - g0, verdict(errors));

    // Wake pin.
    power_down("power-down 2");
    host_wake = 1'b1;
    wait_aon(3);
    host_wake = 1'b0;
    wait_state(S_ON, "wake");
    pmu_rd(P_STATUS, st);
    if (!st[24]) err("PWR_STATUS.WOKE not set after a wake-up");
    expect_irq("wake", 2'b01);
    expect_rsp("SEQ after wake", 32'h3000_0000, 32'h0000_0005);
    power_down("power-down 3", 1'b0);   // WAKE_EN off
    host_wake = 1'b1;
    wait_aon(3);
    host_wake = 1'b0;
    wait_aon(20);
    pmu_rd(P_STATUS, st);
    expect_eq("state after a wake with WAKE_EN 0", {28'd0, st[3:0]}, {28'd0, S_OFF});
    power_up("power-up 3");
    pmu_rd(P_STATUS, st);
    if (st[24]) err("PWR_STATUS.WOKE set after a software power-up");
    $display("[PWR] wake pin: powers up with WAKE_EN, ignored without: %s", verdict(errors));

    // Switch stuck on during a power-down: timeout, FAIL, then recovery.
    pmu_wr(P_TMO, 32'd8);
    sw_stuck = 1'b1;
    pmu_wr(P_CTRL, 32'h102);
    wait_state(S_FAIL, "switch stuck");
    pmu_rd(P_STATUS, st);
    expect_eq("result after the switch timeout", {30'd0, st[17:16]}, 32'd3);
    expect_irq("switch timeout", 2'b10);
    sw_stuck = 1'b0;
    wait_aon(10);
    power_up("power-up after FAIL");
    expect_rsp("STATE after FAIL and power-up", 32'h2000_0000, 32'hABCD_0000);
    pmu_wr(P_TMO, 32'd64);
    $display("[PWR] switch stuck on: timeout after 8 clk_aon cycles, FAIL, recovery with CFG restored: %s",
             verdict(errors));

    // Chip reset: PD_CORE and PD_HOST logic reset, PD_AON kept.
    pmu_wr(P_SCR, 32'h1234_5678);
    pmu_wr(P_CHIP, 32'h0000_0001);      // wrong key
    wait_aon(5);
    if (rst_sys_n !== 1'b1) err("chip reset with a wrong key");
    pmu_wr(P_CHIP, 32'h5AFE_0001);
    wait (rst_sys_n === 1'b0);
    t0 = $realtime;
    wait (rst_sys_n === 1'b1);
    wait (dut.u_pd_host.rst_n === 1'b1);
    #1;   // let the release-time monitors run first
    if (!(t_sys < t_nand && t_nand < t_host))
      err($sformatf("chip reset release order: core %0t, NAND %0t, host %0t", t_sys, t_nand, t_host));
    pmu_rd(P_CAUSE, v);
    expect_eq("RST_CAUSE after a chip reset", v, 32'h2);
    pmu_rd(P_SCR, v);
    expect_eq("AON_SCRATCH after a chip reset", v, 32'h1234_5678);
    pmu_rd(P_STATUS, st);
    expect_eq("state after a chip reset", {28'd0, st[3:0]}, {28'd0, S_ON});
    wait_aon(3);
    expect_rsp("SEQ after a chip reset",   32'h3000_0000, 32'h0000_0000);
    expect_rsp("STATE after a chip reset", 32'h2000_0000, 32'h0000_0000);
    pmu_rd(P_CYC, v);
    expect_eq("PWR_CYCLES after a chip reset", v, 32'd3);   // the FAIL above does not count
    $display("[PWR] chip reset: core held %0.1f us, order core, NAND, host; AON_SCRATCH and PWR_CYCLES kept, host state reset: %s",
             (t_sys - t0) / 1000.0, verdict(errors));

    // APB crossing: random accesses to PMU and HOST registers.
    for (int i = 0; i < 200; i++) begin
      logic [31:0] d = $urandom;
      case ($urandom_range(3))
        0: begin pmu_wr(P_SCR, d); pmu_rd(P_SCR, v); expect_eq("AON_SCRATCH", v, d); end
        1: begin pmu_wr(P_TMO, d); pmu_rd(P_TMO, v); expect_eq("TIMEOUT", v, {16'd0, d[15:0]}); end
        2: begin host_rd(H_STATUS, v); expect_eq("HOST STATUS", v & 32'hF, 32'hC); end
        default: begin
          expect_rsp("ECHO in the stress loop", {16'h0000, d[15:0]}, {16'(i_seq), d[15:0]});
          i_seq++;
        end
      endcase
    end
    pmu_wr(P_TMO, 32'd64);
    $display("[PWR] APB crossing: 200 random accesses to PMU and HOST: %s", verdict(errors));
  endtask

  task automatic t_pll_stuck();
    logic [31:0] st;
    wait (rst_sys_n === 1'b1);
    wait_state(S_FAIL, "PLL stuck");
    pmu_rd(P_STATUS, st);
    expect_eq("result with the PLL stuck", {30'd0, st[17:16]}, 32'd3);
    expect_irq("PLL timeout", 2'b10);
    if (host_pwr_en !== 1'b0) err("FAIL left the switch on");
    $display("[PWR] PLL never locks: power-on sequence ends in FAIL with result 3, switch off: %s",
             verdict(errors));
  endtask

  // ---------------------------------------------------------------------------
  // Main
  // ---------------------------------------------------------------------------
  string test = "directed";

  initial begin
    void'($value$plusargs("test=%s", test));
    #2000;
    por_n = 1'b1;
    if (test == "pll_stuck") t_pll_stuck();
    else                     t_directed();
    $display("[PWR] checks: %0d sequencing samples, %0d isolation samples, %0d APB accesses",
             n_seq_checks, n_iso_checks, n_apb);
    if (errors == 0) begin
      $display("[PWR] %s: PASS", test);
      $finish;
    end else begin
      $display("[PWR] %s: FAIL, %0d errors", test, errors);
      $fatal(1, "[PWR] FAIL");
    end
  end

endmodule
