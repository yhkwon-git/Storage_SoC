// apb_pkg
//
// A minimal APB4 master agent for UVM 1.2: sequence item, driver, sequencer,
// and the adapter that lets a uvm_reg_map run register operations on it.
//
// The driver runs one transfer at a time: SETUP for one clock, then ACCESS
// until PREADY. Read data and PSLVERR are written back into the item, and the
// adapter turns PSLVERR into UVM_NOT_OK.

package apb_pkg;
  `include "uvm_macros.svh"
  import uvm_pkg::*;

  class apb_item extends uvm_sequence_item;
    rand bit [15:0] addr;
    rand bit        write;
    rand bit [31:0] data;
    rand bit [3:0]  strb;
    bit      [31:0] rdata;
    bit             slverr;

    `uvm_object_utils_begin(apb_item)
      `uvm_field_int(addr,   UVM_ALL_ON)
      `uvm_field_int(write,  UVM_ALL_ON)
      `uvm_field_int(data,   UVM_ALL_ON)
      `uvm_field_int(strb,   UVM_ALL_ON)
      `uvm_field_int(rdata,  UVM_ALL_ON)
      `uvm_field_int(slverr, UVM_ALL_ON)
    `uvm_object_utils_end

    function new(string name = "apb_item");
      super.new(name);
      strb = 4'hF;
    endfunction
  endclass

  typedef uvm_sequencer #(apb_item) apb_sequencer;

  class apb_driver extends uvm_driver #(apb_item);
    `uvm_component_utils(apb_driver)

    virtual apb_if vif;
    int unsigned   n_xfers;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db #(virtual apb_if)::get(this, "", "vif", vif))
        `uvm_fatal("NOVIF", "apb_if not set")
    endfunction

    task run_phase(uvm_phase phase);
      vif.psel    <= 1'b0;
      vif.penable <= 1'b0;
      vif.pwrite  <= 1'b0;
      vif.paddr   <= '0;
      vif.pwdata  <= '0;
      vif.pstrb   <= '0;
      vif.pprot   <= '0;
      @(posedge vif.presetn);
      forever begin
        seq_item_port.get_next_item(req);
        @(posedge vif.pclk);
        vif.psel    <= 1'b1;
        vif.penable <= 1'b0;
        vif.paddr   <= req.addr;
        vif.pwrite  <= req.write;
        vif.pwdata  <= req.write ? req.data : 32'd0;
        vif.pstrb   <= req.write ? req.strb : 4'h0;
        @(posedge vif.pclk);
        vif.penable <= 1'b1;
        do @(posedge vif.pclk); while (vif.pready !== 1'b1);
        req.rdata  = vif.prdata;
        req.slverr = vif.pslverr;
        vif.psel    <= 1'b0;
        vif.penable <= 1'b0;
        n_xfers++;
        seq_item_port.item_done();
      end
    endtask
  endclass

  class reg2apb_adapter extends uvm_reg_adapter;
    `uvm_object_utils(reg2apb_adapter)

    function new(string name = "reg2apb_adapter");
      super.new(name);
      supports_byte_enable = 1;
      provides_responses   = 0;
    endfunction

    virtual function uvm_sequence_item reg2bus(const ref uvm_reg_bus_op rw);
      apb_item it = apb_item::type_id::create("it");
      it.addr  = rw.addr[15:0];
      it.write = (rw.kind == UVM_WRITE);
      it.data  = rw.data[31:0];
      it.strb  = rw.byte_en[3:0];
      return it;
    endfunction

    virtual function void bus2reg(uvm_sequence_item bus_item, ref uvm_reg_bus_op rw);
      apb_item it;
      if (!$cast(it, bus_item)) `uvm_fatal("CAST", "not an apb_item")
      rw.kind   = it.write ? UVM_WRITE : UVM_READ;
      rw.addr   = it.addr;
      rw.data   = it.write ? it.data : it.rdata;
      rw.status = it.slverr ? UVM_NOT_OK : UVM_IS_OK;
    endfunction
  endclass

  // One raw transfer, for addresses the register model does not contain.
  class apb_single_seq extends uvm_sequence #(apb_item);
    `uvm_object_utils(apb_single_seq)
    bit [15:0] addr;
    bit        write;
    bit [31:0] data;
    bit [31:0] rdata;
    bit        slverr;

    function new(string name = "apb_single_seq");
      super.new(name);
    endfunction

    task body();
      apb_item it = apb_item::type_id::create("it");
      start_item(it);
      it.addr  = addr;
      it.write = write;
      it.data  = data;
      it.strb  = 4'hF;
      finish_item(it);
      rdata  = it.rdata;
      slverr = it.slverr;
    endtask
  endclass
endpackage
