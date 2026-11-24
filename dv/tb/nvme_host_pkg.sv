`timescale 1ns/1ps

// -----------------------------------------------------------------------------
// nvme_host_pkg
//
// NVMe host driver model (step 2-5, docs/14_nvme_host_verification.md) on the
// TLP-level host model (tlp_tb_pkg::tlp_host): controller registers through
// BAR0, queues and data in host memory, MSI-X messages as the host model
// records them. It works as a host driver does:
//   - enables the controller with an admin queue pair;
//   - creates I/O queue pairs with admin commands, with any submission to
//     completion queue mapping (several SQs may share a CQ) and any vectors,
//     and deletes them;
//   - submits Read, Write and Flush with PRP1 alone, PRP1 and PRP2, or a PRP
//     list, rings the doorbells, takes completions by phase tag, matches each
//     to its command by CID and SQID, follows the SQ head each entry reports,
//     and rings the CQ head doorbells (or holds them back to fill a CQ);
//   - keeps a copy of the namespace and compares every byte read;
//   - resets the controller (CC.EN 0) with commands outstanding, abandons
//     them, and checks that none of them completes or writes its buffer
//     afterwards, and that at most one MSI-X message per reset goes missing
//     (the poster's, if it was waiting for the link).
// Every failed check counts in errors. Coverage events go to cov, which the
// testbench samples.
// -----------------------------------------------------------------------------

package nvme_host_pkg;
  import tlp_tb_pkg::*;

  localparam int NQ   = 5;            // admin queue pair and four I/O queue pairs
  localparam int NSB  = 24;           // namespace 1: blocks of 512 bytes
  localparam int NBUF = 128;          // data buffers: 5 pages, then a PRP list page

  // Statuses as DW3 bits 31:17 carry them ({DNR, M, CRD, SCT, SC})
  localparam bit [14:0] ST_OK     = 15'h0000;
  localparam bit [14:0] ST_OPC    = 15'h4001;
  localparam bit [14:0] ST_FIELD  = 15'h4002;
  localparam bit [14:0] ST_NS     = 15'h400B;
  localparam bit [14:0] ST_PRP    = 15'h4013;
  localparam bit [14:0] ST_LBA    = 15'h4080;
  localparam bit [14:0] ST_CQ_INV = 15'h4100;
  localparam bit [14:0] ST_QID    = 15'h4101;
  localparam bit [14:0] ST_QSIZE  = 15'h4102;
  localparam bit [14:0] ST_IV     = 15'h4108;
  localparam bit [14:0] ST_QDEL   = 15'h410C;

  // I/O command kinds
  localparam int K_READ = 0, K_WRITE = 1, K_FLUSH = 2, K_BAD_OPC = 3, K_BAD_LBA = 4, K_BAD_NS = 5,
                 K_BAD_PRP = 6, K_ADMIN = 7;

  // Coverage events (kind, a, b), sampled by the testbench:
  //   0 I/O command submitted   a kind, b SQ
  //   1 data layout             a 0 PRP1 only, 1 PRP1 and PRP2, 2 PRP list; b size class
  //   2 SQ tail wrap            a SQ
  //   3 CQ head wrap            a CQ (the phase the host expects flips)
  //   4 SQ full                 a SQ
  //   5 CQ head held back       a CQ
  //   6 commands outstanding    a 0: 1, 1: 2-4, 2: 5-15, 3: 16 or more
  //   7 admin command           a which (see admin_ev)
  //   8 controller reset        a commands outstanding: 0: none, 1: 1-3, 2: 4-15, 3: 16 or more
  //   9 queue layout            a 0 one CQ per SQ, 1 a CQ shared by SQs, 2 a vector shared by CQs
  //  10 I/O completed           a transfer overlap, b kind
  typedef struct {
    int kind;
    int a;
    int b;
  } nh_cov_t;

  class nh_cmd;
    bit [15:0] cid;
    int        sq, kind, lba, nblk, bix, off, len;
    longint    seq;           // position among all entries ever put into its SQ
    bit [14:0] want;
    longint    t0;
  endclass

  typedef struct {
    int b, off, len;
  } nh_quar_t;

  class nvme_host;
    tlp_host   h;
    bit [63:0] bar0, msi;
    bit [63:0] qmem = 64'h0000_0001_8000_0000;  // SQ q: + 64 KiB x q; CQ q: + 1 MiB + 64 KiB x q
    bit [63:0] dmem = 64'h0000_0001_8100_0000;  // buffer b: + 32 KiB x b
    int        errors;
    int        timeout = 400000;                // clocks a blocking wait may take

    // Queues as the host sees them
    bit        sq_on [NQ], cq_on [NQ];
    int        sq_size [NQ], cq_size [NQ], sq_cq [NQ], cq_vec [NQ];
    int        sq_tail [NQ], sq_head [NQ], cq_head [NQ], sq_out [NQ], cq_unrung [NQ];
    longint    sq_abs_tail [NQ], sq_abs_head [NQ];
    bit        cq_ph [NQ], cq_hold [NQ];
    bit        sq_dirty [NQ];                   // tail moved, doorbell not rung yet

    nh_cmd     out [bit [15:0]];
    bit        dead [bit [15:0]];               // CIDs abandoned by a reset
    bit [31:0] res_dw0 [bit [15:0]];            // DW0 of completed admin commands
    bit [15:0] next_cid = 16'h0100;
    bit        overlap;                         // the firmware's transfer overlap, as last set

    // Namespace copy
    bit [7:0]  ns [NSB * 512];
    bit        known [NSB];
    int        wlock [NSB], rlock [NSB];

    // Data buffers
    int        free_buf [$];
    nh_quar_t  quar [$];                        // abandoned reads' buffers, poisoned
    nh_quar_t  quar_old [$];                    // checked and released at the next reset

    // Counts
    int        n_sub, n_done, n_st_err, n_reads, n_writes, n_flush, n_admin, n_resets, n_abandon;
    int        n_cqe, n_sq_full, n_cq_hold, n_msi_lost, n_quar_checked;
    longint    rd_bytes, wr_bytes, lat_sum, lat_n;
    int        msi_idx;                         // host.msis index at this epoch's enable
    int        ent_vec [8];                     // entries taken this epoch, per vector
    nh_cov_t   cov [$];

    function new(tlp_host hh, bit [63:0] b0, bit [63:0] msi_addr);
      h = hh;
      bar0 = b0;
      msi = msi_addr;
      for (int b = 0; b < NBUF; b++) free_buf.push_back(b);
      for (int b = 0; b < NSB; b++) begin known[b] = 1'b0; wlock[b] = 0; rlock[b] = 0; end
      for (int q = 0; q < NQ; q++) begin sq_on[q] = 1'b0; cq_on[q] = 1'b0; end
    endfunction

    function void err(string s);
      errors++;
      if (errors <= 20) $display("[NVMEH] ERROR at %0t: %s", $time, s);
    endfunction

    function void ev(int k, int a = 0, int b = 0);
      nh_cov_t c;
      c.kind = k;
      c.a = a;
      c.b = b;
      cov.push_back(c);
    endfunction

    task tick(int n = 1);
      repeat (n) @(negedge h.vif.clk);
    endtask

    // -------------------------------------------------------------------------
    // Registers and host memory
    // -------------------------------------------------------------------------
    function void wr(int off, bit [31:0] v);
      byteq_t b;
      for (int k = 0; k < 4; k++) b.push_back(v[8*k +: 8]);
      h.mem_wr(bar0 + 64'(off), b);
    endfunction

    task rd(int off, output bit [31:0] v);
      byteq_t   b;
      bit [2:0] st;
      h.mem_rd(bar0 + 64'(off), 4, b, st);
      if (st != SC) err($sformatf("BAR0 +%h read: status %0d", off, st));
      v = {b[3], b[2], b[1], b[0]};
    endtask

    function bit [63:0] sq_addr(int q); return qmem + 64'(q) * 64'h1_0000; endfunction
    function bit [63:0] cq_addr(int q); return qmem + 64'h10_0000 + 64'(q) * 64'h1_0000; endfunction
    function bit [63:0] page(int b, int k); return dmem + 64'(b) * 64'h8000 + 64'(k) * 64'h1000; endfunction

    function void put_dw(bit [63:0] a, bit [31:0] v);
      for (int k = 0; k < 4; k++) h.hmem[a + 64'(k)] = v[8*k +: 8];
    endfunction

    function void clear_cq(int q, int n);
      for (int i = 0; i < 16 * n; i++) h.hmem[cq_addr(q) + 64'(i)] = 8'h00;
    endfunction

    // -------------------------------------------------------------------------
    // Controller enable, reset, shutdown
    // -------------------------------------------------------------------------
    function void q_init(int q, int sqs, int cqs, int cq, int vec);
      sq_size[q] = sqs; sq_tail[q] = 0; sq_head[q] = 0; sq_out[q] = 0; sq_cq[q] = cq;
      sq_abs_tail[q] = 0; sq_abs_head[q] = 0;
      if (cq == q || q == 0) begin
        cq_size[cq] = cqs; cq_head[cq] = 0; cq_ph[cq] = 1'b1; cq_vec[cq] = vec; cq_hold[cq] = 1'b0;
        cq_unrung[cq] = 0;
      end
    endfunction

    task enable(int asz);
      bit [31:0] v;
      bit [63:0] sa = sq_addr(0), ca = cq_addr(0);
      int        n = 0;
      q_init(0, asz, asz, 0, 0);
      foreach (sq_dirty[i]) sq_dirty[i] = 1'b0;
      clear_cq(0, asz);
      wr(32'h24, {4'd0, 12'(asz - 1), 4'd0, 12'(asz - 1)});
      wr(32'h28, sa[31:0]); wr(32'h2C, sa[63:32]);
      wr(32'h30, ca[31:0]); wr(32'h34, ca[63:32]);
      wr(32'h14, 32'h0046_0001);                 // IOCQES 4, IOSQES 6, EN
      do begin
        rd(32'h1C, v);
        if (++n > 2000) begin err("CSTS.RDY never set"); return; end
      end while (!v[0]);
      for (int q = 0; q < NQ; q++) begin sq_on[q] = (q == 0); cq_on[q] = (q == 0); end
      msi_idx = h.msis.size();
      foreach (ent_vec[i]) ent_vec[i] = 0;
      overlap = 1'b0;                            // features are back at their defaults
    endtask

    // MSI-X messages since this epoch's enable, against the entries taken:
    // one each, except at most `slack` lost.
    function void msi_check(int slack, string when);
      int got [8], lost = 0;
      foreach (got[v]) got[v] = 0;
      for (int i = msi_idx; i < h.msis.size(); i++)
        for (int v = 0; v < 8; v++)
          if (h.msis[i].addr == msi + 64'(16 * v)) got[v]++;
      for (int v = 0; v < 8; v++) begin
        if (got[v] > ent_vec[v])
          err($sformatf("%s: vector %0d sent %0d MSI-X messages for %0d entries", when, v, got[v], ent_vec[v]));
        else lost += ent_vec[v] - got[v];
      end
      if (lost > slack) err($sformatf("%s: %0d MSI-X messages missing (at most %0d)", when, lost, slack));
      n_msi_lost += lost;
    endfunction

    // Abandoned reads' buffers must still hold the poison.
    function void quar_check(nh_quar_t qq [$]);
      foreach (qq[i]) begin
        for (int k = 0; k < qq[i].len; k++)
          if (h.hget(page(qq[i].b, 0) + 64'(qq[i].off + k)) != 8'hA5) begin
            err($sformatf("buffer %0d of an abandoned read written after the reset (byte %0d)", qq[i].b, k));
            break;
          end
        n_quar_checked++;
      end
    endfunction

    function void abandon(nh_cmd c);
      if (c.kind == K_WRITE)
        for (int b = c.lba; b < c.lba + c.nblk; b++) known[b] = 1'b0;
      if (c.kind == K_READ || c.kind == K_WRITE) begin
        for (int b = c.lba; b < c.lba + c.nblk; b++) begin
          if (c.kind == K_WRITE) wlock[b]--;
          else                   rlock[b]--;
        end
      end
      if (c.bix >= 0) begin
        nh_quar_t z;
        z.b = c.bix; z.off = c.off; z.len = c.len;
        for (int k = 0; k < c.len; k++) h.hmem[page(c.bix, 0) + 64'(c.off + k)] = 8'hA5;
        quar.push_back(z);
      end
      dead[c.cid] = 1'b1;
      n_abandon++;
    endfunction

    // A controller reset with whatever is outstanding.
    task reset_ctrl();
      bit [31:0] v;
      int        n = 0, o = out.size();
      ev(8, (o == 0) ? 0 : (o < 4) ? 1 : (o < 16) ? 2 : 3);
      // Last reset's quarantine has been through a whole epoch: check, release.
      quar_check(quar_old);
      foreach (quar_old[i]) free_buf.push_back(quar_old[i].b);
      quar_old = quar;
      quar.delete();
      wr(32'h14, 32'h0046_0000);
      do begin
        rd(32'h1C, v);
        if (++n > 4000) begin err("CSTS.RDY never cleared"); return; end
      end while (v[0]);
      tick(300);
      // Entries written before the reset completed are completions like any
      // other; nothing may come after.
      for (int q = 0; q < NQ; q++) if (cq_on[q]) take_cq(q, n, 1'b0);
      msi_check(1, "controller reset");
      foreach (out[cid]) abandon(out[cid]);
      out.delete();
      for (int q = 0; q < NQ; q++) begin
        sq_on[q] = 1'b0; cq_on[q] = 1'b0; sq_out[q] = 0; sq_dirty[q] = 1'b0; cq_hold[q] = 1'b0;
      end
      n_resets++;
    endtask

    task shutdown();
      bit [31:0] v;
      int        n = 0;
      wr(32'h14, 32'h0046_4001);
      do begin
        rd(32'h1C, v);
        if (++n > 4000) begin err("CSTS.SHST never complete"); return; end
      end while (v[3:2] != 2'b10);
      tick(300);
      msi_check(0, "shutdown");
      quar_check(quar_old);
      quar_check(quar);
    endtask

    // -------------------------------------------------------------------------
    // Submission and completion
    // -------------------------------------------------------------------------
    function int sq_room(int q);
      return (sq_head[q] - sq_tail[q] - 1 + sq_size[q]) % sq_size[q];
    endfunction

    function bit [15:0] new_cid();
      do next_cid++; while (out.exists(next_cid) || dead.exists(next_cid) || next_cid < 16'h0100);
      return next_cid;
    endfunction

    function nh_cmd put_sqe(int q, int kind, bit [7:0] opc, bit [31:0] nsid, bit [63:0] prp1,
                            bit [63:0] prp2, bit [31:0] c10, bit [31:0] c11, bit [31:0] c12,
                            bit [14:0] want);
      nh_cmd     c = new();
      bit [63:0] a = sq_addr(q) + 64'(64 * sq_tail[q]);
      bit [31:0] dw [16];
      c.cid = new_cid();
      c.sq = q; c.kind = kind; c.want = want; c.bix = -1; c.t0 = $time;
      c.seq = sq_abs_tail[q];
      foreach (dw[i]) dw[i] = 32'd0;
      dw[0] = {c.cid, 8'h00, opc};
      dw[1] = nsid;
      dw[6] = prp1[31:0]; dw[7] = prp1[63:32];
      dw[8] = prp2[31:0]; dw[9] = prp2[63:32];
      dw[10] = c10; dw[11] = c11; dw[12] = c12;
      for (int i = 0; i < 16; i++) put_dw(a + 64'(4 * i), dw[i]);
      sq_tail[q] = (sq_tail[q] + 1) % sq_size[q];
      sq_abs_tail[q]++;
      sq_dirty[q] = 1'b1;
      if (sq_tail[q] == 0) ev(2, q);
      out[c.cid] = c;
      sq_out[q]++;
      n_sub++;
      return c;
    endfunction

    function void ring_sq(int q);
      wr(32'h1000 + 8 * q, 32'(sq_tail[q]));
      sq_dirty[q] = 1'b0;
    endfunction

    // Ring every submission queue whose tail moved.
    function void ring_all();
      for (int q = 0; q < NQ; q++) if (sq_on[q] && sq_dirty[q]) ring_sq(q);
    endfunction

    function void release_cqs();
      for (int q = 0; q < NQ; q++) cq_hold[q] = 1'b0;
    endfunction

    function void complete(int q, bit [31:0] d0, bit [31:0] d2, bit [31:0] d3);
      bit [15:0] cid = d3[15:0];
      bit [14:0] st = d3[31:17];
      int        sq = int'(d2[31:16]);
      int        sqhd = int'(d2[15:0]);
      nh_cmd     c;
      if (dead.exists(cid)) begin
        err($sformatf("CQ%0d: completion for CID %h, abandoned by a controller reset", q, cid));
        return;
      end
      if (!out.exists(cid)) begin
        err($sformatf("CQ%0d: completion for CID %h, not outstanding", q, cid));
        return;
      end
      c = out[cid];
      if (sq != c.sq) err($sformatf("CID %h: SQID %0d, submitted to SQ%0d", cid, sq, c.sq));
      if (sq_cq[c.sq] != q) err($sformatf("CID %h on CQ%0d; SQ%0d completes on CQ%0d", cid, q, c.sq, sq_cq[c.sq]));
      if (st != c.want) err($sformatf("CID %h (kind %0d, SQ%0d): status %h, expected %h", cid, c.kind, c.sq, st, c.want));
      // The SQ head: within the queue, forward of the last one seen, not
      // beyond the tail, and past this command.
      if (sqhd >= sq_size[c.sq]) begin
        err($sformatf("CID %h: SQ head %0d in a queue of %0d", cid, sqhd, sq_size[c.sq]));
      end else begin
        int fwd = (sqhd - sq_head[c.sq] + sq_size[c.sq]) % sq_size[c.sq];
        int ahead = (sq_tail[c.sq] - sq_head[c.sq] + sq_size[c.sq]) % sq_size[c.sq];
        if (fwd > ahead) err($sformatf("CID %h: SQ%0d head %0d beyond the tail %0d", cid, c.sq, sqhd, sq_tail[c.sq]));
        sq_head[c.sq] = sqhd;
        sq_abs_head[c.sq] += longint'(fwd);
        if (sq_abs_head[c.sq] <= c.seq)
          err($sformatf("CID %h completed with SQ%0d head %0d not past it", cid, c.sq, sqhd));
      end
      if (c.sq == 0) res_dw0[cid] = d0;
      else if (d0 != 32'd0) err($sformatf("CID %h: DW0 %h", cid, d0));
      if (c.kind == K_READ || c.kind == K_WRITE) begin
        bit ok = (st == ST_OK);
        if (c.kind == K_READ && ok) begin
          for (int k = 0; k < c.len; k++)
            if (h.hget(page(c.bix, 0) + 64'(c.off + k)) !== ns[c.lba * 512 + k]) begin
              err($sformatf("CID %h: read LBA %0d + %0d bytes: byte %0d is %h, expected %h", cid, c.lba, c.nblk, k,
                            h.hget(page(c.bix, 0) + 64'(c.off + k)), ns[c.lba * 512 + k]));
              break;
            end
          rd_bytes += longint'(c.len);
        end
        if (c.kind == K_WRITE && ok) begin
          for (int k = 0; k < c.len; k++) ns[c.lba * 512 + k] = h.hget(page(c.bix, 0) + 64'(c.off + k));
          for (int b = c.lba; b < c.lba + c.nblk; b++) known[b] = 1'b1;
          wr_bytes += longint'(c.len);
        end
        for (int b = c.lba; b < c.lba + c.nblk; b++) begin
          if (c.kind == K_WRITE) wlock[b]--;
          else                   rlock[b]--;
        end
        ev(10, int'(overlap), c.kind);
      end
      if (c.bix >= 0) free_buf.push_back(c.bix);
      if (st != ST_OK) n_st_err++;
      lat_sum += ($time - c.t0);
      lat_n++;
      sq_out[c.sq]--;
      out.delete(cid);
      n_done++;
    endfunction

    // Take every new entry of CQ q; ring its head doorbell unless it is held
    // back or ring is 0.
    task take_cq(int q, output int n, input bit ring = 1'b1);
      bit [63:0] a;
      bit [31:0] d0, d2, d3;
      n = 0;
      forever begin
        a = cq_addr(q) + 64'(16 * cq_head[q]);
        d3 = h.hget_dw(a + 64'd12);
        if (d3[16] != cq_ph[q]) break;
        d0 = h.hget_dw(a);
        d2 = h.hget_dw(a + 64'd8);
        n++;
        n_cqe++;
        cq_head[q] = (cq_head[q] + 1) % cq_size[q];
        if (cq_head[q] == 0) begin
          cq_ph[q] = !cq_ph[q];
          ev(3, q);
        end
        cq_unrung[q]++;
        ent_vec[cq_vec[q]]++;
        complete(q, d0, d2, d3);
      end
      if (ring && cq_unrung[q] > 0 && !cq_hold[q]) begin
        wr(32'h1004 + 8 * q, 32'(cq_head[q]));
        cq_unrung[q] = 0;
      end
    endtask

    task poll();
      int n;
      for (int q = 0; q < NQ; q++) if (cq_on[q]) take_cq(q, n);
    endtask

    // -------------------------------------------------------------------------
    // Admin commands
    // -------------------------------------------------------------------------
    task admin(int which, bit [7:0] opc, bit [31:0] nsid, bit [63:0] prp1, bit [31:0] c10,
               bit [31:0] c11, bit [14:0] want, output bit [31:0] dw0);
      nh_cmd c;
      int    n = 0;
      // The firmware may be waiting for room in a held-back CQ.
      release_cqs();
      ring_all();
      while (sq_room(0) == 0) begin
        poll();
        tick();
        if (++n > timeout) begin err("admin queue never had room"); return; end
      end
      c = put_sqe(0, K_ADMIN, opc, nsid, prp1, 64'd0, c10, c11, 32'd0, want);
      ring_sq(0);
      n_admin++;
      ev(7, (want != ST_OK) ? admin_err_ev(want) : which);
      n = 0;
      while (out.exists(c.cid)) begin
        tick(4);
        poll();
        if (++n > timeout / 4) begin err($sformatf("admin opcode %h never completed", opc)); return; end
      end
      dw0 = res_dw0.exists(c.cid) ? res_dw0[c.cid] : 32'd0;
      res_dw0.delete(c.cid);
    endtask

    // Admin events: 0 Identify, 1 Create I/O CQ, 2 Create I/O SQ, 3 Delete
    // I/O SQ, 4 Delete I/O CQ, 5 Get Features, 6 Set Features; errors 7 Invalid
    // Queue Identifier, 8 Completion Queue Invalid, 9 Invalid Queue Size,
    // 10 Invalid Interrupt Vector, 11 Invalid Queue Deletion, 12 Invalid Field.
    function int admin_err_ev(bit [14:0] st);
      case (st)
        ST_QID:    return 7;
        ST_CQ_INV: return 8;
        ST_QSIZE:  return 9;
        ST_IV:     return 10;
        ST_QDEL:   return 11;
        default:   return 12;
      endcase
    endfunction

    task create_cq(int cq, int size, int vec);
      bit [31:0] dw0;
      clear_cq(cq, size);
      cq_size[cq] = size; cq_head[cq] = 0; cq_ph[cq] = 1'b1; cq_vec[cq] = vec; cq_hold[cq] = 1'b0;
      cq_unrung[cq] = 0;
      admin(1, 8'h05, 32'd0, cq_addr(cq), {16'(size - 1), 16'(cq)}, {16'(vec), 14'd0, 2'b11}, ST_OK, dw0);
      cq_on[cq] = 1'b1;
    endtask

    task create_sq(int q, int size, int cq);
      bit [31:0] dw0;
      sq_size[q] = size; sq_tail[q] = 0; sq_head[q] = 0; sq_out[q] = 0; sq_cq[q] = cq;
      sq_abs_tail[q] = 0; sq_abs_head[q] = 0;
      admin(2, 8'h01, 32'd0, sq_addr(q), {16'(size - 1), 16'(q)}, {16'(cq), 15'd0, 1'b1}, ST_OK, dw0);
      sq_on[q] = 1'b1;
    endtask

    // Wait until nothing is outstanding on SQ q (or anywhere, q < 0).
    task drain(int q = -1);
      int n = 0;
      release_cqs();
      ring_all();
      while ((q < 0) ? (out.size() > 0) : (sq_out[q] > 0)) begin
        tick(4);
        poll();
        if (++n > timeout / 4) begin err($sformatf("%0d commands never completed", out.size())); return; end
      end
    endtask

    task delete_sq(int q);
      bit [31:0] dw0;
      drain(q);
      admin(3, 8'h00, 32'd0, 64'd0, 32'(q), 32'd0, ST_OK, dw0);
      sq_on[q] = 1'b0;
    endtask

    task delete_cq(int cq);
      bit [31:0] dw0;
      admin(4, 8'h04, 32'd0, 64'd0, 32'(cq), 32'd0, ST_OK, dw0);
      cq_on[cq] = 1'b0;
    endtask

    task set_overlap(bit on);
      bit [31:0] dw0;
      admin(6, 8'h09, 32'd0, 64'd0, 32'hC0, {31'd0, on}, ST_OK, dw0);
      overlap = on;
      admin(5, 8'h0A, 32'd0, 64'd0, 32'hC0, 32'd0, ST_OK, dw0);
      if (dw0 != {31'd0, on}) err($sformatf("Get Features 0xC0: DW0 %h after setting %0d", dw0, on));
    endtask

    // -------------------------------------------------------------------------
    // I/O commands
    // -------------------------------------------------------------------------
    // Submit one I/O command of the given kind to SQ q (not rung). Returns 0
    // if it cannot go now: no room in the SQ, no buffer, or its blocks busy
    // (a read waits for writes to its blocks and for them to be known, a
    // write for every command on its blocks).
    function bit io(int q, int kind, int lba, int nblk, int off);
      nh_cmd     c;
      int        len = 512 * nblk, b = -1, pages;
      bit [63:0] prp1 = 64'd0, prp2 = 64'd0;
      bit [7:0]  opc;
      bit [31:0] nsid = 32'd1;
      bit [14:0] want = ST_OK;
      if (sq_room(q) == 0) begin
        ev(4, q);
        n_sq_full++;
        return 1'b0;
      end
      if (kind == K_READ || kind == K_WRITE) begin
        if (free_buf.size() == 0) return 1'b0;
        for (int k = lba; k < lba + nblk; k++) begin
          if (wlock[k] != 0) return 1'b0;
          if (kind == K_WRITE && rlock[k] != 0) return 1'b0;
          if (kind == K_READ && !known[k]) return 1'b0;
        end
      end
      case (kind)
        K_READ:    opc = 8'h02;
        K_WRITE:   opc = 8'h01;
        K_FLUSH:   opc = 8'h00;
        K_BAD_OPC: begin opc = 8'h7F; want = ST_OPC; end
        K_BAD_LBA: begin opc = 8'h02; want = ST_LBA; lba = NSB - 1; nblk = 2; len = 1024; end
        K_BAD_NS:  begin opc = 8'h02; want = ST_NS; nsid = 32'd2; end
        default:   begin opc = 8'h01; want = ST_PRP; end   // K_BAD_PRP: PRP1 not DW aligned
      endcase
      if (kind == K_READ || kind == K_WRITE) begin
        b = free_buf.pop_front();
        prp1 = page(b, 0) + 64'(off);
        pages = (off + len + 4095) / 4096;
        if (pages == 2) prp2 = page(b, 1);
        if (pages > 2) begin
          prp2 = page(b, 5);
          for (int k = 1; k < pages; k++) begin
            bit [63:0] pk = page(b, k);
            int        lo = 8 * k - 8;
            int        hi = lo + 4;
            put_dw(page(b, 5) + 64'(lo), pk[31:0]);
            put_dw(page(b, 5) + 64'(hi), pk[63:32]);
          end
        end
        if (kind == K_WRITE)
          for (int k = 0; k < len; k++) h.hmem[page(b, 0) + 64'(off + k)] = 8'($urandom);
        else
          for (int k = 0; k < len; k++) h.hmem[page(b, 0) + 64'(off + k)] = 8'h5C;
        for (int k = lba; k < lba + nblk; k++) begin
          if (kind == K_WRITE) wlock[k]++;
          else                 rlock[k]++;
        end
        ev(1, (pages == 1) ? 0 : (pages == 2) ? 1 : 2,
           (nblk == 1) ? 0 : (nblk < 8) ? 1 : (nblk == 8) ? 2 : 3);
        if (kind == K_READ) n_reads++;
        else                n_writes++;
      end else if (kind == K_BAD_PRP) begin
        prp1 = page(0, 0) + 64'd2;
      end else if (kind == K_BAD_LBA || kind == K_BAD_NS) begin
        prp1 = page(0, 0);
      end
      if (kind == K_FLUSH) n_flush++;
      c = put_sqe(q, kind, opc, nsid, prp1, prp2, 32'(lba), 32'd0, (kind == K_FLUSH) ? 32'd0 : 32'(nblk - 1), want);
      c.lba = lba; c.nblk = nblk; c.bix = b; c.off = off; c.len = len;
      ev(0, kind, q);
      begin
        int o = out.size();
        ev(6, (o <= 1) ? 0 : (o <= 4) ? 1 : (o <= 15) ? 2 : 3);
      end
      return 1'b1;
    endfunction
  endclass

endpackage
