// tlp_tb_pkg
//
// TLP-level host model for the transaction layer (docs/10_transaction_layer.md):
// a root complex with host memory, on the packed streams of tlp_if.
//
// Requester (host to device):
//   cfg_rd / cfg_wr          one DW of configuration space, blocking
//   mem_wr                   posted write of any byte range inside 4 KiB
//   mem_rd / mem_rd_nb       read of any byte range inside 4 KiB; blocking,
//                            or a handle the caller waits on
//   Every completion is checked: completer and requester IDs, tag, status,
//   Byte Count and Lower Address against what is still expected, and the
//   device's split rule (a completion ends at a 128-byte boundary unless it
//   is the last). Data is gathered per request.
//
// Completer (device to host memory):
//   An MRd from the device is checked (requester ID, length against MRRS, no
//   4 KiB crossing, byte enables) and answered from host memory after a random
//   latency, split at random RCB (64-byte) boundaries into completions of at
//   most cpl_mps bytes. Completions of different tags are sent in random
//   order, those of one tag in address order. A fault can be injected per
//   MRd (inj_* percentages): no completion at all, a UR or CA completion, a
//   poisoned completion, a wrong Byte Count; or one extra completion with a
//   tag nobody owns.
//   An MWr from the device is checked the same way and written into host
//   memory; one into [msi_base, msi_base + 1 MiB) is recorded as an MSI-X
//   message instead.
//
// Driver: TLPs go out in queue order, two DWs per beat, with random idle
// clocks (rx_gap_pct). Monitor: TX READY is random (tx_ready_pct), and VALID
// and data must hold until taken. Drive after the falling edge, sample on the
// rising edge, as in the other testbenches.

