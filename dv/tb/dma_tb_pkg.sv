// dma_tb_pkg
//
// Memory model for the DMA testbench (tb_dma.sv): one AXI4 slave holding
// bytes.
//   * AW, W and AR READY are random (awready_pct, wready_pct, arready_pct).
//   * W is accepted only after its AW, one clock later at the earliest, as the
//     crossbar does.
//   * B and R come back after a random latency. They stay in order within an
//     ID; across the DMA's two read IDs the model picks between the oldest
//     ready burst of each at random, so descriptor and data reads reorder.
//   * R beats have random gaps (r_gap_pct).
//   * Reads of beats inside rd_err ranges answer that range's response; a
//     write burst touching a wr_err range answers its response and writes
//     none of its beats there.
//   * Every AR and AW is checked: INCR, 64-bit beats, 8-byte aligned, at most
//     16 beats; WLAST is checked against AWLEN.
//
// Drivers change signals after the falling edge, and everything is sampled on
// the rising edge, as in axi_tb_pkg.

`timescale 1ns/1ps

package dma_tb_pkg;

  localparam logic [1:0] OKAY   = 2'b00;
  localparam logic [1:0] SLVERR = 2'b10;
  localparam logic [1:0] DECERR = 2'b11;

  // Contents of a byte nobody has written.
  function automatic logic [7:0] init_byte(logic [31:0] a);
    return a[7:0] ^ a[15:8] ^ a[23:16] ^ 8'hA5;
  endfunction

  typedef struct {
    logic [3:0]  id;
    logic [31:0] addr;
    int          len;      // beats - 1
    int          beat;
    longint      ready_at;
    logic [1:0]  resp;
  } req_t;

  typedef struct {
    logic [31:0] lo;
    logic [31:0] hi;       // exclusive
    logic [1:0]  resp;
  } range_t;

  class mem_slave;
    virtual axi4_if vif;
    longint         clk_period = 10;

    int awready_pct = 70;
    int wready_pct  = 70;
    int arready_pct = 70;
    int r_gap_pct   = 20;
    int r_lat_min   = 0;
    int r_lat_max   = 6;
    int b_lat_min   = 0;
    int b_lat_max   = 4;

    logic [7:0] mem [logic [31:0]];
    range_t     rd_err[$];
    range_t     wr_err[$];

    req_t aw_q[$];
    req_t b_q[$];
    req_t r_q[$];
    req_t cur_r;
    bit   r_busy;
    bit   b_acc, r_acc;

    int errors;
    int n_ar, n_aw, n_w, n_r, n_b;
    int out_rd, out_wr, max_out_rd, max_out_wr;

    function new(virtual axi4_if v);
      vif = v;
    endfunction

    function void err(string s);
      errors++;
      if (errors <= 10) $display("[DMA] ERROR memory model at %0t: %s", $time, s);
    endfunction

    function void clear();
      mem.delete();
      rd_err.delete();
      wr_err.delete();
    endfunction

    // Request counts per run; the outstanding maxima cover the whole test.
    function void clear_stats();
      n_ar = 0; n_aw = 0; n_w = 0; n_r = 0; n_b = 0;
    endfunction

    function void set_speed(int ready_pct, int lat_max, int gap_pct);
      awready_pct = ready_pct; wready_pct = ready_pct; arready_pct = ready_pct;
      r_lat_min = 0; b_lat_min = 0;
      r_lat_max = lat_max; b_lat_max = lat_max;
      r_gap_pct = gap_pct;
    endfunction

    function logic [7:0] get(logic [31:0] a);
      return mem.exists(a) ? mem[a] : init_byte(a);
    endfunction

    function logic [63:0] read_word(logic [31:0] a);
      logic [63:0] w;
      for (int i = 0; i < 8; i++) w[i*8 +: 8] = get(a + 32'(i));
      return w;
    endfunction

    function logic [1:0] resp_at(range_t q[$], logic [31:0] lo, logic [31:0] hi);
      foreach (q[i]) if (lo < q[i].hi && q[i].lo < hi) return q[i].resp;
      return OKAY;
    endfunction

    function longint after(int lo, int hi);
      return $time + clk_period * longint'($urandom_range(hi, lo));
    endfunction

    function void check_req(string ch, logic [31:0] addr, logic [7:0] len, logic [2:0] size,
                            logic [1:0] burst);
      if (size != 3'd3)        err($sformatf("%s size %0d, expected 3", ch, size));
      if (burst != 2'b01)      err($sformatf("%s burst type %0d, expected INCR", ch, burst));
      if (addr[2:0] != 3'd0)   err($sformatf("%s address %h not 8-byte aligned", ch, addr));
      if (len > 8'd15)         err($sformatf("%s of %0d beats", ch, len + 1));
    endfunction

    task run();
      vif.awready = 1'b0;
      vif.wready  = 1'b0;
      vif.arready = 1'b0;
      vif.bvalid  = 1'b0;
      vif.rvalid  = 1'b0;
      vif.bid     = 4'd0;
      vif.bresp   = OKAY;
      vif.rid     = 4'd0;
      vif.rdata   = 64'd0;
      vif.rresp   = OKAY;
      vif.rlast   = 1'b0;
      fork
        sampler();
        drive();
      join_none
    endtask

    task sampler();
      req_t r;
      logic [31:0] w;
      forever begin
        @(posedge vif.clk);
        b_acc = vif.bvalid && vif.bready;
        r_acc = vif.rvalid && vif.rready;
        if (r_acc) begin
          n_r++;
          if (vif.rlast) out_rd--;
        end
        if (b_acc) begin
          n_b++;
          out_wr--;
        end
        if (vif.awvalid && vif.awready) begin
          check_req("AW", vif.awaddr, vif.awlen, vif.awsize, vif.awburst);
          r.id = vif.awid; r.addr = vif.awaddr; r.len = int'(vif.awlen); r.beat = 0;
          r.ready_at = 0;
          r.resp = resp_at(wr_err, vif.awaddr, vif.awaddr + 32'((r.len + 1) * 8));
          aw_q.push_back(r);
          n_aw++;
          out_wr++;
          if (out_wr > max_out_wr) max_out_wr = out_wr;
        end
        if (vif.wvalid && vif.wready) begin
          n_w++;
          if (aw_q.size() == 0) begin
            err("W beat accepted with no AW");
          end else begin
            w = aw_q[0].addr + 32'(aw_q[0].beat * 8);
            if (aw_q[0].resp == OKAY) begin
              for (int i = 0; i < 8; i++) if (vif.wstrb[i]) mem[w + 32'(i)] = vif.wdata[i*8 +: 8];
            end
            if (vif.wlast != (aw_q[0].beat == aw_q[0].len)) begin
              err($sformatf("WLAST %0d on beat %0d of a %0d-beat write", vif.wlast,
                            aw_q[0].beat, aw_q[0].len + 1));
            end
            aw_q[0].beat++;
            if (vif.wlast || aw_q[0].beat > aw_q[0].len) begin
              r = aw_q.pop_front();
              r.ready_at = after(b_lat_min, b_lat_max);
              b_q.push_back(r);
            end
          end
        end
        if (vif.arvalid && vif.arready) begin
          check_req("AR", vif.araddr, vif.arlen, vif.arsize, vif.arburst);
          r.id = vif.arid; r.addr = vif.araddr; r.len = int'(vif.arlen); r.beat = 0;
          r.ready_at = after(r_lat_min, r_lat_max);
          r.resp = OKAY;
          r_q.push_back(r);
          n_ar++;
          out_rd++;
          if (out_rd > max_out_rd) max_out_rd = out_rd;
        end
      end
    endtask

    // Oldest ready read of a random ID.
    function int pick_r();
      int  cand[$];
      bit  older;
      for (int i = 0; i < r_q.size(); i++) begin
        older = 1'b0;
        for (int j = 0; j < i; j++) if (r_q[j].id == r_q[i].id) older = 1'b1;
        if (!older && r_q[i].ready_at <= $time) cand.push_back(i);
      end
      if (cand.size() == 0) return -1;
      return cand[$urandom_range(cand.size() - 1)];
    endfunction

    task drive();
      int          i;
      logic [31:0] a;
      forever begin
        @(negedge vif.clk);
        vif.awready = ($urandom_range(99) < awready_pct);
        vif.wready  = (aw_q.size() > 0) && ($urandom_range(99) < wready_pct);
        vif.arready = ($urandom_range(99) < arready_pct);

        if (!(vif.bvalid && !b_acc)) begin
          vif.bvalid = 1'b0;
          if (b_q.size() > 0 && b_q[0].ready_at <= $time) begin
            vif.bid    = b_q[0].id;
            vif.bresp  = b_q[0].resp;
            vif.bvalid = 1'b1;
            void'(b_q.pop_front());
          end
        end

        if (!(vif.rvalid && !r_acc)) begin
          if (vif.rvalid && r_acc) begin
            if (cur_r.beat == cur_r.len) r_busy = 1'b0;
            else                         cur_r.beat++;
          end
          vif.rvalid = 1'b0;
          if (!r_busy) begin
            i = pick_r();
            if (i >= 0) begin
              cur_r  = r_q[i];
              r_q.delete(i);
              r_busy = 1'b1;
            end
          end
          if (r_busy && !($urandom_range(99) < r_gap_pct)) begin
            a          = cur_r.addr + 32'(cur_r.beat * 8);
            vif.rid    = cur_r.id;
            vif.rdata  = read_word(a);
            vif.rresp  = resp_at(rd_err, a, a + 32'd8);
            vif.rlast  = (cur_r.beat == cur_r.len);
            vif.rvalid = 1'b1;
          end
        end
      end
    endtask

    function bit idle();
      return aw_q.size() == 0 && b_q.size() == 0 && r_q.size() == 0 && !r_busy &&
             !vif.bvalid && !vif.rvalid && out_rd == 0 && out_wr == 0;
    endfunction
  endclass

endpackage
