// ral_test_pkg
//
// UVM register tests for the APB blocks, run on Vivado's simulator (xsim)
// with UVM 1.2. The register model is the generated soc_apb
// (dv/ral/soc_apb_ral_pkg.sv); the DUT is apb_sys, apb_intc, apb_timer, dma,
// two nand_ctrl and soc_pwr (PMU behind its clock-domain crossing, HOST, NVME), so the generated
// register RTL is tested together with the logic around it.
//
//   1. uvm_reg_hw_reset_seq   every register's reset value
//   2. uvm_reg_bit_bash_seq   every bit of every register: written 1 and 0,
//                             read back against the field's access type
//   3. behavior               INTC pending and claim, timer counting and
//                             prescale, software write over counting, the
//                             timer and external interrupts, one console and
//                             exit event per write, writes to read-only
//                             registers ignored without error; DMA: a
//                             misaligned DESC_PTR ends in ERR with cause 4
//                             and no bus request, ERR reaches INTC source 2,
//                             write-1-to-clear, ABORT while idle does nothing;
//                             PMU and HOST: power-on reset cause, a PD_HOST
//                             power-up with its interrupt, a command through
//                             PD_HOST, the link held, a power-down;
//                             NVME with no host: controller off, no command,
//                             16 free slots, no interrupt with every source
//                             enabled; NAND0 and NAND1 with no device: idle,
//                             write protect on from reset, a STATUS command
//                             completing with its tag and the bus's FFh and
//                             its done interrupt until CPL is read
//   4. decode                 PSLVERR for offsets and slots with no register
//
// Left out of 1 and 2, with the reason: MTIME_LO/HI count from reset
// (checked in 3); CONSOLE and EXIT are write-only events that read as 0
// (checked in 3); DMA CTRL is write-only and a 1 in it starts or aborts the
// DMA (checked in 3); PMU PWR_CTRL starts power sequences and CHIP_RESET
// resets the testbench; PMU RST_CAUSE is set by hardware at power-on
// (checked in 3); HOST TX and RX push and pop the host FIFOs (checked in 3);
// HOST BM_CTRL starts a bus-master transfer and MSIX_REQ requests a vector
// (both checked by tb_tl and the host firmware test); NVME SLOT_FREE is
// write-only and returns a command-buffer slot, XF_CTRL starts a PRP transfer
// and CQE_CTRL queues a completion queue entry (all checked by tb_nvme);
// NAND CMD_GO queues a command and reading CPL takes a completion (checked
// in 3 and by tb_nand).
// Fields written by hardware (PENDING, CLAIM, MTIME, the DMA's and PMU's
// status and counters) are volatile in the model, so the bit bash does not
// compare them.

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

    task nand_check(nand_regs b, int c);
      uvm_status_e st;
      uvm_reg_data_t v;
      int n = 0;
      b.STATUS.read(st, v);
      expect_ok(v[15:0] == 16'h0002, $sformatf("NAND%0d STATUS %h, expected idle with R/B# ready", c, v));
      b.CTRL.read(st, v);
      expect_ok(v[2:0] == 3'b001, $sformatf("NAND%0d CTRL %h, expected write protect on", c, v));
      b.CTRL.write(st, 32'h2);                              // IEN_DONE
      b.CMD_GO.write(st, 32'h5A05);                         // STATUS, tag 5Ah
      do begin
        repeat (10) @(posedge vif.pclk);
        b.STATUS.read(st, v);
      end while (v[15:12] == 4'd0 && ++n < 100);
      env.regmodel.INTC.PENDING.read(st, v);
      expect_ok(v[6 + 2 * c] == 1'b1, $sformatf("INTC PENDING %h: NAND%0d done not pending", v, c));
      b.CPL.read(st, v);
      expect_ok(v[31] && v[7:0] == 8'h5A && v[9:8] == 2'd0 && v[23:16] == 8'hFF,
                $sformatf("NAND%0d CPL %h, expected tag 5A, code 0, status FF", c, v));
      env.regmodel.INTC.PENDING.read(st, v);
      expect_ok(v[6 + 2 * c] == 1'b0, $sformatf("INTC PENDING %h: NAND%0d done pending after CPL", v, c));
      b.CTRL.write(st, 32'h1);
    endtask

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

    // Poll PWR_STATUS until the PD_HOST sequencer reaches state s.
    task wait_pmu_state(int s, output uvm_reg_data_t v);
      uvm_status_e st;
      int n = 0;
      do begin
        env.regmodel.PMU.PWR_STATUS.read(st, v);
        n++;
      end while (v[3:0] != s && n < 50);
    endtask

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
      exclude(rm.DMA.CTRL,       "NO_REG_BIT_BASH_TEST");
      exclude(rm.PMU.PWR_CTRL,   "NO_REG_BIT_BASH_TEST");
      exclude(rm.PMU.CHIP_RESET, "NO_REG_BIT_BASH_TEST");
      exclude(rm.PMU.RST_CAUSE,  "NO_REG_HW_RESET_TEST");
      exclude(rm.PMU.RST_CAUSE,  "NO_REG_BIT_BASH_TEST");
      exclude(rm.HOST.TX,        "NO_REG_BIT_BASH_TEST");
      exclude(rm.HOST.RX,        "NO_REG_BIT_BASH_TEST");
      // A write starts a bus-master transfer or requests an MSI-X vector,
      // which would set BM_STATUS and ERR_STATUS bits under the test.
      exclude(rm.HOST.BM_CTRL,   "NO_REG_BIT_BASH_TEST");
      exclude(rm.HOST.MSIX_REQ,  "NO_REG_BIT_BASH_TEST");
      exclude(rm.NVME.SLOT_FREE, "NO_REG_BIT_BASH_TEST");
      // A write starts a PRP transfer or queues a completion queue entry.
      exclude(rm.NVME.XF_CTRL,   "NO_REG_BIT_BASH_TEST");
      exclude(rm.NVME.CQE_CTRL,  "NO_REG_BIT_BASH_TEST");
      // A write queues a NAND command; a read takes a completion.
      exclude(rm.NAND0.CMD_GO,   "NO_REG_BIT_BASH_TEST");
      exclude(rm.NAND1.CMD_GO,   "NO_REG_BIT_BASH_TEST");
      exclude(rm.NAND0.CPL,      "NO_REG_BIT_BASH_TEST");
      exclude(rm.NAND1.CPL,      "NO_REG_BIT_BASH_TEST");

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

      // 3d. DMA without a bus: START with a DESC_PTR that is not 16-byte
      // aligned ends at once in ERR, cause 4, the pointer in ERR_ADDR, and no
      // bus request. ERR is INTC source 2. Writing 1 clears it; ABORT while
      // idle changes nothing.
      rm.DMA.DESC_PTR.write(st, 32'h1000_0008);
      rm.DMA.CTRL.write(st, 32'h1);
      rm.DMA.STATUS.read(st, v);
      expect_ok(v == 32'h4, $sformatf("DMA STATUS %h after a misaligned START, expected 4 (ERR)", v));
      rm.DMA.ERR_INFO.read(st, v);
      expect_ok(v == 32'h4, $sformatf("DMA ERR_INFO %h, expected 4 (bad descriptor pointer)", v));
      rm.DMA.ERR_ADDR.read(st, v);
      expect_ok(v == 32'h1000_0008, $sformatf("DMA ERR_ADDR %h, expected 10000008", v));
      expect_ok(vif.dma_bus_req === 1'b0, "DMA made a bus request for a misaligned DESC_PTR");
      rm.INTC.PENDING.read(st, v);
      expect_ok(v == 32'h4, $sformatf("INTC PENDING %h with the DMA in ERR, expected 4 (source 2)", v));
      rm.DMA.STATUS.write(st, 32'h4);
      rm.DMA.STATUS.read(st, v);
      expect_ok(v == 32'h0, $sformatf("DMA STATUS %h after writing 1 to ERR, expected 0", v));
      rm.DMA.CTRL.write(st, 32'h2);
      rm.DMA.STATUS.read(st, v);
      rm.DMA.CYCLES.read(st, v2);
      expect_ok(v == 32'h0 && v2 == 32'h0, $sformatf("DMA STATUS %h CYCLES %0d after ABORT while idle", v, v2));

      // 3e. PMU through its clock-domain crossing, and HOST: power-on reset
      // cause; a PD_HOST power-up ends in ON with the DONE interrupt on INTC
      // source 10; one command through PD_HOST and back; a power-down ends in
      // OFF and counts in PWR_CYCLES.
      rm.PMU.TIMEOUT.write(st, 32'd64);   // the bit bash may have left anything here
      rm.PMU.RST_CAUSE.read(st, v);
      expect_ok(v == 32'h1, $sformatf("PMU RST_CAUSE %h after power-on, expected 1", v));
      rm.PMU.RST_CAUSE.write(st, 32'h3);
      rm.PMU.RST_CAUSE.read(st, v);
      expect_ok(v == 32'h0, $sformatf("PMU RST_CAUSE %h after writing 1s, expected 0", v));
      rm.PMU.PWR_CTRL.write(st, 32'h101);
      wait_pmu_state(5, v);
      expect_ok(v[3:0] == 4'd5, $sformatf("PMU PWR_STATUS %h after UP, expected state 5 (ON)", v));
      rm.PMU.PWR_IRQ.read(st, v);
      expect_ok(v == 32'h1, $sformatf("PMU PWR_IRQ %h after a power-up, expected 1 (DONE)", v));
      rm.INTC.PENDING.read(st, v);
      expect_ok(v == 32'h400, $sformatf("INTC PENDING %h with the PMU interrupt, expected 400 (source 10)", v));
      rm.PMU.PWR_IRQ.write(st, 32'h1);
      repeat (100) @(posedge vif.pclk);
      rm.INTC.PENDING.read(st, v);
      expect_ok(v == 32'h0, $sformatf("INTC PENDING %h after clearing PWR_IRQ", v));
      // STATUS.IDLE, and a power-down, need the host link held (step 2-1).
      rm.HOST.LINK_CTRL.write(st, 32'h1);
      do rm.HOST.LINK_STATUS.read(st, v); while (v[1:0] != 2'b11);
      rm.HOST.STATUS.read(st, v);
      expect_ok(v == 32'hC, $sformatf("HOST STATUS %h with PD_HOST on and the link held, expected C (ON, IDLE)", v));
      rm.HOST.TX.write(st, 32'h0000_0042);
      do rm.HOST.STATUS.read(st, v); while (!v[0]);
      rm.HOST.RX.read(st, v);
      expect_ok(v == 32'h0000_0042, $sformatf("HOST RX %h, expected 00000042 (ECHO, SEQ 0)", v));
      rm.PMU.PWR_CTRL.write(st, 32'h102);
      wait_pmu_state(0, v);
      rm.PMU.PWR_CYCLES.read(st, v2);
      expect_ok(v[3:0] == 4'd0 && v2 == 32'd1, $sformatf("PMU PWR_STATUS %h PWR_CYCLES %0d after DOWN", v, v2));
      rm.PMU.PWR_IRQ.write(st, 32'h3);

      // 3f. NVME without a host: controller off, no command waiting, 16 free
      // command-buffer slots; with every interrupt source enabled, none
      // fires (no event, no command).
      rm.NVME.STATUS.read(st, v);
      expect_ok(v == 32'h0010_0000, $sformatf("NVME STATUS %h, expected 00100000 (16 free slots)", v));
      rm.NVME.CMD.read(st, v);
      expect_ok(v == 32'h0, $sformatf("NVME CMD %h with no command, expected 0", v));
      rm.NVME.EVENT.write(st, 32'h1F);
      rm.NVME.EVENT_EN.write(st, 32'h1F);
      rm.NVME.CTRL.write(st, 32'h1);
      repeat (20) @(posedge vif.pclk);
      rm.INTC.PENDING.read(st, v);
      expect_ok(v[3] == 1'b0, $sformatf("INTC PENDING %h with NVME sources enabled and idle: source 3 set", v));
      rm.NVME.EVENT_EN.write(st, 32'h0);
      rm.NVME.CTRL.write(st, 32'h0);

      // 3g. NAND0 and NAND1 with no device (R/B# ready, DQ reads FFh): idle,
      // write protect on from reset; a STATUS command completes with its tag,
      // code 0 and FFh, and its done interrupt (INTC 6, 8) is pending until
      // CPL is read.
      nand_check(rm.NAND0, 0);
      nand_check(rm.NAND1, 1);

      // 4. Decode: offsets and slots without a register answer PSLVERR.
      raw(16'h0000, 1'b0, 0, rd, err);
      expect_ok(!err && rd == 32'h5353_4F43, "ID read through a raw transfer");
      bad_addr = '{16'h0018, 16'h0FFC, 16'h1020, 16'h1FFC, 16'h2010, 16'h3014, 16'h4020, 16'h5058,
                   16'h600C, 16'h7044, 16'h8028, 16'h8FFC, 16'h9000, 16'hF000};
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
