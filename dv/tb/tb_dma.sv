// tb_dma
//
// Block testbench for rtl/dma/dma.sv (Verilator --binary --timing --assert
// --coverage; dv/run_dma.sh).
//
//   +test=directed   byte offsets, 4 KB splits, chains, FENCE, every error
//                    cause, abort, START while busy, restart after an error,
//                    throughput on a memory that never stalls
//   +test=random     +n=<chains>: random chains (1 to 8 descriptors, lengths
//                    1 to 20,000 bytes, any offsets, FENCE on descriptors that
//                    read an earlier descriptor's destination) on a memory
//                    with random READY, latency and R gaps; 8% of the chains
//                    get an error and 4% an abort
//
// Reference model: a byte array updated by running each descriptor in order.
// After a run every byte the memory holds is compared with it, so a write
// outside a descriptor's destination (a wrong strobe, a wrong burst address)
// is caught as well as wrong data; destinations carry 16 guard bytes on each
// side. Runs that stop on an error compare the descriptors that DESC_DONE
// reports complete. axi4_checker watches the DMA's AXI port.
//
// Output lines start with [DMA].

`timescale 1ns/1ps

module tb_dma;
  import dma_tb_pkg::*;

  logic clk   = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;

  axi4_if axi (.clk(clk), .rst_n(rst_n));

  logic        psel    = 1'b0;
  logic        penable = 1'b0;
  logic        pwrite  = 1'b0;
  logic [11:0] paddr   = 12'd0;
  logic [31:0] pwdata  = 32'd0;
  logic [3:0]  pstrb   = 4'd0;
  logic [31:0] prdata;
  logic        pready, pslverr;
  logic        irq_done, irq_err;
  logic [1:0]  awid, arid;

  dma u_dma (
    .clk       (clk),         .rst_n     (rst_n),
    .psel      (psel),        .penable   (penable),     .paddr    (paddr),
    .pwrite    (pwrite),      .pwdata    (pwdata),      .pstrb    (pstrb),
    .prdata    (prdata),      .pready    (pready),      .pslverr  (pslverr),
    .m_awid    (awid),        .m_awaddr  (axi.awaddr),  .m_awlen  (axi.awlen),
    .m_awsize  (axi.awsize),  .m_awburst (axi.awburst), .m_awprot (axi.awprot),
    .m_awcache (axi.awcache), .m_awqos   (axi.awqos),   .m_awvalid(axi.awvalid),
    .m_awready (axi.awready),
    .m_wdata   (axi.wdata),   .m_wstrb   (axi.wstrb),   .m_wlast  (axi.wlast),
    .m_wvalid  (axi.wvalid),  .m_wready  (axi.wready),
    .m_bid     (axi.bid[1:0]),.m_bresp   (axi.bresp),   .m_bvalid (axi.bvalid),
    .m_bready  (axi.bready),
    .m_arid    (arid),        .m_araddr  (axi.araddr),  .m_arlen  (axi.arlen),
    .m_arsize  (axi.arsize),  .m_arburst (axi.arburst), .m_arprot (axi.arprot),
    .m_arcache (axi.arcache), .m_arqos   (axi.arqos),   .m_arvalid(axi.arvalid),
    .m_arready (axi.arready),
    .m_rid     (axi.rid[1:0]),.m_rdata   (axi.rdata),   .m_rresp  (axi.rresp),
    .m_rlast   (axi.rlast),   .m_rvalid  (axi.rvalid),  .m_rready (axi.rready),
    .irq_done  (irq_done),    .irq_err   (irq_err)
  );
  assign axi.awid = {2'b00, awid};
  assign axi.arid = {2'b00, arid};

  axi4_checker #(.KIND("M"), .IDX(2)) u_chk (.a(axi));

  localparam logic [11:0] R_CTRL   = 12'h000;
  localparam logic [11:0] R_PTR    = 12'h004;
  localparam logic [11:0] R_STATUS = 12'h008;
  localparam logic [11:0] R_INFO   = 12'h00C;
  localparam logic [11:0] R_EADDR  = 12'h010;
  localparam logic [11:0] R_CUR    = 12'h014;
  localparam logic [11:0] R_DONE   = 12'h018;
  localparam logic [11:0] R_CYC    = 12'h01C;

  mem_slave   slv;
  logic [7:0] exp [logic [31:0]];
  int         errors = 0;

  function automatic void err(string s);
    errors++;
    if (errors <= 20) $display("[DMA] ERROR at %0t: %s", $time, s);
  endfunction

  // A string variable, not a ?: between literals: Verilator pads the latter
  // to the longer literal.
  function automatic string verdict(int bad);
    string s;
    s = (bad == 0) ? "ok" : "FAIL";
    return s;
  endfunction

  // ---------------------------------------------------------------------------
  // APB: SETUP on one falling edge, ACCESS on the next. The register block
  // answers in the first ACCESS cycle; PREADY and PRDATA are sampled on the
  // falling edge inside it.
  // ---------------------------------------------------------------------------
  task automatic apb_xfer(bit wr, logic [11:0] a, logic [31:0] d, output logic [31:0] rd);
    @(negedge clk);
    psel = 1'b1; penable = 1'b0; pwrite = wr; paddr = a; pwdata = d; pstrb = 4'hF;
    @(negedge clk);
    penable = 1'b1;
    while (!pready) @(negedge clk);
    rd = prdata;
    if (pslverr) err($sformatf("PSLVERR at offset %h", a));
    @(negedge clk);
    psel = 1'b0; penable = 1'b0; pwrite = 1'b0;
  endtask

  task automatic apb_wr(logic [11:0] a, logic [31:0] d);
    logic [31:0] unused;
    apb_xfer(1'b1, a, d, unused);
  endtask

  task automatic apb_rd(logic [11:0] a, output logic [31:0] d);
    apb_xfer(1'b0, a, 32'd0, d);
  endtask

  // ---------------------------------------------------------------------------
  // Test memory: random contents in both the model and the reference
  // ---------------------------------------------------------------------------
  function automatic void fill(logic [31:0] a, int n);
    logic [7:0] b;
    for (int i = 0; i < n; i++) begin
      b = 8'($urandom);
      slv.mem[a + 32'(i)] = b;
      exp[a + 32'(i)]     = b;
    end
  endfunction

  function automatic void put32(logic [31:0] a, logic [31:0] v);
    for (int i = 0; i < 4; i++) begin
      slv.mem[a + 32'(i)] = v[i*8 +: 8];
      exp[a + 32'(i)]     = v[i*8 +: 8];
    end
  endfunction

  function automatic logic [7:0] exp_get(logic [31:0] a);
    return exp.exists(a) ? exp[a] : init_byte(a);
  endfunction

  logic [31:0] src_ptr, dst_ptr;

  function automatic void new_chain();
    slv.clear();
    exp.delete();
    src_ptr = 32'h1000_0000 + 32'($urandom_range(4095));
    dst_ptr = 32'h2000_0000 + 32'($urandom_range(4095));
  endfunction

  // A source of len bytes at byte offset off.
  function automatic logic [31:0] alloc_src(int len, int off);
    logic [31:0] a;
    a = ((src_ptr + 32'd15) & ~32'd7) + 32'(off);
    fill(a - 32'd8, len + 16);
    src_ptr = a + 32'(len) + 32'($urandom_range(64));
    return a;
  endfunction

  // A destination of len bytes at byte offset off, with 16 guard bytes on
  // each side.
  function automatic logic [31:0] alloc_dst(int len, int off);
    logic [31:0] a;
    a = ((dst_ptr + 32'd23) & ~32'd7) + 32'(off);
    fill(a - 32'd16, len + 32);
    dst_ptr = a + 32'(len) + 32'd16 + 32'($urandom_range(64));
    return a;
  endfunction

  // ---------------------------------------------------------------------------
  // Descriptors
  // ---------------------------------------------------------------------------
  typedef struct {
    logic [31:0] src;
    logic [31:0] dst;
    int          len;
    bit          fence;
  } desc_t;

  logic [31:0] dsc_addr [$];

  function automatic desc_t mk(logic [31:0] s, logic [31:0] d, int len, bit fence);
    desc_t r;
    r.src = s; r.dst = d; r.len = len; r.fence = fence;
    return r;
  endfunction

  function automatic void build_chain(desc_t d[$], logic [31:0] base);
    logic [31:0] a;
    a = base + 32'($urandom_range(15) * 16);
    dsc_addr.delete();
    foreach (d[i]) begin
      dsc_addr.push_back(a);
      a = a + 32'(16 + 16 * $urandom_range(3));
    end
    foreach (d[i]) begin
      put32(dsc_addr[i] + 32'd0,  d[i].src);
      put32(dsc_addr[i] + 32'd4,  d[i].dst);
      put32(dsc_addr[i] + 32'd8,  {7'd0, d[i].fence, 24'(d[i].len)});
      put32(dsc_addr[i] + 32'd12, (i + 1 < d.size()) ? dsc_addr[i + 1] : 32'd0);
    end
  endfunction

  // Run the first n descriptors in order on the reference.
  function automatic void apply(desc_t d[$], int n);
    for (int k = 0; k < n; k++) begin
      for (int i = 0; i < d[k].len; i++) exp[d[k].dst + 32'(i)] = exp_get(d[k].src + 32'(i));
    end
  endfunction

  function automatic int compare_all(string name);
    int bad = 0;
    foreach (slv.mem[a]) begin
      if (!exp.exists(a)) begin
        bad++;
        if (bad <= 4) err($sformatf("%s: byte %h written outside every destination", name, a));
      end else if (slv.mem[a] !== exp[a]) begin
        bad++;
        if (bad <= 4) err($sformatf("%s: byte %h is %h, expected %h", name, a, slv.mem[a], exp[a]));
      end
    end
    return bad;
  endfunction

  function automatic int compare_dst(string name, desc_t d[$], int n);
    int bad = 0;
    for (int k = 0; k < n; k++) begin
      for (int i = -16; i < d[k].len + 16; i++) begin
        if (slv.get(d[k].dst + 32'(i)) !== exp_get(d[k].dst + 32'(i))) begin
          bad++;
          if (bad <= 4) err($sformatf("%s: descriptor %0d byte %0d differs", name, k, i));
        end
      end
    end
    return bad;
  endfunction

  // Start address of the burst that carries byte target, with the DMA's
  // split rules (16 beats, 4 KB pages) over a transfer of len bytes at a.
  function automatic logic [31:0] burst_of(logic [31:0] a, int len, logic [31:0] target);
    logic [31:0] w;
    int          left, b, to_page;
    w    = a & ~32'd7;
    left = (int'(a[2:0]) + len + 7) / 8;
    while (left > 0) begin
      to_page = (4096 - int'(w[11:0])) / 8;
      b = 16;
      if (to_page < b) b = to_page;
      if (left < b)    b = left;
      if (target >= w && target < w + 32'(b * 8)) return w;
      w    = w + 32'(b * 8);
      left = left - b;
    end
    return 32'hFFFF_FFFF;
  endfunction

  // ---------------------------------------------------------------------------
  // Coverage
  // ---------------------------------------------------------------------------
  int cv_soff, cv_doff, cv_lenb, cv_fence;
  int cv_blen, cv_wr, cv_page;
  int cv_cause, cv_chain;

  covergroup cg_desc;
    cp_soff:  coverpoint cv_soff  { bins o[] = {[0:7]}; }
    cp_doff:  coverpoint cv_doff  { bins o[] = {[0:7]}; }
    x_off:    cross cp_soff, cp_doff;
    cp_len:   coverpoint cv_lenb  { bins one = {0}; bins lt8 = {1}; bins eq8 = {2}; bins lt128 = {3};
                                    bins eq128 = {4}; bins lt4k = {5}; bins ge4k = {6}; }
    cp_fence: coverpoint cv_fence { bins off = {0}; bins on = {1}; }
  endgroup

  covergroup cg_burst;
    cp_blen:    coverpoint cv_blen { bins b[] = {[1:16]}; }
    cp_dir:     coverpoint cv_wr   { bins rd = {0}; bins wr = {1}; }
    cp_page:    coverpoint cv_page { bins mid_page = {0}; bins to_page_end = {1}; }
    x_dir_len:  cross cp_dir, cp_blen;
    x_dir_page: cross cp_dir, cp_page;
  endgroup

  covergroup cg_end;
    cp_cause: coverpoint cv_cause { bins ok = {0}; bins desc_rd = {1}; bins data_rd = {2};
                                    bins data_wr = {3}; bins bad = {4}; bins abort = {5}; }
    cp_chain: coverpoint cv_chain { bins one = {1}; bins few = {[2:4]}; bins some = {[5:16]};
                                    bins many = {[17:$]}; }
  endgroup

  cg_desc  cgd = new;
  cg_burst cgb = new;
  cg_end   cge = new;

  int n_page_rd, n_page_wr;

  function automatic int len_bucket(int len);
    if (len == 1)    return 0;
    if (len < 8)     return 1;
    if (len == 8)    return 2;
    if (len < 128)   return 3;
    if (len == 128)  return 4;
    if (len < 4096)  return 5;
    return 6;
  endfunction

  always @(posedge clk) begin
    if (rst_n) begin
      if (u_dma.launch) begin
        cv_soff  = int'(u_dma.nd_src[2:0]);
        cv_doff  = int'(u_dma.nd_dst[2:0]);
        cv_lenb  = len_bucket(int'(u_dma.nd_len));
        cv_fence = int'(u_dma.nd_fence);
        cgd.sample();
      end
      if (axi.arvalid && axi.arready && axi.arid == 4'd0) begin
        cv_blen = int'(axi.arlen) + 1;
        cv_wr   = 0;
        cv_page = (({20'd0, axi.araddr[11:0]} + (cv_blen * 8)) == 4096) ? 1 : 0;
        if (cv_page == 1 && cv_blen < 16) n_page_rd++;
        cgb.sample();
      end
      if (axi.awvalid && axi.awready) begin
        cv_blen = int'(axi.awlen) + 1;
        cv_wr   = 1;
        cv_page = (({20'd0, axi.awaddr[11:0]} + (cv_blen * 8)) == 4096) ? 1 : 0;
        if (cv_page == 1 && cv_blen < 16) n_page_wr++;
        cgb.sample();
      end
    end
  end

  // The DMA issues an AW only when the whole burst is in its write FIFO, so
  // once a burst's first W beat is offered, WVALID stays high to WLAST: a
  // write never holds the slave's W channel waiting for read data.
  bit in_wburst = 1'b0;
  int n_w_bubble = 0;
  always @(posedge clk) begin
    if (rst_n) begin
      if (in_wburst && !axi.wvalid) begin
        n_w_bubble++;
        if (n_w_bubble <= 3) err("WVALID low inside a write burst");
      end
      if (axi.wvalid && axi.wready) in_wburst = !axi.wlast;
      else if (axi.wvalid)          in_wburst = 1'b1;
    end
  end

  // ---------------------------------------------------------------------------
  // Runs
  // ---------------------------------------------------------------------------
  logic [31:0] r_status, r_info, r_eaddr, r_cur, r_done, r_cyc;
  longint      tot_desc, tot_bytes;

  task automatic read_regs();
    apb_rd(R_STATUS, r_status);
    apb_rd(R_INFO,   r_info);
    apb_rd(R_EADDR,  r_eaddr);
    apb_rd(R_CUR,    r_cur);
    apb_rd(R_DONE,   r_done);
    apb_rd(R_CYC,    r_cyc);
  endtask

  task automatic wait_end(string name, int max_cycles);
    int c = 0;
    while (!irq_done && !irq_err) begin
      @(negedge clk);
      c++;
      if (c > max_cycles) begin
        $display("[DMA] ERROR %s: no DONE or ERR after %0d clocks", name, c);
        $fatal(1, "[DMA] FAIL: hang");
      end
    end
    if (!slv.idle()) err($sformatf("%s: transactions outstanding when the run ended", name));
  endtask

  task automatic start(logic [31:0] ptr);
    apb_wr(R_PTR, ptr);
    apb_wr(R_CTRL, 32'h1);
  endtask

  // After a run has ended: no more requests for a while.
  task automatic quiet(string name);
    int ar0, aw0;
    ar0 = slv.n_ar;
    aw0 = slv.n_aw;
    repeat (50) @(negedge clk);
    if (slv.n_ar != ar0 || slv.n_aw != aw0) err($sformatf("%s: requests after the run ended", name));
  endtask

  function automatic int max_cycles_for(desc_t d[$]);
    longint b = 0;
    foreach (d[i]) b += longint'(d[i].len);
    return int'(2000 + 8 * d.size() * 40 + b * 4);
  endfunction

  // A chain that must complete.
  task automatic good_chain(string name, desc_t d[$], output int bad);
    build_chain(d, 32'h0800_0000);
    apply(d, d.size());
    slv.clear_stats();
    start(dsc_addr[0]);
    wait_end(name, max_cycles_for(d));
    read_regs();
    bad = 0;
    if (r_status != 32'h2) begin bad++; err($sformatf("%s: STATUS %h, expected 2 (DONE)", name, r_status)); end
    if (r_done != 32'(d.size())) begin
      bad++; err($sformatf("%s: DESC_DONE %0d, expected %0d", name, r_done, d.size()));
    end
    if (r_info != 32'd0) begin bad++; err($sformatf("%s: ERR_INFO %h after a clean run", name, r_info)); end
    bad += compare_all(name);
    cv_cause = 0;
    cv_chain = d.size();
    cge.sample();
    tot_desc += longint'(d.size());
    foreach (d[i]) tot_bytes += longint'(d[i].len);
    apb_wr(R_STATUS, 32'h6);
  endtask

  // A chain that must stop with the given cause, response and ERR_ADDR, with
  // at most max_done descriptors complete.
  task automatic err_chain(string name, desc_t d[$], bit built, int cause, logic [1:0] resp,
                           logic [31:0] eaddr, int max_done, output int bad);
    if (!built) build_chain(d, 32'h0800_0000);
    slv.clear_stats();
    start(dsc_addr[0]);
    wait_end(name, max_cycles_for(d));
    read_regs();
    bad = 0;
    if (r_status != 32'h4) begin bad++; err($sformatf("%s: STATUS %h, expected 4 (ERR)", name, r_status)); end
    if (r_info[2:0] != 3'(cause) || r_info[5:4] != resp) begin
      bad++; err($sformatf("%s: ERR_INFO %h, expected cause %0d resp %0d", name, r_info, cause, resp));
    end
    if (r_eaddr != eaddr) begin
      bad++; err($sformatf("%s: ERR_ADDR %h, expected %h", name, r_eaddr, eaddr));
    end
    if (int'(r_done) > max_done) begin
      bad++; err($sformatf("%s: DESC_DONE %0d, at most %0d expected", name, r_done, max_done));
    end
    apply(d, int'(r_done));
    bad += compare_dst(name, d, int'(r_done));
    quiet(name);
    cv_cause = cause;
    cv_chain = d.size();
    cge.sample();
    apb_wr(R_STATUS, 32'h6);
  endtask

  // Two short descriptors right after an error: the DMA must start clean.
  task automatic recovery(string name, output int bad);
    desc_t d[$];
    new_chain();
    d.push_back(mk(alloc_src(100, 3), alloc_dst(100, 6), 100, 1'b0));
    d.push_back(mk(alloc_src(37, 0),  alloc_dst(37, 1),  37,  1'b0));
    good_chain({name, " restart"}, d, bad);
  endtask

  // ---------------------------------------------------------------------------
  // Directed tests
  // ---------------------------------------------------------------------------
  task automatic t_offsets(output int bad);
    int lens[17] = '{1, 2, 3, 7, 8, 9, 15, 16, 17, 31, 63, 64, 65, 127, 128, 129, 200};
    desc_t d[$];
    int b;
    bad = 0;
    for (int so = 0; so < 8; so++) begin
      for (int dof = 0; dof < 8; dof++) begin
        new_chain();
        d.delete();
        foreach (lens[i]) d.push_back(mk(alloc_src(lens[i], so), alloc_dst(lens[i], dof), lens[i], 1'b0));
        good_chain($sformatf("offsets %0d/%0d", so, dof), d, b);
        bad += b;
      end
    end
    $display("[DMA] offsets: 64 chains of 17 descriptors, source and destination offsets 0..7 each, lengths 1..200: errors %0d", bad);
  endtask

  task automatic t_pages(output int bad);
    int lens[4] = '{13, 4096, 4097, 9000};
    desc_t d[$];
    logic [31:0] s, t;
    int b, rd0, wr0;
    bad = 0;
    rd0 = n_page_rd;
    wr0 = n_page_wr;
    for (int k = 0; k < 8; k++) begin
      new_chain();
      d.delete();
      foreach (lens[i]) begin
        s = 32'h1000_0000 + 32'(i) * 32'h8000 + 32'h0FE8 + 32'(k);
        t = 32'h2000_0000 + 32'(i) * 32'h8000 + 32'h0FD8 + 32'(7 - k);
        fill(s - 32'd8, lens[i] + 16);
        fill(t - 32'd16, lens[i] + 32);
        d.push_back(mk(s, t, lens[i], 1'b0));
      end
      good_chain($sformatf("pages %0d", k), d, b);
      bad += b;
    end
    $display("[DMA] 4 KB splits: 8 chains starting 24 and 40 bytes before a page end, lengths 13, 4096, 4097, 9000: %0d read and %0d write bursts cut at a page end, errors %0d",
             n_page_rd - rd0, n_page_wr - wr0, bad);
  endtask

  task automatic t_fence(output int bad);
    desc_t d[$];
    logic [31:0] a, b, c;
    int e;
    bad = 0;
    for (int k = 0; k < 4; k++) begin
      new_chain();
      d.delete();
      a = alloc_src(2048, k);
      b = alloc_dst(2048, 6);
      c = alloc_dst(64, 3);
      d.push_back(mk(a, b, 2048, 1'b0));
      d.push_back(mk(b + 32'd2048 - 32'd64, c, 64, 1'b1));
      good_chain($sformatf("fence %0d", k), d, e);
      bad += e;
    end
    $display("[DMA] fence: second descriptor reads the last 64 bytes the first one writes: errors %0d", bad);
  endtask

  task automatic t_errors(output int bad);
    desc_t  d[$];
    range_t r;
    int     e, b;
    bad = 0;

    // Data read error in the second of three descriptors.
    new_chain();
    d.delete();
    for (int i = 0; i < 3; i++) d.push_back(mk(alloc_src(1000, i), alloc_dst(1000, 7 - i), 1000, 1'b0));
    r.lo = d[1].src + 32'd500; r.hi = r.lo + 32'd1; r.resp = SLVERR;
    slv.rd_err.push_back(r);
    err_chain("data read error", d, 1'b0, 2, SLVERR, burst_of(d[1].src, 1000, r.lo), 1, e);
    bad += e;
    $display("[DMA] data read error: cause %0d, resp %0d, ERR_ADDR %h, DESC_DONE %0d: %s",
             r_info[2:0], r_info[5:4], r_eaddr, r_done, verdict(e));
    recovery("data read error", b); bad += b;

    // Data write error in the second of three descriptors.
    new_chain();
    d.delete();
    for (int i = 0; i < 3; i++) d.push_back(mk(alloc_src(1000, i), alloc_dst(1000, 7 - i), 1000, 1'b0));
    r.lo = d[1].dst + 32'd300; r.hi = r.lo + 32'd1; r.resp = SLVERR;
    slv.wr_err.push_back(r);
    err_chain("data write error", d, 1'b0, 3, SLVERR, burst_of(d[1].dst, 1000, r.lo), 1, e);
    bad += e;
    $display("[DMA] data write error: cause %0d, resp %0d, ERR_ADDR %h, DESC_DONE %0d: %s",
             r_info[2:0], r_info[5:4], r_eaddr, r_done, verdict(e));
    recovery("data write error", b); bad += b;

    // Descriptor read error: the second descriptor's NEXT points into a range
    // that answers DECERR.
    new_chain();
    d.delete();
    for (int i = 0; i < 3; i++) d.push_back(mk(alloc_src(300, i), alloc_dst(300, i), 300, 1'b0));
    build_chain(d, 32'h0800_0000);
    put32(dsc_addr[1] + 32'd12, 32'h0F00_0000);
    r.lo = 32'h0F00_0000; r.hi = 32'h0F00_0010; r.resp = DECERR;
    slv.rd_err.push_back(r);
    err_chain("descriptor read error", d, 1'b1, 1, DECERR, 32'h0F00_0000, 2, e);
    bad += e;
    $display("[DMA] descriptor read error: cause %0d, resp %0d, ERR_ADDR %h, DESC_DONE %0d: %s",
             r_info[2:0], r_info[5:4], r_eaddr, r_done, verdict(e));
    recovery("descriptor read error", b); bad += b;

    // LEN 0 in the second descriptor.
    new_chain();
    d.delete();
    for (int i = 0; i < 3; i++) d.push_back(mk(alloc_src(200, i), alloc_dst(200, i), 200, 1'b0));
    build_chain(d, 32'h0800_0000);
    put32(dsc_addr[1] + 32'd8, 32'd0);
    err_chain("LEN 0", d, 1'b1, 4, OKAY, dsc_addr[1], 1, e);
    bad += e;
    $display("[DMA] LEN 0: cause %0d, ERR_ADDR %h, DESC_DONE %0d: %s",
             r_info[2:0], r_eaddr, r_done, verdict(e));
    recovery("LEN 0", b); bad += b;

    // NEXT not 16-byte aligned in the first descriptor: it never starts.
    new_chain();
    d.delete();
    for (int i = 0; i < 2; i++) d.push_back(mk(alloc_src(200, i), alloc_dst(200, i), 200, 1'b0));
    build_chain(d, 32'h0800_0000);
    put32(dsc_addr[0] + 32'd12, dsc_addr[1] + 32'd4);
    err_chain("NEXT misaligned", d, 1'b1, 4, OKAY, dsc_addr[0], 0, e);
    bad += e;
    if (slv.n_aw != 0) begin bad++; err("NEXT misaligned: data was written"); end
    $display("[DMA] NEXT misaligned: cause %0d, ERR_ADDR %h, DESC_DONE %0d, writes %0d: %s",
             r_info[2:0], r_eaddr, r_done, slv.n_aw, verdict(e));
    recovery("NEXT misaligned", b); bad += b;

    // DESC_PTR not 16-byte aligned: ERR at once, no bus traffic.
    new_chain();
    slv.clear_stats();
    start(32'h0800_0008);
    wait_end("DESC_PTR misaligned", 100);
    read_regs();
    e = 0;
    if (r_status != 32'h4 || r_info != 32'h4 || r_eaddr != 32'h0800_0008 || slv.n_ar != 0) begin
      e++;
      err($sformatf("DESC_PTR misaligned: STATUS %h ERR_INFO %h ERR_ADDR %h reads %0d",
                    r_status, r_info, r_eaddr, slv.n_ar));
    end
    cv_cause = 4; cv_chain = 1; cge.sample();
    apb_wr(R_STATUS, 32'h6);
    bad += e;
    $display("[DMA] DESC_PTR misaligned: cause %0d, ERR_ADDR %h, reads %0d: %s",
             r_info[2:0], r_eaddr, slv.n_ar, verdict(e));
    recovery("DESC_PTR misaligned", b); bad += b;
  endtask

  task automatic t_abort(output int bad);
    desc_t d[$];
    int    b;
    bad = 0;
    new_chain();
    d.push_back(mk(alloc_src(32768, 2), alloc_dst(32768, 5), 32768, 1'b0));
    build_chain(d, 32'h0800_0000);
    slv.clear_stats();
    start(dsc_addr[0]);
    repeat (400) @(negedge clk);
    apb_wr(R_CTRL, 32'h2);
    wait_end("abort", 5000);
    read_regs();
    if (r_status != 32'h4 || r_info != 32'h5 || r_eaddr != dsc_addr[0] || r_done != 0) begin
      bad++;
      err($sformatf("abort: STATUS %h ERR_INFO %h ERR_ADDR %h DESC_DONE %0d", r_status, r_info,
                    r_eaddr, r_done));
    end
    quiet("abort");
    cv_cause = 5; cv_chain = 1; cge.sample();
    apb_wr(R_STATUS, 32'h6);
    $display("[DMA] abort after 400 clocks of a 32 KiB copy: cause %0d, ERR_ADDR %h, %0d clocks in all: %s",
             r_info[2:0], r_eaddr, r_cyc, verdict(bad));
    recovery("abort", b); bad += b;
  endtask

  // START while BUSY is ignored; START clears DONE.
  task automatic t_start_busy(output int bad);
    desc_t       d[$];
    logic [31:0] y, ydst, st;
    bad = 0;
    new_chain();
    d.push_back(mk(alloc_src(8192, 1), alloc_dst(8192, 4), 8192, 1'b0));
    build_chain(d, 32'h0800_0000);
    apply(d, 1);
    ydst = alloc_dst(64, 0);
    y    = 32'h0900_0000;
    put32(y + 32'd0,  d[0].src);
    put32(y + 32'd4,  ydst);
    put32(y + 32'd8,  32'd64);
    put32(y + 32'd12, 32'd0);
    start(dsc_addr[0]);
    repeat (100) @(negedge clk);
    start(y);
    wait_end("START while busy", 100000);
    read_regs();
    if (r_status != 32'h2 || r_done != 1 || r_cur != dsc_addr[0]) begin
      bad++;
      err($sformatf("START while busy: STATUS %h DESC_DONE %0d CUR_DESC %h", r_status, r_done, r_cur));
    end
    bad += compare_all("START while busy");
    // DONE still set: a new START clears it.
    start(y);
    apb_rd(R_STATUS, st);
    if (st[1] != 1'b0) begin bad++; err($sformatf("STATUS %h right after START: DONE not cleared", st)); end
    wait_end("second START", 10000);
    apb_wr(R_STATUS, 32'h6);
    $display("[DMA] START while busy ignored, START clears DONE: %s", verdict(bad));
  endtask

  // Throughput on a memory that never stalls.
  task automatic t_perf();
    desc_t d[$];
    int    b;
    slv.set_speed(100, 0, 0);
    new_chain();
    d.push_back(mk(alloc_src(4096, 0), alloc_dst(4096, 0), 4096, 1'b0));
    good_chain("perf aligned", d, b);
    $display("[DMA] throughput, 4096 B, offsets 0/0: %0d clocks, %0.2f B/clock", r_cyc, 4096.0 / real'(r_cyc));
    new_chain();
    d.delete();
    d.push_back(mk(alloc_src(4096, 3), alloc_dst(4096, 5), 4096, 1'b0));
    good_chain("perf unaligned", d, b);
    $display("[DMA] throughput, 4096 B, offsets 3/5: %0d clocks, %0.2f B/clock", r_cyc, 4096.0 / real'(r_cyc));
    new_chain();
    d.delete();
    d.push_back(mk(alloc_src(65536, 0), alloc_dst(65536, 0), 65536, 1'b0));
    good_chain("perf 64k", d, b);
    $display("[DMA] throughput, 65536 B, offsets 0/0: %0d clocks, %0.2f B/clock", r_cyc, 65536.0 / real'(r_cyc));
    new_chain();
    d.delete();
    for (int i = 0; i < 64; i++) d.push_back(mk(alloc_src(64, 0), alloc_dst(64, 0), 64, 1'b0));
    good_chain("perf chain", d, b);
    $display("[DMA] throughput, 64 descriptors of 64 B: %0d clocks, %0.2f B/clock, %0.1f clocks per descriptor",
             r_cyc, 4096.0 / real'(r_cyc), real'(r_cyc) / 64.0);
    slv.set_speed(70, 6, 20);
  endtask

  // ---------------------------------------------------------------------------
  // Random test
  // ---------------------------------------------------------------------------
  function automatic int rand_len();
    int p = $urandom_range(99);
    if (p < 25) return $urandom_range(16, 1);
    if (p < 55) return $urandom_range(300, 17);
    if (p < 90) return $urandom_range(5000, 301);
    return $urandom_range(20000, 5001);
  endfunction

  task automatic t_random(int n, output int bad);
    desc_t  d[$];
    bit     alloc[$];
    range_t r;
    int     nd, k, kind, e, len, off, n_err, n_abort, n_fence, wait_c;
    logic [31:0] eaddr;
    bad = 0; n_err = 0; n_abort = 0; n_fence = 0;
    for (int c = 0; c < n; c++) begin
      new_chain();
      slv.set_speed($urandom_range(100, 30), $urandom_range(8), $urandom_range(30));
      d.delete();
      alloc.delete();
      nd = $urandom_range(8, 1);
      for (int i = 0; i < nd; i++) begin
        if (i > 0 && d[i-1].len > 16 && $urandom_range(99) < 15) begin
          // Read part of the previous destination: needs FENCE.
          off = $urandom_range(d[i-1].len - 1);
          len = $urandom_range(d[i-1].len - off, 1);
          d.push_back(mk(d[i-1].dst + 32'(off), alloc_dst(len, $urandom_range(7)), len, 1'b1));
          alloc.push_back(1'b0);
          n_fence++;
        end else begin
          len = rand_len();
          d.push_back(mk(alloc_src(len, $urandom_range(7)), alloc_dst(len, $urandom_range(7)), len,
                         ($urandom_range(99) < 5)));
          alloc.push_back(1'b1);
        end
      end
      kind = $urandom_range(99);
      if (kind < 8) begin
        // Error in a random descriptor with its own source.
        k = $urandom_range(nd - 1);
        while (!alloc[k]) k = $urandom_range(nd - 1);
        n_err++;
        if ($urandom_range(1) == 0) begin
          r.lo = d[k].src + 32'(d[k].len / 2); r.hi = r.lo + 32'd1; r.resp = SLVERR;
          slv.rd_err.push_back(r);
          eaddr = burst_of(d[k].src, d[k].len, r.lo);
          err_chain($sformatf("random %0d read error", c), d, 1'b0, 2, SLVERR, eaddr, k, e);
        end else begin
          r.lo = d[k].dst + 32'(d[k].len / 2); r.hi = r.lo + 32'd1; r.resp = DECERR;
          slv.wr_err.push_back(r);
          eaddr = burst_of(d[k].dst, d[k].len, r.lo);
          err_chain($sformatf("random %0d write error", c), d, 1'b0, 3, DECERR, eaddr, k, e);
        end
        bad += e;
      end else if (kind < 12) begin
        // Abort at a random time; the chain may finish first.
        n_abort++;
        build_chain(d, 32'h0800_0000);
        slv.clear_stats();
        start(dsc_addr[0]);
        wait_c = $urandom_range(2000, 1);
        for (int i = 0; i < wait_c && !irq_done && !irq_err; i++) @(negedge clk);
        apb_wr(R_CTRL, 32'h2);
        wait_end($sformatf("random %0d abort", c), max_cycles_for(d));
        read_regs();
        if (r_status == 32'h2) begin
          apply(d, d.size());
          if (r_done != 32'(nd)) begin bad++; err($sformatf("random %0d: finished with DESC_DONE %0d", c, r_done)); end
          bad += compare_all($sformatf("random %0d abort after the end", c));
        end else if (r_status == 32'h4 && r_info == 32'h5) begin
          apply(d, int'(r_done));
          bad += compare_dst($sformatf("random %0d abort", c), d, int'(r_done));
          quiet($sformatf("random %0d abort", c));
        end else begin
          bad++;
          err($sformatf("random %0d abort: STATUS %h ERR_INFO %h", c, r_status, r_info));
        end
        cv_cause = (r_status == 32'h2) ? 0 : 5; cv_chain = nd; cge.sample();
        apb_wr(R_STATUS, 32'h6);
      end else begin
        good_chain($sformatf("random %0d", c), d, e);
        bad += e;
      end
    end
    $display("[DMA] random: %0d chains, %0d descriptors and %0d bytes completed, %0d with FENCE, %0d error runs, %0d aborts: errors %0d",
             n, tot_desc, tot_bytes, n_fence, n_err, n_abort, bad);
  endtask

  // ---------------------------------------------------------------------------
  // Main
  // ---------------------------------------------------------------------------
  string test = "directed";
  int    n    = 200;

  initial begin
    int b, total;
    void'($value$plusargs("test=%s", test));
    void'($value$plusargs("n=%d", n));
    slv = new(axi);
    slv.run();
    repeat (5) @(negedge clk);
    rst_n = 1'b1;
    repeat (5) @(negedge clk);
    total = 0;
    if (test == "directed") begin
      t_offsets(b);    total += b;
      t_pages(b);      total += b;
      t_fence(b);      total += b;
      t_errors(b);     total += b;
      t_abort(b);      total += b;
      t_start_busy(b); total += b;
      t_perf();
    end else begin
      t_random(n, b);  total += b;
    end
    $display("[DMA] outstanding at most: %0d reads, %0d writes", slv.max_out_rd, slv.max_out_wr);
    if (slv.max_out_rd > 5 || slv.max_out_wr > 4) err("more transactions outstanding than the DMA allows");
    if (total == 0 && errors == 0 && slv.errors == 0) begin
      $display("[DMA] %s: PASS", test);
    end else begin
      $display("[DMA] %s: FAIL, %0d mismatches, %0d errors reported", test, total, errors + slv.errors);
      $fatal(1, "[DMA] FAIL");
    end
    $finish;
  end

endmodule
