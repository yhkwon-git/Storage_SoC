// tb_cdc_async_fifo
//
// Drives cdc_async_fifo at one pair of clock periods and checks every popped
// word against a reference queue. It also checks that the FIFO never holds
// more than DEPTH words, and measures throughput.
//
// Plusargs:
//   +wr_ps= +rd_ps=        clock periods in ps (default 10000, 8000)
//   +rd_off_ps=            delay before rd_clk starts, in ps (default 0)
//   +words=                words to move (default 20000)
//   +push_pct= +pop_pct=   chance per clock of wr_en and rd_en (100 = always)
//   +min_eff=              fail if throughput is below this percent of the
//                          bound (0 = report only)
// Seed: +verilator+seed+N.
//
// The bound is the lower of what the writer offers and what the reader takes,
// in words per rd_clk: min(1, pop_pct/100, push_pct/100 * rd_ps/wr_ps).

`timescale 1ps/1ps

module tb_cdc_async_fifo;

  localparam int WIDTH = 32;
  localparam int DEPTH = 16;

  int unsigned wr_ps     = 10000;
  int unsigned rd_ps     = 8000;
  int unsigned rd_off_ps = 0;
  int unsigned words     = 20000;
  int unsigned push_pct  = 70;
  int unsigned pop_pct   = 70;
  int unsigned min_eff   = 0;

  logic             wr_clk   = 1'b0;
  logic             rd_clk   = 1'b0;
  logic             wr_rst_n = 1'b0;
  logic             rd_rst_n = 1'b0;
  logic             wr_en    = 1'b0;
  logic             rd_en    = 1'b0;
  logic [WIDTH-1:0] wr_data  = '0;
  wire  [WIDTH-1:0] rd_data;
  wire              wr_full;
  wire              rd_empty;

  cdc_async_fifo #(.WIDTH(WIDTH), .DEPTH(DEPTH)) dut (
    .wr_clk   (wr_clk),
    .wr_rst_n (wr_rst_n),
    .wr_en    (wr_en),
    .wr_data  (wr_data),
    .wr_full  (wr_full),
    .rd_clk   (rd_clk),
    .rd_rst_n (rd_rst_n),
    .rd_en    (rd_en),
    .rd_data  (rd_data),
    .rd_empty (rd_empty)
  );

  logic [WIDTH-1:0] model[$];
  int unsigned      pushed    = 0;
  int unsigned      popped    = 0;
  int unsigned      errors    = 0;
  int unsigned      max_level = 0;
  longint unsigned  rd_cycles = 0;
  longint unsigned  first_pop = 0;
  longint unsigned  last_pop  = 0;

  initial begin
    void'($value$plusargs("wr_ps=%d", wr_ps));
    void'($value$plusargs("rd_ps=%d", rd_ps));
    void'($value$plusargs("rd_off_ps=%d", rd_off_ps));
    void'($value$plusargs("words=%d", words));
    void'($value$plusargs("push_pct=%d", push_pct));
    void'($value$plusargs("pop_pct=%d", pop_pct));
    void'($value$plusargs("min_eff=%d", min_eff));
    fork
      forever #(wr_ps / 2) wr_clk = ~wr_clk;
      begin
        if (rd_off_ps != 0) #(rd_off_ps);
        forever #(rd_ps / 2) rd_clk = ~rd_clk;
      end
      begin
        repeat (4) @(posedge wr_clk);
        wr_rst_n <= 1'b1;
      end
      begin
        repeat (4) @(posedge rd_clk);
        rd_rst_n <= 1'b1;
      end
    join_none
  end

  // Writer: count a word when the FIFO accepts it, then pick the next one.
  always @(posedge wr_clk) begin
    if (wr_rst_n) begin
      if (wr_en && !wr_full) begin
        model.push_back(wr_data);
        pushed++;
        if (model.size() > max_level) max_level = model.size();
        if (model.size() > DEPTH) begin
          errors++;
          $display("[FIFO] ERROR write accepted with %0d words already held", model.size() - 1);
        end
      end
      wr_en   <= (pushed < words) && ($urandom_range(99) < push_pct);
      wr_data <= $urandom();
    end
  end

  // Reader: compare each popped word with the oldest one written.
  always @(posedge rd_clk) begin
    if (rd_rst_n) begin
      rd_cycles++;
      if (rd_en && !rd_empty) begin
        if (model.size() == 0) begin
          errors++;
          $display("[FIFO] ERROR pop while nothing was written");
        end else begin
          logic [WIDTH-1:0] exp;
          exp = model.pop_front();
          if (rd_data !== exp) begin
            errors++;
            if (errors <= 5)
              $display("[FIFO] ERROR word %0d: read %h, expected %h", popped, rd_data, exp);
          end
        end
        popped++;
        if (popped == 1) first_pop = rd_cycles;
        last_pop = rd_cycles;
      end
      rd_en <= ($urandom_range(99) < pop_pct);
    end
  end

  initial begin
    real tput, bound, offer, eff;
    longint unsigned limit;
    #1;
    limit = longint'(words) * longint'((wr_ps > rd_ps) ? 64'(wr_ps) : 64'(rd_ps)) * 40;
    fork
      wait (popped >= words);
      begin
        #(limit);
        $display("[FIFO] ERROR timeout: %0d of %0d words read", popped, words);
        errors++;
      end
    join_any
    disable fork;

    tput  = (popped > 1 && last_pop > first_pop) ?
            real'(popped - 1) / real'(last_pop - first_pop) : 0.0;
    offer = (real'(push_pct) / 100.0) * (real'(rd_ps) / real'(wr_ps));
    bound = real'(pop_pct) / 100.0;
    if (offer < bound) bound = offer;
    if (bound > 1.0)   bound = 1.0;
    eff   = (bound > 0.0) ? 100.0 * tput / bound : 0.0;

    $display("[FIFO] wr %0d ps, rd %0d ps, push %0d%%, pop %0d%%: words %0d, errors %0d, max level %0d/%0d, %.3f words per rd clock, bound %.3f, %.1f%%",
             wr_ps, rd_ps, push_pct, pop_pct, popped, errors, max_level, DEPTH,
             tput, bound, eff);

    if (errors != 0 || popped != words || model.size() != 0 ||
        (min_eff != 0 && eff < real'(min_eff))) begin
      $fatal(1, "[FIFO] FAIL");
    end
    $display("[FIFO] PASS");
    $finish;
  end

endmodule
