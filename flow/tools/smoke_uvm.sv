// Toolchain check, Vivado simulator side: UVM 1.2 sequence -> driver,
// randomize() with a constraint, and a covergroup read back with get_coverage().
// Pass = UVM_ERROR 0 and UVM_FATAL 0 (report_phase raises an error otherwise).
`timescale 1ns/1ps
`include "uvm_macros.svh"
import uvm_pkg::*;

class smoke_item extends uvm_sequence_item;
  rand bit [3:0] a;
  constraint c_a { a inside {[0:9]}; }
  `uvm_object_utils(smoke_item)
  function new(string name = "smoke_item"); super.new(name); endfunction
endclass

class smoke_seq extends uvm_sequence #(smoke_item);
  `uvm_object_utils(smoke_seq)
  function new(string name = "smoke_seq"); super.new(name); endfunction
  task body();
    repeat (50) begin
      smoke_item it = smoke_item::type_id::create("it");
      start_item(it);
      if (!it.randomize()) `uvm_error("SMOKE", "randomize failed")
      finish_item(it);
    end
  endtask
endclass

class smoke_drv extends uvm_driver #(smoke_item);
  `uvm_component_utils(smoke_drv)
  covergroup cg with function sample(bit [3:0] v);
    cp: coverpoint v { bins lo = {[0:4]}; bins hi = {[5:9]}; illegal_bins over = {[10:15]}; }
  endgroup
  int n;
  function new(string name, uvm_component parent); super.new(name, parent); cg = new; endfunction
  task run_phase(uvm_phase phase);
    forever begin
      seq_item_port.get_next_item(req);
      cg.sample(req.a);
      n++;
      #1;
      seq_item_port.item_done();
    end
  endtask
  function void report_phase(uvm_phase phase);
    real cov = cg.get_coverage();
    `uvm_info("SMOKE", $sformatf("items=%0d coverage=%0.1f", n, cov), UVM_NONE)
    if (n != 50 || cov < 100.0) `uvm_error("SMOKE", "expected 50 items and full coverage")
  endfunction
endclass

class smoke_test extends uvm_test;
  `uvm_component_utils(smoke_test)
  uvm_sequencer #(smoke_item) sqr;
  smoke_drv drv;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    sqr = uvm_sequencer#(smoke_item)::type_id::create("sqr", this);
    drv = smoke_drv::type_id::create("drv", this);
  endfunction
  function void connect_phase(uvm_phase phase);
    drv.seq_item_port.connect(sqr.seq_item_export);
  endfunction
  task run_phase(uvm_phase phase);
    smoke_seq s = smoke_seq::type_id::create("s");
    phase.raise_objection(this);
    s.start(sqr);
    phase.drop_objection(this);
  endtask
endclass

module smoke_uvm;
  initial run_test("smoke_test");
endmodule