`timescale 1ns/1ps

package tlp_tb_pkg;

  typedef bit [31:0] dwq_t[$];
  typedef bit [7:0]  byteq_t[$];

  localparam bit [2:0] SC = 3'b000, UR = 3'b001, CA = 3'b100;

  function automatic bit [31:0] mk_dw0(bit [2:0] fmt, bit [4:0] ty, int len, bit ep = 1'b0,
                                       bit td = 1'b0, bit [2:0] tc = 3'd0, bit [1:0] attr = 2'd0);
    bit [9:0] l;
    l = (len >= 1024) ? 10'd0 : 10'(len);
    return {fmt, ty, 1'b0, tc, 4'b0000, td, ep, attr, 2'b00, l};
  endfunction

  function automatic bit [1:0] low_off(bit [3:0] be);
    if (be[0]) return 2'd0;
    if (be[1]) return 2'd1;
    if (be[2]) return 2'd2;
    if (be[3]) return 2'd3;
    return 2'd0;           // zero-length read
  endfunction

  function automatic bit [1:0] high_drop(bit [3:0] be);
    if (be[3]) return 2'd0;
    if (be[2]) return 2'd1;
    if (be[1]) return 2'd2;
    return 2'd3;
  endfunction

  function automatic int req_bytes(int len, bit [3:0] fbe, bit [3:0] lbe);
    int ones;
    if (len == 1) begin
      ones = int'(fbe[0]) + int'(fbe[1]) + int'(fbe[2]) + int'(fbe[3]);
      return (fbe == 4'd0) ? 1 : ones;
    end
    return len * 4 - int'(low_off(fbe)) - int'(high_drop(lbe));
  endfunction

  // DW range and byte enables of a byte range (n >= 1) inside one 4 KiB page.
  function automatic void be_of(bit [63:0] a, int n, output bit [63:0] dwa, output int len,
                                output bit [3:0] fbe, output bit [3:0] lbe);
    int first, last;
    first = int'(a[1:0]);
    dwa   = {a[63:2], 2'b00};
    len   = (first + n + 3) / 4;
    last  = (first + n - 1) % 4;   // byte lane of the last byte
    if (len == 1) begin
      fbe = 4'((((1 << n) - 1) << first) & 4'hF);
      lbe = 4'h0;
    end else begin
      fbe = 4'((4'hF << first) & 4'hF);
      lbe = 4'((1 << (last + 1)) - 1);
    end
  endfunction

  // Header (and payload) of a memory request.
  function automatic dwq_t enc_mem(bit wr, bit [63:0] dwa, int len, bit [3:0] fbe, bit [3:0] lbe,
                                   bit [15:0] rid, bit [7:0] tag, dwq_t data, bit ep = 1'b0,
                                   bit force4 = 1'b0, bit [2:0] tc = 3'd0, bit [1:0] attr = 2'd0);
    dwq_t q;
    bit   is4;
    is4 = force4 || (dwa[63:32] != 32'd0);
    q.push_back(mk_dw0({1'b0, wr, is4}, 5'b00000, len, ep, 1'b0, tc, attr));
    q.push_back({rid, tag, lbe, fbe});
    if (is4) q.push_back(dwa[63:32]);
    q.push_back({dwa[31:2], 2'b00});
    if (wr) foreach (data[i]) q.push_back(data[i]);
    return q;
  endfunction

  function automatic dwq_t enc_cfg(bit wr, bit [15:0] rid, bit [7:0] tag, bit [15:0] bdf,
                                   bit [9:0] regn, bit [3:0] fbe, bit [31:0] data,
                                   bit type1 = 1'b0, bit ep = 1'b0);
    dwq_t q;
    q.push_back(mk_dw0({1'b0, wr, 1'b0}, type1 ? 5'b00101 : 5'b00100, 1, ep));
    q.push_back({rid, tag, 4'h0, fbe});
    q.push_back({bdf, 4'h0, regn[9:6], regn[5:0], 2'b00});
    if (wr) q.push_back(data);
    return q;
  endfunction

  function automatic dwq_t enc_cpl(bit [15:0] cid, bit [2:0] st, bit [11:0] bc, bit [15:0] rid,
                                   bit [7:0] tag, bit [6:0] la, dwq_t data, bit ep = 1'b0);
    dwq_t q;
    bit   d;
    d = (data.size() > 0);
    q.push_back(mk_dw0({1'b0, d, 1'b0}, 5'b01010, d ? data.size() : 0, ep));
    q.push_back({cid, st, 1'b0, bc});
    q.push_back({rid, tag, 1'b0, la});
    foreach (data[i]) q.push_back(data[i]);
    return q;
  endfunction

  // Unpacked view of a received TLP.
  class tlp;
    bit [2:0]  fmt;
    bit [4:0]  ty;
    bit [2:0]  tc;
    bit [1:0]  attr;
    bit        ep, td;
    int        len;
    bit [15:0] rid;
    bit [7:0]  tag;
    bit [3:0]  fbe, lbe;
    bit [63:0] addr;      // DW address of a memory request
    bit [15:0] cid;
    bit [2:0]  st;
    bit [11:0] bc;
    bit [6:0]  la;
    dwq_t      d;

    function new(dwq_t q);
      int h;
      fmt  = q[0][31:29];
      ty   = q[0][28:24];
      tc   = q[0][22:20];
      td   = q[0][15];
      ep   = q[0][14];
      attr = q[0][13:12];
      len  = (q[0][9:0] == 0) ? 1024 : int'(q[0][9:0]);
      h    = fmt[0] ? 4 : 3;
      rid  = q[1][31:16];
      tag  = q[1][15:8];
      lbe  = q[1][7:4];
      fbe  = q[1][3:0];
      cid  = q[1][31:16];
      st   = q[1][15:13];
      bc   = q[1][11:0];
      addr = fmt[0] ? {q[2], q[3][31:2], 2'b00} : {32'd0, q[2][31:2], 2'b00};
      if (ty == 5'b01010) begin
        rid = q[2][31:16];
        tag = q[2][15:8];
        la  = q[2][6:0];
      end
      for (int i = h; i < q.size(); i++) d.push_back(q[i]);
    endfunction

    function bit is_mwr(); return fmt[1] && (ty == 5'b00000); endfunction
    function bit is_mrd(); return !fmt[1] && (ty == 5'b00000); endfunction
    function bit is_cpl(); return (fmt[2:1] == 2'b00 || fmt[2:1] == 2'b01) && !fmt[0] && (ty == 5'b01010); endfunction
  endclass

  // A request of the host, waiting for its completions.
  class host_req;
    bit [7:0]  tag;
    bit        cfg;
    int        nbytes;   // bytes asked for
    int        got;
    bit [6:0]  exp_la;
    byteq_t    bytes;
    bit [2:0]  status = SC;
    bit        done;
    int        ncpl;
  endclass

  // A completion the host will send.
  class cpl_job;
    dwq_t   q;
    longint ready_at;
    bit [7:0] tag;
  endclass

  // An item for the driver: a TLP, possibly damaged on purpose.
  class tx_item;
    dwq_t q;
    bit   nosop;     // first beat without sop
    bit   midsop;    // sop again on the second beat
    bit   bad;       // link-layer discard flag on the last beat
  endclass

  typedef struct {
    bit [63:0] addr;
    bit [31:0] data;
    longint    t;
  } msi_t;

  class tlp_host;
    virtual tlp_if vif;
    longint clk_period = 20;

    // Knobs
    int rx_gap_pct   = 10;
    int tx_ready_pct = 85;
    int lat_min      = 4;
    int lat_max      = 60;
    int merge_pct    = 50;    // chance to extend a completion by one more RCB
    int rcb          = 64;
    int cpl_mps      = 128;   // largest completion the host sends
    int dev_mps      = 128;   // device's Max_Payload_Size, for checks
    int dev_mrrs     = 512;
    int inj_drop = 0, inj_ur = 0, inj_ca = 0, inj_ep = 0, inj_bc = 0, inj_unexp = 0;
    bit [15:0] rc_id  = 16'h0000;
    bit [15:0] dev_id = 16'h0100;
    bit        id_set;        // the device has seen a configuration write
    bit [63:0] msi_base = 64'h0000_0000_FEE0_0000;

    // Host memory
    bit [7:0] hmem [bit [63:0]];

    // State
    host_req  outq [bit [7:0]];
    bit [7:0] free_tags[$];
    tx_item   sendq[$];
    cpl_job   cjobs[$];
    msi_t     msis[$];
    int       errors;
    bit       drv_busy;      // the driver holds a TLP (it may be in an idle gap)

    // Counts
    int     n_sent, n_recv, n_dev_mrd, n_dev_mwr, n_cpl_sent, n_cpl_recv, n_msi;
    int     n_faults, n_unexp_inj, n_split;
    longint dev_rd_bytes, dev_wr_bytes;
    longint busy_rx, busy_tx;        // beats moved
    int     max_out;

    function new(virtual tlp_if v);
      vif = v;
      for (int i = 0; i < 32; i++) free_tags.push_back(8'(i));
    endfunction

    function void err(string s);
      errors++;
      if (errors <= 20) $display("[HOST] ERROR at %0t: %s", $time, s);
    endfunction

    function bit [7:0] hget(bit [63:0] a);
      return hmem.exists(a) ? hmem[a] : (a[7:0] ^ a[15:8] ^ a[23:16] ^ 8'h3C);
    endfunction

    function bit [31:0] hget_dw(bit [63:0] a);
      return {hget(a + 3), hget(a + 2), hget(a + 1), hget(a)};
    endfunction

    function void send(dwq_t q, bit nosop = 0, bit midsop = 0, bit bad = 0);
      tx_item it = new();
      it.q = q; it.nosop = nosop; it.midsop = midsop; it.bad = bad;
      sendq.push_back(it);
    endfunction

    function bit idle();
      return sendq.size() == 0 && !drv_busy && cjobs.size() == 0 && outq.size() == 0 && !vif.rx_valid;
    endfunction

    task run();
      vif.rx_valid = 1'b0;
      vif.rx_data  = 64'd0;
      vif.rx_sop   = 1'b0;
      vif.rx_eop   = 1'b0;
      vif.rx_ehalf = 1'b0;
      vif.rx_bad   = 1'b0;
      vif.tx_ready = 1'b0;
      fork
        driver();
        monitor();
        cpl_sched();
      join_none
    endtask

    // ------------------------------------------------------------------------
    // Driver
    // ------------------------------------------------------------------------
    task driver();
      tx_item it;
      int     i;
      bit     have, acc;
      have = 1'b0;
      i    = 0;
      forever begin
        @(posedge vif.clk);
        acc = vif.rx_valid && vif.rx_ready;
        @(negedge vif.clk);
        if (acc) begin
          busy_rx++;
          i += 2;
          if (i >= it.q.size()) have = 1'b0;
        end
        drv_busy = have;
        if (vif.rx_valid && !acc) continue;   // hold until taken
        if (!have && sendq.size() > 0) begin
          it   = sendq.pop_front();
          i    = 0;
          have = 1'b1;
          n_sent++;
          drv_busy = 1'b1;
        end
        if (have && ($urandom_range(99) >= rx_gap_pct)) begin
          vif.rx_valid = 1'b1;
          vif.rx_data  = {(i + 1 < it.q.size()) ? it.q[i + 1] : 32'd0, it.q[i]};
          vif.rx_sop   = (i == 0 && !it.nosop) || (i == 2 && it.midsop);
          vif.rx_eop   = (i + 2 >= it.q.size());
          vif.rx_ehalf = (i + 1 == it.q.size());
          vif.rx_bad   = (i + 2 >= it.q.size()) && it.bad;
        end else begin
          vif.rx_valid = 1'b0;
        end
      end
    endtask

    // ------------------------------------------------------------------------
    // Monitor
    // ------------------------------------------------------------------------
    task monitor();
      dwq_t        q;
      bit          pv, pr;
      bit [66:0]   pd;
      forever begin
        @(negedge vif.clk);
        vif.tx_ready = ($urandom_range(99) < tx_ready_pct);
        @(posedge vif.clk);
        if (pv && !pr && !(vif.tx_valid && {vif.tx_ehalf, vif.tx_eop, vif.tx_sop, vif.tx_data} == pd))
          err("TX VALID or data changed before READY");
        pv = vif.tx_valid;
        pr = vif.tx_ready;
        pd = {vif.tx_ehalf, vif.tx_eop, vif.tx_sop, vif.tx_data};
        if (vif.tx_valid && vif.tx_ready) begin
          busy_tx++;
          if (vif.tx_sop && q.size() != 0) err("TX sop inside a TLP");
          if (!vif.tx_sop && q.size() == 0) err("TX beat without sop");
          if (vif.tx_sop) q.delete();
          q.push_back(vif.tx_data[31:0]);
          if (!(vif.tx_eop && vif.tx_ehalf)) q.push_back(vif.tx_data[63:32]);
          if (vif.tx_eop) begin
            handle(q);
            q.delete();
          end
        end
      end
    endtask

    function void handle(dwq_t q);
      tlp t;
      int h, exp;
      n_recv++;
      t   = new(q);
      h   = t.fmt[0] ? 4 : 3;
      exp = h + (t.fmt[1] ? t.len : 0);
      if (q.size() != exp) begin
        err($sformatf("TLP of %0d DWs, header says %0d", q.size(), exp));
        return;
      end
      if (t.td || t.tc != 0) err("TLP with TD or a traffic class other than 0");
      if (t.fmt[0] && t.addr[63:32] == 0 && !t.is_cpl()) err("4DW header for a 32-bit address");
      if (t.is_mwr())      dev_mwr(t);
      else if (t.is_mrd()) dev_mrd(t);
      else if (t.is_cpl()) host_cpl(t);
      else err($sformatf("unexpected TLP fmt %b type %b", t.fmt, t.ty));
    endfunction

    function void check_req(tlp t, string what, int limit);
      int end_dw;
      if (t.rid != dev_id) err($sformatf("%s requester ID %h, expected %h", what, t.rid, dev_id));
      if (t.len > limit / 4) err($sformatf("%s of %0d DWs, limit %0d bytes", what, t.len, limit));
      end_dw = int'(t.addr[11:2]) + t.len - 1;
      if (end_dw > 1023) err($sformatf("%s at %h, %0d DWs, crosses 4 KiB", what, t.addr, t.len));
      if (t.len == 1 && t.lbe != 0) err($sformatf("%s of 1 DW with Last BE %h", what, t.lbe));
      if (t.len > 1 && (t.fbe == 0 || t.lbe == 0)) err($sformatf("%s with an empty BE", what));
    endfunction

    // Device writes host memory, or sends an MSI-X message.
    function void dev_mwr(tlp t);
      bit [63:0] a;
      msi_t      m;
      n_dev_mwr++;
      check_req(t, "MWr", dev_mps);
      if (t.ep) err("poisoned MWr from the device");
      if (t.addr >= msi_base && t.addr < msi_base + 64'h10_0000) begin
        if (t.len != 1 || t.fbe != 4'hF) err("MSI-X message is not one whole DW");
        m.addr = t.addr; m.data = t.d[0]; m.t = $time;
        msis.push_back(m);
        n_msi++;
        return;
      end
      foreach (t.d[i]) begin
        for (int k = 0; k < 4; k++) begin
          bit en;
          en = (i == 0) ? t.fbe[k] : ((i == t.len - 1) ? t.lbe[k] : 1'b1);
          a  = t.addr + 64'(4 * i + k);
          if (en) hmem[a] = t.d[i][8*k +: 8];
        end
      end
      dev_wr_bytes += 4 * t.len;
    endfunction

    // Device reads host memory: completions, maybe with a fault.
    function void dev_mrd(tlp t);
      int        total, rem, f, s, e, lim, b;
      bit [63:0] a;
      longint    when;
      cpl_job    j;
      dwq_t      dq;
      bit        first;
      n_dev_mrd++;
      check_req(t, "MRd", dev_mrrs);
      total = req_bytes(t.len, t.fbe, t.lbe);
      dev_rd_bytes += longint'(total);
      a = t.addr + 64'(low_off(t.fbe));
      f = $urandom_range(99);
      when = $time + clk_period * longint'($urandom_range(lat_max, lat_min));
      if (inj_unexp > 0 && $urandom_range(99) < inj_unexp) begin
        j = new();
        dq.delete();
        dq.push_back(32'hDEAD_BEEF);
        j.q = enc_cpl(rc_id, SC, 12'd4, dev_id, 8'hE0 + 8'($urandom_range(15)), 7'd0, dq);
        j.ready_at = when;
        j.tag = 8'hFF;
        cjobs.push_back(j);
        n_unexp_inj++;
      end
      if (f < inj_drop) begin
        n_faults++;
        return;
      end
      f -= inj_drop;
      if (f < inj_ur + inj_ca) begin
        n_faults++;
        j = new();
        dq.delete();
        j.q = enc_cpl(rc_id, (f < inj_ur) ? UR : CA, 12'(total), t.rid, t.tag, a[6:0], dq);
        j.ready_at = when;
        j.tag = t.tag;
        cjobs.push_back(j);
        return;
      end
      f -= inj_ur + inj_ca;
      // Split into completions at RCB boundaries, each at most cpl_mps bytes.
      s     = int'(t.addr[11:0]) / 4;                 // DW within the page
      e     = s + t.len;
      rem   = total;
      first = 1'b1;
      while (s < e) begin
        lim = ((s * 4) / rcb + 1) * rcb / 4;           // next RCB boundary
        while (lim < e && (lim - s + rcb / 4) * 4 <= cpl_mps && $urandom_range(99) < merge_pct) lim += rcb / 4;
        if (lim > e) lim = e;
        if (lim < e) n_split++;
        dq.delete();
        for (int i = s; i < lim; i++) dq.push_back(hget_dw({t.addr[63:12], 12'd0} + 64'(4 * i)));
        j = new();
        j.q = enc_cpl(rc_id, SC, 12'(rem), t.rid, t.tag, first ? a[6:0] : 7'(s * 4), dq);
        if (first && f < inj_ep) begin
          j.q[0][14] = 1'b1;
          n_faults++;
        end else if (first && f >= inj_ep && f < inj_ep + inj_bc) begin
          j.q[1][11:0] = j.q[1][11:0] + 12'd4;
          n_faults++;
        end
        when += clk_period * longint'($urandom_range(8, 0));
        j.ready_at = when;
        j.tag = t.tag;
        cjobs.push_back(j);
        b = (lim - s) * 4 - (first ? int'(low_off(t.fbe)) : 0);
        rem -= b;
        s = lim;
        first = 1'b0;
      end
    endfunction

    // Completion scheduler: a random ready completion, oldest first within
    // its tag.
    task cpl_sched();
      int cand[$];
      bit seen[bit [7:0]];
      int k;
      forever begin
        @(negedge vif.clk);
        if (cjobs.size() == 0 || sendq.size() > 8) continue;
        cand.delete();
        seen.delete();
        foreach (cjobs[i]) begin
          if (!seen.exists(cjobs[i].tag) || cjobs[i].tag == 8'hFF) begin
            seen[cjobs[i].tag] = 1'b1;
            if (cjobs[i].ready_at <= $time) cand.push_back(i);
          end
        end
        if (cand.size() == 0) continue;
        k = cand[$urandom_range(cand.size() - 1)];
        send(cjobs[k].q);
        cjobs.delete(k);
        n_cpl_sent++;
      end
    endtask

    // ------------------------------------------------------------------------
    // Requester
    // ------------------------------------------------------------------------
    task automatic get_tag(output bit [7:0] tag);
      while (free_tags.size() == 0) @(negedge vif.clk);
      tag = free_tags.pop_front();
    endtask

    function void host_cpl(tlp t);
      host_req r;
      int      skip, take, room;
      n_cpl_recv++;
      if (!outq.exists(t.tag)) begin
        err($sformatf("completion for tag %0d, which is not outstanding", t.tag));
        return;
      end
      r = outq[t.tag];
      r.ncpl++;
      if (t.rid != rc_id) err($sformatf("completion requester ID %h", t.rid));
      if (id_set && t.cid != dev_id) err($sformatf("completer ID %h, expected %h", t.cid, dev_id));
      if (t.ep) err("poisoned completion from the device");
      if (t.st != SC) begin
        if (t.fmt[1]) err("error completion with data");
        if (!r.cfg && ((t.bc == 0) ? 4096 : int'(t.bc)) != r.nbytes - r.got)
          err($sformatf("error completion Byte Count %0d, expected %0d", t.bc, r.nbytes - r.got));
        r.status = t.st;
        finish(r);
        return;
      end
      if (!t.fmt[1]) begin
        if (!r.cfg) err("successful memory read completion without data");
        finish(r);
        return;
      end
      if (r.cfg) begin
        if (t.len != 1 || t.bc != 12'd4 || t.la != 7'd0) err("configuration completion fields");
        for (int k = 0; k < 4; k++) r.bytes.push_back(t.d[0][8*k +: 8]);
        r.got = 4;
        finish(r);
        return;
      end
      if (((t.bc == 0) ? 4096 : int'(t.bc)) != r.nbytes - r.got)
        err($sformatf("tag %0d Byte Count %0d, expected %0d", t.tag, t.bc, r.nbytes - r.got));
      if (t.la != r.exp_la) err($sformatf("tag %0d Lower Address %h, expected %h", t.tag, t.la, r.exp_la));
      skip = int'(t.la[1:0]);
      room = t.len * 4 - skip;
      take = (r.nbytes - r.got < room) ? r.nbytes - r.got : room;
      if (take < room && r.nbytes - r.got > room) err("completion longer than needed");
      if (r.got + take < r.nbytes && ((int'(t.la) & ~3) + t.len * 4) % 128 != 0)
        err($sformatf("tag %0d split at Lower Address %h + %0d DWs, not a 128-byte boundary",
                      t.tag, t.la, t.len));
      for (int i = 0; i < take; i++) r.bytes.push_back(t.d[(skip + i) / 4][8 * ((skip + i) % 4) +: 8]);
      r.got += take;
      r.exp_la = 7'((int'(t.la) & ~3) + t.len * 4);
      if (r.got >= r.nbytes) finish(r);
    endfunction

    function void finish(host_req r);
      r.done = 1'b1;
      outq.delete(r.tag);
      free_tags.push_back(r.tag);
    endfunction

    task automatic cfg_rd(bit [9:0] regn, output bit [31:0] d, output bit [2:0] st,
                          input bit [15:0] bdf = 16'hFFFF, input bit type1 = 1'b0);
      host_req r = new();
      bit [7:0] tag;
      get_tag(tag);
      r.tag = tag; r.cfg = 1'b1; r.nbytes = 4;
      outq[tag] = r;
      send(enc_cfg(1'b0, rc_id, tag, (bdf == 16'hFFFF) ? dev_id : bdf, regn, 4'hF, 32'd0, type1));
      while (!r.done) @(negedge vif.clk);
      st = r.status;
      d  = (r.bytes.size() == 4) ? {r.bytes[3], r.bytes[2], r.bytes[1], r.bytes[0]} : 32'd0;
    endtask

    task automatic cfg_wr(bit [9:0] regn, bit [31:0] d, bit [3:0] be, output bit [2:0] st,
                          input bit ep = 1'b0, input bit [15:0] bdf = 16'hFFFF);
      host_req r = new();
      bit [7:0] tag;
      get_tag(tag);
      r.tag = tag; r.cfg = 1'b1; r.nbytes = 4;
      outq[tag] = r;
      send(enc_cfg(1'b1, rc_id, tag, (bdf == 16'hFFFF) ? dev_id : bdf, regn, be, d, 1'b0, ep));
      while (!r.done) @(negedge vif.clk);
      if (bdf == 16'hFFFF && !ep) id_set = 1'b1;
      st = r.status;
    endtask

    function void mem_wr(bit [63:0] a, byteq_t b, bit ep = 1'b0);
      bit [63:0] dwa;
      int        len;
      bit [3:0]  fbe, lbe;
      dwq_t      d;
      be_of(a, b.size(), dwa, len, fbe, lbe);
      for (int i = 0; i < len; i++) begin
        bit [31:0] w;
        for (int k = 0; k < 4; k++) begin
          int o;
          o = 4 * i + k - int'(a[1:0]);
          w[8*k +: 8] = (o >= 0 && o < b.size()) ? b[o] : 8'h00;
        end
        d.push_back(w);
      end
      send(enc_mem(1'b1, dwa, len, fbe, lbe, rc_id, 8'd0, d, ep));
    endfunction

    task automatic mem_rd_nb(bit [63:0] a, int n, output host_req r);
      bit [63:0] dwa;
      int        len;
      bit [3:0]  fbe, lbe;
      bit [7:0]  tag;
      dwq_t      none;
      r = new();
      get_tag(tag);
      be_of(a, n, dwa, len, fbe, lbe);
      r.tag = tag; r.nbytes = n; r.exp_la = a[6:0];
      outq[tag] = r;
      if (outq.size() > max_out) max_out = outq.size();
      send(enc_mem(1'b0, dwa, len, fbe, lbe, rc_id, tag, none));
    endtask

    task automatic mem_rd(bit [63:0] a, int n, output byteq_t b, output bit [2:0] st);
      host_req r;
      mem_rd_nb(a, n, r);
      while (!r.done) @(negedge vif.clk);
      b  = r.bytes;
      st = r.status;
    endtask
  endclass

endpackage
