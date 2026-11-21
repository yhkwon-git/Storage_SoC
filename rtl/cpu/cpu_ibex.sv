`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// cpu_ibex
//
// Ibex (lowRISC, v2.1.0, rtl/vendor/ibex) in this SoC's configuration:
// RV32IMC with the fast multiplier, no B extension, no PMP, no instruction
// cache, no security features, flip-flop register file. The core and its
// register file are wired here the way ibex_top wires them, without the
// clock gate, lockstep and cache RAMs ibex_top adds.
//
// boot_addr is 0: the vector table sits at 0x0000_0000 and the first
// instruction is fetched from 0x0000_0080.
//
// The instruction and data ports keep Ibex's request/grant/valid protocol;
// obi2axi turns each into an AXI4 master port.
// -----------------------------------------------------------------------------

module cpu_ibex (
  input  wire          clk,
  input  wire          rst_n,

  output logic         instr_req,
  input  wire          instr_gnt,
  input  wire          instr_rvalid,
  output logic [31:0]  instr_addr,
  input  wire  [31:0]  instr_rdata,
  input  wire          instr_err,

  output logic         data_req,
  input  wire          data_gnt,
  input  wire          data_rvalid,
  output logic         data_we,
  output logic [3:0]   data_be,
  output logic [31:0]  data_addr,
  output logic [31:0]  data_wdata,
  input  wire  [31:0]  data_rdata,
  input  wire          data_err,

  input  wire          irq_timer,
  input  wire          irq_external,

  output logic         core_busy,
  output logic         double_fault
);

  import ibex_pkg::*;

  logic [4:0]  rf_raddr_a, rf_raddr_b, rf_waddr;
  logic        rf_we;
  logic [31:0] rf_wdata, rf_rdata_a, rf_rdata_b;

  // Instruction cache ports: unused with ICache = 0.
  logic [IC_TAG_SIZE-1:0]  ic_tag_rdata  [IC_NUM_WAYS];
  logic [IC_LINE_SIZE-1:0] ic_data_rdata [IC_NUM_WAYS];
  assign ic_tag_rdata  = '{default: '0};
  assign ic_data_rdata = '{default: '0};

  ibex_mubi_t core_busy_mubi;
  assign core_busy = (core_busy_mubi != IbexMuBiOff);

  /* verilator lint_off PINCONNECTEMPTY */
  ibex_core #(
    .PMPEnable         (1'b0),
    .RV32E             (1'b0),
    .RV32M             (RV32MFast),
    .RV32B             (RV32BNone),
    .BranchTargetALU   (1'b0),
    .WritebackStage    (1'b0),
    .ICache            (1'b0),
    .BranchPredictor   (1'b0),
    .DbgTriggerEn      (1'b0),
    .SecureIbex        (1'b0),
    .DummyInstructions (1'b0),
    .RegFileECC        (1'b0),
    .MemECC            (1'b0)
  ) u_ibex_core (
    .clk_i                  (clk),
    .rst_ni                 (rst_n),
    .hart_id_i              (32'd0),
    .boot_addr_i            (32'd0),

    .instr_req_o            (instr_req),
    .instr_gnt_i            (instr_gnt),
    .instr_rvalid_i         (instr_rvalid),
    .instr_addr_o           (instr_addr),
    .instr_rdata_i          (instr_rdata),
    .instr_err_i            (instr_err),

    .data_req_o             (data_req),
    .data_gnt_i             (data_gnt),
    .data_rvalid_i          (data_rvalid),
    .data_we_o              (data_we),
    .data_be_o              (data_be),
    .data_addr_o            (data_addr),
    .data_wdata_o           (data_wdata),
    .data_rdata_i           (data_rdata),
    .data_err_i             (data_err),

    .dummy_instr_id_o       (),
    .dummy_instr_wb_o       (),
    .rf_raddr_a_o           (rf_raddr_a),
    .rf_raddr_b_o           (rf_raddr_b),
    .rf_waddr_wb_o          (rf_waddr),
    .rf_we_wb_o             (rf_we),
    .rf_wdata_wb_ecc_o      (rf_wdata),
    .rf_rdata_a_ecc_i       (rf_rdata_a),
    .rf_rdata_b_ecc_i       (rf_rdata_b),

    .ic_tag_req_o           (),
    .ic_tag_write_o         (),
    .ic_tag_addr_o          (),
    .ic_tag_wdata_o         (),
    .ic_tag_rdata_i         (ic_tag_rdata),
    .ic_data_req_o          (),
    .ic_data_write_o        (),
    .ic_data_addr_o         (),
    .ic_data_wdata_o        (),
    .ic_data_rdata_i        (ic_data_rdata),
    .ic_scr_key_valid_i     (1'b0),
    .ic_scr_key_req_o       (),

    .irq_software_i         (1'b0),
    .irq_timer_i            (irq_timer),
    .irq_external_i         (irq_external),
    .irq_fast_i             (15'd0),
    .irq_nm_i               (1'b0),
    .irq_pending_o          (),

    .debug_req_i            (1'b0),
    .crash_dump_o           (),
    .double_fault_seen_o    (double_fault),

    .fetch_enable_i         (IbexMuBiOn),
    .alert_minor_o          (),
    .alert_major_internal_o (),
    .alert_major_bus_o      (),
    .core_busy_o            (core_busy_mubi)
  );

  ibex_register_file_ff #(
    .RV32E             (1'b0),
    .DataWidth         (32),
    .DummyInstructions (1'b0),
    .WrenCheck         (1'b0),
    .RdataMuxCheck     (1'b0),
    .WordZeroVal       (32'h0)
  ) u_rf (
    .clk_i             (clk),
    .rst_ni            (rst_n),
    .test_en_i         (1'b0),
    .dummy_instr_id_i  (1'b0),
    .dummy_instr_wb_i  (1'b0),
    .raddr_a_i         (rf_raddr_a),
    .rdata_a_o         (rf_rdata_a),
    .raddr_b_i         (rf_raddr_b),
    .rdata_b_o         (rf_rdata_b),
    .waddr_a_i         (rf_waddr),
    .wdata_a_i         (rf_wdata),
    .we_a_i            (rf_we),
    .err_o             ()
  );
  /* verilator lint_on PINCONNECTEMPTY */

endmodule : cpu_ibex

`default_nettype wire
