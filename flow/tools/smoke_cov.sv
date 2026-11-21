// Toolchain check, Verilator side: covergroup with coverpoints and a cross.
// Every bin is written to coverage.dat (page v_covergroup) with its hit count,
// and the script checks that all 14 were hit. In version 5.052 get_coverage()
// on a single coverpoint does not compile and the covergroup total reads 0.0
// at run time, so coverage numbers come from coverage.dat, not from the TB.
module smoke_cov;
  logic       clk = 1'b0;
  logic [1:0] a;
  logic [2:0] b;

  // -Wall flags members the tool adds to every covergroup (option,
  // type_option, total_bins, ...), so lint is relaxed for this block only.
  /* verilator lint_off UNUSEDSIGNAL */
  /* verilator lint_off UNDRIVEN */
  covergroup cg @(posedge clk);
    cp_a: coverpoint a { bins v[] = {[0:3]}; }
    cp_b: coverpoint b { bins lo = {[0:3]}; bins hi = {[4:7]}; }
    x_ab: cross cp_a, cp_b;
  endgroup
  /* verilator lint_on UNDRIVEN */
  /* verilator lint_on UNUSEDSIGNAL */

  cg c = new;

  initial begin
    repeat (200) begin
      a = 2'($urandom);
      b = 3'($urandom);
      #1 clk = 1'b1;
      #1 clk = 1'b0;
    end
    $display("[SMOKE] covergroup total=%0.1f", c.get_coverage());
    $finish;
  end
endmodule
