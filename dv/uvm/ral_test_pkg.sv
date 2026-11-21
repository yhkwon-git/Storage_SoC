// ral_test_pkg
//
// UVM register tests for the APB blocks, run on Vivado's simulator (xsim)
// with UVM 1.2. The register model is the generated soc_apb
// (dv/ral/soc_apb_ral_pkg.sv); the DUT is apb_sys, apb_intc and apb_timer,
// so the generated register RTL is tested together with the logic around it.
//
//   1. uvm_reg_hw_reset_seq   every register's reset value
//   2. uvm_reg_bit_bash_seq   every bit of every register: written 1 and 0,
//                             read back against the field's access type
//   3. behavior               INTC pending and claim, timer counting and
//                             prescale, software write over counting, the
//                             timer and external interrupts, one console and
//                             exit event per write, writes to read-only
//                             registers ignored without error
//   4. decode                 PSLVERR for offsets and slots with no register
//
// Left out of 1 and 2, with the reason: MTIME_LO/HI count from reset
// (checked in 3); CONSOLE and EXIT are write-only events that read as 0
// (checked in 3). Fields written by hardware (PENDING, CLAIM, MTIME) are
// volatile in the model, so the bit bash does not compare them.

package ral_test_pkg;
  `include "uvm_macros.svh"
  import uvm_pkg::*;
  import apb_pkg::*;
  import soc_apb_ral_pkg::*;

  class ral_env extends uvm_env;
    `uvm_component_utils(ral_env)

    apb_sequencer   seqr;
    apb_driver      drv;
    reg2apb_adapter adapter;
    soc_apb         regmodel;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      seqr     = apb_sequencer::type_id::create("seqr", this);
      drv      = apb_driver::type_id::create("drv", this);
      adapter  = reg2apb_adapter::type_id::create("adapter");
      regmodel = new("regmodel");
      regmodel.build();
      regmodel.lock_model();
      regmodel.reset();
    endfunction

    function void connect_phase(uvm_phase phase);
      drv.seq_item_port.connect(seqr.seq_item_export);
      regmodel.default_map.set_sequencer(seqr, adapter);
      regmodel.default_map.set_auto_predict(1);
    endfunction
  endclass

  class ral_test extends uvm_test;
    `uvm_component_utils(ral_test)

    ral_env        env;
    virtual apb_if vif;
    int            n_checks;
    int            n_fail;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      env = ral_env::type_id::create("env", this);
      if (!uvm_config_db #(virtual apb_if)::get(this, "", "vif", vif))
        `uvm_fatal("NOVIF", "apb_if not set")
    endfunction

    function void exclude(uvm_reg r, string test);
      uvm_resource_db #(bit)::set({"REG::", r.get_full_name()}, test, 1, this);
    endfunction

    function void expect_ok(bit ok, string what);
      n_checks++;
      if (!ok) begin
        n_fail++;
        `uvm_error("CHECK", what)
      end
    endfunction

    task raw(bit [15:0] addr, bit write, bit [31:0] data, output bit [31:0] rdata, output bit slverr);
      apb_single_seq s = apb_single_seq::type_id::create("s");
      s.addr  = addr;
      s.write = write;
      s.data  = data;
      s.start(env.seqr);
      rdata  = s.rdata;
      slverr = s.slverr;
    endtask

    task run_phase(uvm_phase phase);
      uvm_reg_hw_reset_seq rst_seq;
      uvm_reg_bit_bash_seq bb_seq;
      uvm_status_e         st;
      uvm_reg_data_t       v, v2;
      soc_apb              rm;
      bit [31:0]           rd;
      bit                  err;
      int                  c0, e0;
      bit [15:0]           bad_addr[$];

      phase.raise_objection(this);
      rm = env.regmodel;
      @(posedge vif.presetn);
      repeat (2) @(posedge vif.pclk);

      exclude(rm.TIMER.MTIME_LO, "NO_REG_HW_RESET_TEST");
      exclude(rm.TIMER.MTIME_HI, "NO_REG_HW_RESET_TEST");
      exclude(rm.TIMER.MTIME_LO, "NO_REG_BIT_BASH_TEST");
      exclude(rm.TIMER.MTIME_HI, "NO_REG_BIT_BASH_TEST");
      exclude(rm.SYS.CONSOLE,    "NO_REG_BIT_BASH_TEST");
      exclude(rm.SYS.EXIT,       "NO_REG_BIT_BASH_TEST");

      // 1. Reset values.
      rst_seq = uvm_reg_hw_reset_seq::type_id::create("rst_seq");
      rst_seq.model = rm;
      rst_seq.start(null);

      // 2. Bit bash.
      bb_seq = uvm_reg_bit_bash_seq::type_id::create("bb_seq");
      bb_seq.model = rm;
      bb_seq.start(null);

      // 3a. INTC: PENDING is SWSET without bit 0; CLAIM is the lowest pending
      // and enabled ID; the external interrupt follows.
      rm.INTC.ENABLE.write(st, 32'h0010_0200);
      rm.INTC.SWSET.write(st, 32'h0010_0201);
      rm.INTC.PENDING.read(st, v);
      expect_ok(v == 32'h0010_0200, $sformatf("PENDING %h, expected 00100200", v));
      rm.INTC.CLAIM.read(st, v);
      expect_ok(v == 9, $sformatf("CLAIM %0d, expected 9", v));
      expect_ok(vif.irq_external === 1'b1, "external interrupt low with sources 9 and 20 enabled");
      rm.INTC.SWSET.write(st, 32'h0010_0000);
      rm.INTC.CLAIM.read(st, v);
      expect_ok(v == 20, $sformatf("CLAIM %0d, expected 20", v));
      rm.INTC.ENABLE.write(st, 32'h0000_0200);
      rm.INTC.CLAIM.read(st, v);
      expect_ok(v == 0, $sformatf("CLAIM %0d with nothing enabled pending, expected 0", v));
      expect_ok(vif.irq_external === 1'b0, "external interrupt high with nothing enabled pending");
      rm.INTC.SWSET.write(st, 32'h0);
      rm.INTC.ENABLE.write(st, 32'h0);

      // 3b. TIMER: one APB read takes 3 clocks in this driver, so two
      // back-to-back reads see MTIME 3 apart at prescale 0 and 1 apart at
      // prescale 2.
      rm.TIMER.CTRL.write(st, 32'h0000_0001);
      rm.TIMER.MTIME_LO.read(st, v);
      rm.TIMER.MTIME_LO.read(st, v2);
      expect_ok(v2 - v == 3, $sformatf("MTIME advanced by %0d between reads at prescale 0, expected 3", v2 - v));
      rm.TIMER.CTRL.write(st, 32'h0000_0201);
      rm.TIMER.MTIME_LO.read(st, v);
      rm.TIMER.MTIME_LO.read(st, v2);
      expect_ok(v2 - v == 1, $sformatf("MTIME advanced by %0d between reads at prescale 2, expected 1", v2 - v));
      rm.TIMER.CTRL.write(st, 32'h0000_0000);
      rm.TIMER.MTIME_LO.read(st, v);
      rm.TIMER.MTIME_LO.read(st, v2);
      expect_ok(v2 == v, "MTIME moved with counting disabled");
      // A software write wins over counting.
      rm.TIMER.CTRL.write(st, 32'h0000_0001);
      rm.TIMER.MTIME_HI.write(st, 32'h0000_0000);
      rm.TIMER.MTIME_LO.write(st, 32'h0000_1000);
      rm.TIMER.MTIME_LO.read(st, v);
      expect_ok(v >= 32'h1000 && v < 32'h1010, $sformatf("MTIME_LO %h after writing 1000", v));
      // Timer interrupt once MTIME reaches MTIMECMP.
      rm.TIMER.MTIMECMP_HI.write(st, 32'h0000_0000);
      rm.TIMER.MTIMECMP_LO.write(st, 32'h0000_1040);
      expect_ok(vif.irq_timer === 1'b0, "timer interrupt high before MTIMECMP");
      repeat (80) @(posedge vif.pclk);
      expect_ok(vif.irq_timer === 1'b1, "timer interrupt low after MTIMECMP");
      rm.TIMER.MTIMECMP_HI.write(st, 32'hFFFF_FFFF);
      repeat (2) @(posedge vif.pclk);
      expect_ok(vif.irq_timer === 1'b0, "timer interrupt high with MTIMECMP at its maximum");

      // 3c. SYS: one console event per CONSOLE write, one exit event per EXIT
      // write, each with the written value; read-only registers ignore writes
      // and answer without error.
      c0 = vif.console_events;
      e0 = vif.exit_events;
      rm.SYS.CONSOLE.write(st, 32'h0000_0041);
      rm.SYS.EXIT.write(st, 32'h0000_1234);
      repeat (2) @(posedge vif.pclk);
      expect_ok(vif.console_events == c0 + 1 && vif.last_char == 8'h41, "CONSOLE write did not give one event with 'A'");
      expect_ok(vif.exit_events == e0 + 1 && vif.last_code == 32'h1234, "EXIT write did not give one event with 1234");
      rm.SYS.ID.write(st, 32'h0);
      expect_ok(st == UVM_IS_OK, "write to ID answered an error");
      rm.SYS.ID.mirror(st, UVM_CHECK);

      // 4. Decode: offsets and slots without a register answer PSLVERR.
      raw(16'h0000, 1'b0, 0, rd, err);
      expect_ok(!err && rd == 32'h5353_4F43, "ID read through a raw transfer");
      bad_addr = '{16'h0018, 16'h0FFC, 16'h1000, 16'h1FFC, 16'h2010, 16'h3014, 16'h4000, 16'hF000};
      foreach (bad_addr[i]) begin
        raw(bad_addr[i], 1'b0, 0, rd, err);
        expect_ok(err, $sformatf("read of %h answered without PSLVERR", bad_addr[i]));
        raw(bad_addr[i], 1'b1, 32'hFFFF_FFFF, rd, err);
        expect_ok(err, $sformatf("write of %h answered without PSLVERR", bad_addr[i]));
      end

      `uvm_info("RAL", $sformatf("behavior and decode checks %0d, failures %0d, APB transfers %0d",
                                 n_checks, n_fail, env.drv.n_xfers), UVM_NONE)
      phase.drop_objection(this);
    endtask
  endclass
endpackage
