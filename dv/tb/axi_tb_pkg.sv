// axi_tb_pkg
//
// Classes for the crossbar testbench.
//   axi_txn     one burst, with the target the address should decode to
//   axi_master  drives one master port, keeps a shadow of what it wrote, and
//               checks every B and R: ID, order per ID, response, data, RLAST,
//               no interleaving of read bursts
//   axi_slave   memory behind one slave port; checks the address window, the
//               master/slave path, W order and WLAST; returns B and R after a
//               random latency and, when reorder is set, in a random order
//               across different IDs (never within one ID)
//
// Drivers change signals after the falling edge; everything is sampled on the
// rising edge, the same scheme as the Mini_DRAM_Controller testbench.

`timescale 1ns/1ps

package axi_tb_pkg;

  localparam int NM    = 4;
  localparam int NS    = 5;
  localparam int T_ERR = NS;

  localparam logic [1:0] OKAY   = 2'b00;
  localparam logic [1:0] DECERR = 2'b11;

  // Same map and paths as the axi_xbar defaults.
  localparam logic [31:0] SLV_BASE [NS] = '{32'h0000_0000, 32'h1000_0000, 32'h4000_0000,
                                            32'h3000_0000, 32'h3001_0000};
  localparam logic [31:0] SLV_MASK [NS] = '{32'hFFFF_C000, 32'hFFFF_0000, 32'hFFFF_0000,
                                            32'hFFFF_F000, 32'hFFFF_F000};
  localparam logic [4:0]  CONN     [NM] = '{5'b00011, 5'b11111, 5'b11010, 5'b00110};

  // Addresses no slave owns.
  localparam logic [31:0] UNMAPPED [7] = '{32'h0000_4000, 32'h1001_0000, 32'h2000_0000,
                                           32'h3000_1000, 32'h3002_0000, 32'h5000_0000,
                                           32'hF000_0000};

  function automatic string tgt_name(int t);
    case (t)
      0:       return "ROM";
      1:       return "SRAM";
      2:       return "APB";
      3:       return "NAND0";
      4:       return "NAND1";
      default: return "DECERR";
    endcase
  endfunction

  function automatic int decode(int m, logic [31:0] a);
    for (int s = 0; s < NS; s++) begin
      if (CONN[m][s] && ((a & SLV_MASK[s]) == SLV_BASE[s])) return s;
    end
    return T_ERR;
  endfunction

  // Contents of a word nobody has written.
  function automatic logic [63:0] init_word(logic [31:0] a);
    return {a ^ 32'h5A5A_0000, ~a};
  endfunction

  function automatic logic [63:0] merge(logic [63:0] old, logic [63:0] nw, logic [7:0] strb);
    logic [63:0] r;
    r = old;
    for (int i = 0; i < 8; i++) begin
      if (strb[i]) r[i*8 +: 8] = nw[i*8 +: 8];
    end
    return r;
  endfunction

  // Each master gets its own quarter of every slave window, so writes from
  // different masters never race on one word.
  function automatic logic [31:0] region_size(int s);
    return (~SLV_MASK[s] + 32'd1) >> 2;
  endfunction

  function automatic logic [31:0] region_base(int m, int s);
    return SLV_BASE[s] + 32'(m) * region_size(s);
  endfunction

  // ---------------------------------------------------------------------------
  class axi_txn;
    bit          write;
    int          master;
    logic [3:0]  id;
    logic [31:0] addr;
    int          len;
    logic [63:0] data[$];
    logic [7:0]  strb[$];
    int          tgt;
    int          beat;
    longint      t_req;
    longint      t_acc;
    longint      t_done;
  endclass

  // ---------------------------------------------------------------------------
  class axi_master;
    virtual axi4_if vif;
    int             idx;

    // Knobs: percent chance per clock.
    int aw_gap_pct = 30;
    int w_gap_pct  = 20;
    int ar_gap_pct = 30;
    int bready_pct = 80;
    int rready_pct = 80;

    axi_txn aw_q[$];
    axi_txn w_q[$];
    axi_txn ar_q[$];
    axi_txn cur_aw;
    axi_txn cur_w;
    axi_txn cur_ar;
    int     w_beat;
    bit     aw_acc, w_acc, ar_acc;

    axi_txn wr_out[16][$];
    axi_txn rd_out[16][$];

    logic [63:0] shadow  [logic [31:0]];
    int          wr_busy [logic [31:0]];
    int          rd_busy [logic [31:0]];

    bit         in_rburst;
    logic [3:0] cur_rid;

    int     errors;
    int     n_sent, n_done, n_decerr;
    int     n_wr_done, n_rd_done;
    longint lat_sum;

    function new(virtual axi4_if v, int i);
      vif = v;
      idx = i;
    endfunction

    function void err(string s);
      errors++;
      if (errors <= 10) $display("[XBAR] ERROR M%0d at %0t: %s", idx, $time, s);
    endfunction

    function logic [63:0] expect_word(logic [31:0] w);
      return shadow.exists(w) ? shadow[w] : init_word(w);
    endfunction

    // True if no in-flight transaction conflicts with a burst at a.
    function bit words_free(logic [31:0] a, int len, bit write);
      logic [31:0] w;
      for (int b = 0; b <= len; b++) begin
        w = a + 32'(b * 8);
        if (wr_busy.exists(w) && wr_busy[w] != 0) return 1'b0;
        if (write && rd_busy.exists(w) && rd_busy[w] != 0) return 1'b0;
      end
      return 1'b1;
    endfunction

    function void mark(axi_txn t, int delta);
      logic [31:0] w;
      if (t.tgt == T_ERR) return;
      for (int b = 0; b <= t.len; b++) begin
        w = t.addr + 32'(b * 8);
        if (t.write) wr_busy[w] = (wr_busy.exists(w) ? wr_busy[w] : 0) + delta;
        else         rd_busy[w] = (rd_busy.exists(w) ? rd_busy[w] : 0) + delta;
      end
    endfunction

    function void send(axi_txn t);
      t.master = idx;
      t.beat   = 0;
      mark(t, 1);
      n_sent++;
      if (t.write) begin
        aw_q.push_back(t);
        w_q.push_back(t);
      end else begin
        ar_q.push_back(t);
      end
    endfunction

    function int pending();
      return n_sent - n_done;
    endfunction

    task run();
      vif.awvalid = 1'b0;
      vif.wvalid  = 1'b0;
      vif.arvalid = 1'b0;
      vif.bready  = 1'b0;
      vif.rready  = 1'b0;
      fork
        sampler();
        drive_aw();
        drive_w();
        drive_ar();
        drive_ready();
      join_none
    endtask

    task sampler();
      forever begin
        @(posedge vif.clk);
        aw_acc = vif.awvalid && vif.awready;
        w_acc  = vif.wvalid && vif.wready;
        ar_acc = vif.arvalid && vif.arready;
        if (aw_acc) begin
          cur_aw.t_acc = $time;
          wr_out[cur_aw.id].push_back(cur_aw);
        end
        if (ar_acc) begin
          cur_ar.t_acc = $time;
          rd_out[cur_ar.id].push_back(cur_ar);
        end
        if (vif.bvalid && vif.bready) on_b(vif.bid, vif.bresp);
        if (vif.rvalid && vif.rready) on_r(vif.rid, vif.rdata, vif.rresp, vif.rlast);
      end
    endtask

    task drive_aw();
      forever begin
        @(negedge vif.clk);
        if (vif.awvalid && !aw_acc) continue;
        if (aw_q.size() == 0 || ($urandom_range(99) < aw_gap_pct)) begin
          vif.awvalid = 1'b0;
        end else begin
          cur_aw       = aw_q.pop_front();
          cur_aw.t_req = $time;
          vif.awid     = cur_aw.id;
          vif.awaddr   = cur_aw.addr;
          vif.awlen    = 8'(cur_aw.len);
          vif.awsize   = 3'd3;
          vif.awburst  = 2'b01;
          vif.awprot   = 3'($urandom());
          vif.awcache  = 4'($urandom());
          vif.awqos    = 4'($urandom());
          vif.awvalid  = 1'b1;
        end
      end
    endtask

    task drive_ar();
      forever begin
        @(negedge vif.clk);
        if (vif.arvalid && !ar_acc) continue;
        if (ar_q.size() == 0 || ($urandom_range(99) < ar_gap_pct)) begin
          vif.arvalid = 1'b0;
        end else begin
          cur_ar       = ar_q.pop_front();
          cur_ar.t_req = $time;
          vif.arid     = cur_ar.id;
          vif.araddr   = cur_ar.addr;
          vif.arlen    = 8'(cur_ar.len);
          vif.arsize   = 3'd3;
          vif.arburst  = 2'b01;
          vif.arprot   = 3'($urandom());
          vif.arcache  = 4'($urandom());
          vif.arqos    = 4'($urandom());
          vif.arvalid  = 1'b1;
        end
      end
    endtask

    // W beats follow the order the writes were queued in, which is AW order.
    // They may be offered before their AW is accepted.
    task drive_w();
      forever begin
        @(negedge vif.clk);
        if (vif.wvalid && !w_acc) continue;
        if (vif.wvalid && w_acc) begin
          if (w_beat == cur_w.len) cur_w = null;
          else                     w_beat++;
        end
        if (cur_w == null && w_q.size() != 0) begin
          cur_w  = w_q.pop_front();
          w_beat = 0;
        end
        if (cur_w == null || ($urandom_range(99) < w_gap_pct)) begin
          vif.wvalid = 1'b0;
        end else begin
          vif.wdata  = cur_w.data[w_beat];
          vif.wstrb  = cur_w.strb[w_beat];
          vif.wlast  = (w_beat == cur_w.len);
          vif.wvalid = 1'b1;
        end
      end
    endtask

    task drive_ready();
      forever begin
        @(negedge vif.clk);
        vif.bready = ($urandom_range(99) < bready_pct);
        vif.rready = ($urandom_range(99) < rready_pct);
      end
    endtask

    function void on_b(logic [3:0] bid, logic [1:0] bresp);
      axi_txn     t;
      logic [1:0] exp;
      logic [31:0] w;
      if (bid[3:2] != 2'b00) err($sformatf("BID %h has upper bits set", bid));
      if (wr_out[bid].size() == 0) begin
        err($sformatf("B with ID %0d and no write outstanding", bid));
        return;
      end
      t   = wr_out[bid].pop_front();
      exp = (t.tgt == T_ERR) ? DECERR : OKAY;
      if (bresp != exp) begin
        err($sformatf("B for write to %h (%s): resp %0d, expected %0d",
                      t.addr, tgt_name(t.tgt), bresp, exp));
      end
      if (t.tgt != T_ERR) begin
        for (int b = 0; b <= t.len; b++) begin
          w = t.addr + 32'(b * 8);
          shadow[w] = merge(expect_word(w), t.data[b], t.strb[b]);
        end
      end else begin
        n_decerr++;
      end
      mark(t, -1);
      t.t_done = $time;
      lat_sum += t.t_done - t.t_acc;
      n_done++;
      n_wr_done++;
    endfunction

    function void on_r(logic [3:0] rid, logic [63:0] rdata, logic [1:0] rresp, logic rlast);
      axi_txn      t;
      logic [1:0]  exp;
      logic [31:0] w;
      if (rid[3:2] != 2'b00) err($sformatf("RID %h has upper bits set", rid));
      if (in_rburst && rid != cur_rid) begin
        err($sformatf("R for ID %0d inside a burst for ID %0d", rid, cur_rid));
      end
      if (rd_out[rid].size() == 0) begin
        err($sformatf("R with ID %0d and no read outstanding", rid));
        return;
      end
      t   = rd_out[rid][0];
      exp = (t.tgt == T_ERR) ? DECERR : OKAY;
      if (rresp != exp) begin
        err($sformatf("R beat %0d for read of %h (%s): resp %0d, expected %0d",
                      t.beat, t.addr, tgt_name(t.tgt), rresp, exp));
      end
      if (t.tgt != T_ERR) begin
        w = t.addr + 32'(t.beat * 8);
        if (rdata !== expect_word(w)) begin
          err($sformatf("R data at %h: %h, expected %h", w, rdata, expect_word(w)));
        end
      end
      if (rlast != (t.beat == t.len)) begin
        err($sformatf("RLAST %0d on beat %0d of a %0d-beat read", rlast, t.beat, t.len + 1));
      end
      t.beat++;
      if (rlast || t.beat > t.len) begin
        void'(rd_out[rid].pop_front());
        if (t.tgt == T_ERR) n_decerr++;
        mark(t, -1);
        t.t_done = $time;
        lat_sum += t.t_done - t.t_acc;
        n_done++;
        n_rd_done++;
        in_rburst = 1'b0;
      end else begin
        in_rburst = 1'b1;
        cur_rid   = rid;
      end
    endfunction
  endclass

  // ---------------------------------------------------------------------------
  typedef struct {
    logic [3:0]  id;
    logic [31:0] addr;
    int          len;
    int          beat;
    longint      ready_at;
  } req_t;

  class axi_slave;
    virtual axi4_if vif;
    int             idx;
    longint         clk_period = 10;

    // Knobs.
    int awready_pct = 70;
    int wready_pct  = 70;
    int arready_pct = 70;
    int b_lat_min   = 0;
    int b_lat_max   = 4;
    int r_lat_min   = 0;
    int r_lat_max   = 6;
    int r_gap_pct   = 20;
    bit reorder     = 1'b1;

    logic [63:0] mem [logic [31:0]];

    req_t aw_list[$];
    req_t b_list[$];
    req_t r_list[$];
    req_t cur_b;
    req_t cur_r;
    bit   r_busy;
    bit   b_acc, r_acc;

    int     errors;
    int     n_aw, n_ar, n_w;
    int     aw_by_m[NM];
    int     ar_by_m[NM];
    int     out_rd[NM];
    int     out_wr[NM];
    int     max_out_rd[NM];
    int     max_out_wr[NM];
    int     ar_order[$];
    int     n_r;
    longint first_w, last_w;
    longint first_r, last_r;

    function new(virtual axi4_if v, int i);
      vif = v;
      idx = i;
    endfunction

    function void err(string s);
      errors++;
      if (errors <= 10) $display("[XBAR] ERROR S%0d %s at %0t: %s", idx, tgt_name(idx), $time, s);
    endfunction

    function void clear_stats();
      n_aw = 0; n_ar = 0; n_w = 0; n_r = 0;
      first_w = 0; last_w = 0; first_r = 0; last_r = 0;
      ar_order.delete();
      for (int m = 0; m < NM; m++) begin
        aw_by_m[m] = 0; ar_by_m[m] = 0; max_out_rd[m] = 0; max_out_wr[m] = 0;
      end
    endfunction

    function logic [63:0] read_word(logic [31:0] w);
      return mem.exists(w) ? mem[w] : init_word(w);
    endfunction

    function longint after(int lo, int hi);
      return $time + clk_period * longint'($urandom_range(hi, lo));
    endfunction

    function void check_req(string ch, logic [3:0] id, logic [31:0] addr, logic [7:0] len);
      int m;
      m = int'(id[3:2]);
      if (!CONN[m][idx]) err($sformatf("%s from M%0d, which has no path here", ch, m));
      if ((addr & SLV_MASK[idx]) != SLV_BASE[idx]) begin
        err($sformatf("%s address %h is outside this slave", ch, addr));
      end
      if (addr[31:0] + 32'(({24'd0, len} + 1) * 8) > SLV_BASE[idx] + ~SLV_MASK[idx] + 32'd1) begin
        err($sformatf("%s burst at %h, %0d beats, runs past this slave", ch, addr, len + 1));
      end
    endfunction

    task run();
      vif.awready = 1'b0;
      vif.wready  = 1'b0;
      vif.arready = 1'b0;
      vif.bvalid  = 1'b0;
      vif.rvalid  = 1'b0;
      fork
        sampler();
        drive();
      join_none
    endtask

    task sampler();
      req_t r;
      int   m;
      logic [31:0] w;
      forever begin
        @(posedge vif.clk);
        b_acc = vif.bvalid && vif.bready;
        r_acc = vif.rvalid && vif.rready;
        if (r_acc) begin
          n_r++;
          if (first_r == 0) first_r = $time;
          last_r = $time;
        end
        if (vif.awvalid && vif.awready) begin
          check_req("AW", vif.awid, vif.awaddr, vif.awlen);
          r.id = vif.awid; r.addr = vif.awaddr; r.len = int'(vif.awlen); r.beat = 0; r.ready_at = 0;
          aw_list.push_back(r);
          m = int'(vif.awid[3:2]);
          n_aw++;
          aw_by_m[m]++;
          out_wr[m]++;
          if (out_wr[m] > max_out_wr[m]) max_out_wr[m] = out_wr[m];
        end
        if (vif.wvalid && vif.wready) begin
          n_w++;
          if (first_w == 0) first_w = $time;
          last_w = $time;
          if (aw_list.size() == 0) begin
            err("W beat arrived before its AW");
          end else begin
            w = aw_list[0].addr + 32'(aw_list[0].beat * 8);
            mem[w] = merge(read_word(w), vif.wdata, vif.wstrb);
            if (vif.wlast != (aw_list[0].beat == aw_list[0].len)) begin
              err($sformatf("WLAST %0d on beat %0d of a %0d-beat write", vif.wlast,
                            aw_list[0].beat, aw_list[0].len + 1));
            end
            aw_list[0].beat++;
            if (vif.wlast || aw_list[0].beat > aw_list[0].len) begin
              r = aw_list.pop_front();
              r.ready_at = after(b_lat_min, b_lat_max);
              b_list.push_back(r);
            end
          end
        end
        if (b_acc) begin
          out_wr[int'(cur_b.id[3:2])]--;
        end
        if (vif.arvalid && vif.arready) begin
          check_req("AR", vif.arid, vif.araddr, vif.arlen);
          r.id = vif.arid; r.addr = vif.araddr; r.len = int'(vif.arlen); r.beat = 0;
          r.ready_at = after(r_lat_min, r_lat_max);
          r_list.push_back(r);
          m = int'(vif.arid[3:2]);
          n_ar++;
          ar_by_m[m]++;
          ar_order.push_back(m);
          out_rd[m]++;
          if (out_rd[m] > max_out_rd[m]) max_out_rd[m] = out_rd[m];
        end
      end
    endtask

    // Next response: the oldest of its ID, ready by now. In reorder mode a
    // random one of those; otherwise only the oldest of all.
    function int pick_b();
      int  cand[$];
      bit  older;
      for (int i = 0; i < b_list.size(); i++) begin
        older = 1'b0;
        for (int j = 0; j < i; j++) if (b_list[j].id == b_list[i].id) older = 1'b1;
        if (!older && b_list[i].ready_at <= $time) cand.push_back(i);
        if (!reorder) break;
      end
      if (cand.size() == 0) return -1;
      return reorder ? cand[$urandom_range(cand.size() - 1)] : cand[0];
    endfunction

    function int pick_r();
      int  cand[$];
      bit  older;
      for (int i = 0; i < r_list.size(); i++) begin
        older = 1'b0;
        for (int j = 0; j < i; j++) if (r_list[j].id == r_list[i].id) older = 1'b1;
        if (!older && r_list[i].ready_at <= $time) cand.push_back(i);
        if (!reorder) break;
      end
      if (cand.size() == 0) return -1;
      return reorder ? cand[$urandom_range(cand.size() - 1)] : cand[0];
    endfunction

    task drive();
      int i;
      forever begin
        @(negedge vif.clk);
        vif.awready = ($urandom_range(99) < awready_pct);
        vif.wready  = ($urandom_range(99) < wready_pct);
        vif.arready = ($urandom_range(99) < arready_pct);

        // B: hold until taken, then offer the next.
        if (!(vif.bvalid && !b_acc)) begin
          vif.bvalid = 1'b0;
          i = pick_b();
          if (i >= 0) begin
            cur_b = b_list[i];
            b_list.delete(i);
            vif.bid    = cur_b.id;
            vif.bresp  = OKAY;
            vif.bvalid = 1'b1;
          end
        end

        // R: one whole burst at a time, with random gaps between beats.
        if (!(vif.rvalid && !r_acc)) begin
          if (vif.rvalid && r_acc) begin
            if (cur_r.beat == cur_r.len) begin
              r_busy = 1'b0;
              out_rd[int'(cur_r.id[3:2])]--;
            end else begin
              cur_r.beat++;
            end
          end
          vif.rvalid = 1'b0;
          if (!r_busy) begin
            i = pick_r();
            if (i >= 0) begin
              cur_r  = r_list[i];
              r_list.delete(i);
              r_busy = 1'b1;
            end
          end
          if (r_busy && !($urandom_range(99) < r_gap_pct)) begin
            vif.rid    = cur_r.id;
            vif.rdata  = read_word(cur_r.addr + 32'(cur_r.beat * 8));
            vif.rresp  = OKAY;
            vif.rlast  = (cur_r.beat == cur_r.len);
            vif.rvalid = 1'b1;
          end
        end
      end
    endtask

    function bit idle();
      return aw_list.size() == 0 && b_list.size() == 0 && r_list.size() == 0 && !r_busy &&
             !vif.bvalid && !vif.rvalid;
    endfunction
  endclass

endpackage
