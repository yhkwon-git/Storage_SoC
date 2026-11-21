// ral_tb
//
// The three APB blocks behind one APB bus, decoded by slot like the SoC's
// bridge does (paddr[15:12]: 0 SYS, 2 INTC, 3 TIMER; other slots answer
// PSLVERR), driven by the UVM register test in ral_test_pkg.

`timescale 1ns/1ps

module ral_tb;
  import uvm_pkg::*;
  import ral_test_pkg::*;

  logic clk   = 1'b0;
  logic rst_n = 1'b0;
  always #10 clk = ~clk;

  apb_if apb (.pclk(clk), .presetn(rst_n));

  wire [3:0] slot = apb.paddr[15:12];

  logic [31:0] rd_sys, rd_intc, rd_tmr;
  logic        rdy_sys, rdy_intc, rdy_tmr;
  logic        err_sys, err_intc, err_tmr;
  logic        console_valid, exit_valid;
  logic [7:0]  console_char;
  logic [31:0] exit_code;

  apb_sys u_sys (
    .clk (clk), .rst_n (rst_n),
    .psel (apb.psel && slot == 4'd0), .penable (apb.penable), .paddr (apb.paddr[11:0]),
    .pwrite (apb.pwrite), .pwdata (apb.pwdata), .pstrb (apb.pstrb),
    .prdata (rd_sys), .pready (rdy_sys), .pslverr (err_sys),
    .console_valid (console_valid), .console_char (console_char),
    .exit_valid (exit_valid), .exit_code (exit_code)
  );

  apb_intc u_intc (
    .clk (clk), .rst_n (rst_n),
    .psel (apb.psel && slot == 4'd2), .penable (apb.penable), .paddr (apb.paddr[11:0]),
    .pwrite (apb.pwrite), .pwdata (apb.pwdata), .pstrb (apb.pstrb),
    .prdata (rd_intc), .pready (rdy_intc), .pslverr (err_intc),
    .src (32'd0), .irq (apb.irq_external)
  );

  apb_timer u_tmr (
    .clk (clk), .rst_n (rst_n),
    .psel (apb.psel && slot == 4'd3), .penable (apb.penable), .paddr (apb.paddr[11:0]),
    .pwrite (apb.pwrite), .pwdata (apb.pwdata), .pstrb (apb.pstrb),
    .prdata (rd_tmr), .pready (rdy_tmr), .pslverr (err_tmr),
    .irq (apb.irq_timer)
  );

  always_comb begin
    case (slot)
      4'd0:    begin apb.prdata = rd_sys;  apb.pready = rdy_sys;  apb.pslverr = err_sys;  end
      4'd2:    begin apb.prdata = rd_intc; apb.pready = rdy_intc; apb.pslverr = err_intc; end
      4'd3:    begin apb.prdata = rd_tmr;  apb.pready = rdy_tmr;  apb.pslverr = err_tmr;  end
      default: begin apb.prdata = 32'd0;   apb.pready = 1'b1;     apb.pslverr = 1'b1;     end
    endcase
  end

  initial begin
    apb.console_events = 0;
    apb.exit_events    = 0;
  end

  always @(posedge clk) begin
    if (console_valid) begin
      apb.console_events++;
      apb.last_char = console_char;
    end
    if (exit_valid) begin
      apb.exit_events++;
      apb.last_code = exit_code;
    end
  end

  initial begin
    uvm_config_db #(virtual apb_if)::set(null, "*", "vif", apb);
    run_test("ral_test");
  end

  initial begin
    repeat (5) @(posedge clk);
    rst_n = 1'b1;
  end
endmodule
