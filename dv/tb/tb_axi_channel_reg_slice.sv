// tb_axi_channel_reg_slice
//
// 1. Random VALID and READY: every beat comes out once, in order, and VALID
//    and payload hold until accepted (the slice's own monitors stop the run
//    on a violation, and the testbench checks the output side again).
// 2. Full rate: with VALID and READY held high, one beat per clock and one
//    clock of latency.
// 3. Stalls: with VALID held high, a downstream stall of k clocks blocks the
//    upstream for exactly k clocks, for k = 1..6.
// Seed: +verilator+seed+N.

`timescale 1ns/1ps

module tb_axi_channel_reg_slice;

  localparam int W = 16;

  logic         aclk    = 1'b0;
  logic         aresetn = 1'b0;
  logic         s_valid = 1'b0;
  logic [W-1:0] s_data  = '0;
  logic         m_ready = 1'b0;
  wire          s_ready;
  wire          m_valid;
  wire  [W-1:0] m_data;

  always #5 aclk = ~aclk;

  axi_channel_reg_slice #(.WIDTH(W)) dut (
    .aclk    (aclk),
    .aresetn (aresetn),
    .s_valid (s_valid),
    .s_ready (s_ready),
    .s_data  (s_data),
    .m_valid (m_valid),
    .m_ready (m_ready),
    .m_data  (m_data)
  );

  // Controls, written by the test sequence between clock edges.
  int unsigned  target      = 0;    // beats the upstream sends in this phase
  int unsigned  valid_pct   = 100;
  int unsigned  ready_pct   = 100;
  bit           ready_force = 1'b0; // 1: m_ready follows ready_value
  bit           ready_value = 1'b1;

  // Handshake times use $time: the two always blocks below run in either
  // order on the same edge, so a counter kept in one of them is not a
  // reliable clock count for the other.
  logic [W-1:0]    model[$];
  int unsigned     sent = 0, recv = 0, errors = 0;
  longint unsigned cyc = 0;
  longint unsigned first_s = 0, first_m = 0, last_m = 0;
  int unsigned     up_blocked = 0, down_stalled = 0;

  // Upstream: once VALID is high, hold VALID and data until READY.
  always @(posedge aclk) begin
    if (aresetn) begin
      if (s_valid && s_ready) begin
        model.push_back(s_data);
        sent++;
        if (sent == 1) first_s = $time;
      end
      if (s_valid && !s_ready) up_blocked++;
      if (!s_valid || s_ready) begin
        s_valid <= (sent < target) && ($urandom_range(99) < valid_pct);
        s_data  <= W'($urandom());
      end
    end
  end

  // Downstream: compare each accepted beat; check the output holds while stalled.
  logic         prev_valid = 1'b0, prev_ready = 1'b0;
  logic [W-1:0] prev_data  = '0;
  always @(posedge aclk) begin
    if (aresetn) begin
      cyc++;
      if (prev_valid && !prev_ready && (!m_valid || m_data !== prev_data)) begin
        errors++;
        $display("[SLICE] ERROR output changed while stalled at clock %0d", cyc);
      end
      if (m_valid && !m_ready) down_stalled++;
      if (m_valid && m_ready) begin
        logic [W-1:0] exp;
        exp = model.pop_front();
        if (m_data !== exp) begin
          errors++;
          if (errors <= 5) $display("[SLICE] ERROR beat %0d: %h, expected %h", recv, m_data, exp);
        end
        recv++;
        if (recv == 1) first_m = $time;
        last_m = $time;
      end
      prev_valid <= m_valid;
      prev_ready <= m_ready;
      prev_data  <= m_data;
      m_ready    <= ready_force ? ready_value : ($urandom_range(99) < ready_pct);
    end
  end

  task automatic phase_start(int unsigned beats, int unsigned vpct, int unsigned rpct,
                             bit force_ready);
    @(negedge aclk);
    sent = 0; recv = 0; first_s = 0; first_m = 0; last_m = 0;
    up_blocked = 0; down_stalled = 0; cyc = 0;
    target = beats; valid_pct = vpct; ready_pct = rpct;
    ready_force = force_ready; ready_value = 1'b1;
  endtask

  task automatic drain();
    target = sent;
    ready_force = 1'b1;
    ready_value = 1'b1;
    wait (recv == sent && !m_valid);
    repeat (2) @(posedge aclk);
  endtask

  int unsigned rnd_beats;
  real         rate;
  int unsigned latency;
  string       stall_line;
  bit          stall_ok;

  initial begin
    repeat (3) @(posedge aclk);
    aresetn <= 1'b1;

    // 1. Random.
    phase_start(5000, 60, 60, 1'b0);
    wait (recv == 5000);
    rnd_beats = recv;
    drain();

    // 2. Full rate.
    phase_start(1000, 100, 100, 1'b1);
    wait (recv == 1000);
    rate    = real'(recv - 1) / (real'(last_m - first_m) / 10.0);
    latency = int'((first_m - first_s) / 10);
    drain();

    // 3. Stalls of k clocks in a stream that never stops offering.
    stall_ok   = 1'b1;
    stall_line = "";
    for (int k = 1; k <= 6; k++) begin
      phase_start(100000, 100, 100, 1'b1);
      repeat (10) @(negedge aclk);
      @(negedge aclk);
      up_blocked = 0; down_stalled = 0;
      ready_value = 1'b0;
      repeat (k) @(negedge aclk);
      ready_value = 1'b1;
      repeat (10) @(negedge aclk);
      stall_line = {stall_line, $sformatf(" %0d/%0d", down_stalled, up_blocked)};
      if (down_stalled != k || up_blocked != k) stall_ok = 1'b0;
      drain();
    end

    $display("[SLICE] random: %0d beats in order, errors %0d", rnd_beats, errors);
    $display("[SLICE] full rate: %.3f beats per clock, latency %0d clock", rate, latency);
    $display("[SLICE] stall k=1..6, downstream/upstream stalled clocks:%s", stall_line);

    if (errors != 0 || rate < 1.0 || latency != 1 || !stall_ok) $fatal(1, "[SLICE] FAIL");
    $display("[SLICE] PASS");
    $finish;
  end

endmodule
