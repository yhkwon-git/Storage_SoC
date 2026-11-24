`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// nvme_checker
//
// Assertions on the NVMe controller's queue state (step 2-5,
// docs/14_nvme_host_verification.md), bound into every nvme_ctrl by
// dv/sva/nvme_bind.sv in tb_nvme and tb_soc. They hold whatever the host and
// the firmware do:
//   - pointers of an enabled queue stay below its size;
//   - an SQ head moves by one (wrapping) or to 0, never anywhere else, and a
//     fetch reads only a queue with an entry between head and tail;
//   - a CQ tail moves by one only when an entry has been written, an entry is
//     written only with room for it, and the phase tag flips only where the
//     tail goes back to 0;
//   - the commands waiting for firmware never outnumber the slots in use;
//   - the epoch moves only by one, and only as a controller reset completes;
//   - with the controller off nothing is fetched, moved or written, and no
//     transfer starts and no entry is posted unless the controller is on;
//   - a completion queue's MSI-X request follows the write of an entry.
// -----------------------------------------------------------------------------

module nvme_checker #(
  parameter int NQ    = 5,
  parameter int NSLOT = 16,
  localparam int SW   = $clog2(NSLOT)
) (
  input wire               clk,
  input wire               rst_n,
  input wire  [1:0]        c_st,            // 0 off, 1 on, 2 resetting
  input wire  [3:0]        epoch,
  input wire  [11:0]       sq_head  [NQ],
  input wire  [11:0]       sq_tail  [NQ],
  input wire  [11:0]       cq_head  [NQ],
  input wire  [11:0]       cq_tail  [NQ],
  input wire  [11:0]       sq_size  [NQ],
  input wire  [11:0]       cq_size  [NQ],
  input wire               cq_phase [NQ],
  input wire  [NQ-1:0]     sq_en,
  input wire  [NQ-1:0]     cq_en,
  input wire               can_fetch,
  input wire  [2:0]        pick,
  input wire               c_adv,
  input wire  [2:0]        c_cq,
  input wire  [11:0]       c_tail,
  input wire  [11:0]       c_head,
  input wire  [11:0]       c_size,
  input wire               f_busy,
  input wire               p_busy,
  input wire               c_active,
  input wire               xf_start,
  input wire               c_post,
  input wire  [NSLOT-1:0]  slot_free,
  input wire  [SW:0]       cf_count,
  input wire               msix_req
);

  localparam logic [1:0] OFF = 2'd0, ON = 2'd1, RST = 2'd2;

  // Same-clock rules, as concurrent assertions.
  default clocking cb @(posedge clk); endclocking
  default disable iff (!rst_n);

  a_fetch_nonempty: assert property (can_fetch |-> sq_en[pick] && sq_head[pick] != sq_tail[pick])
    else $error("[NVME-SVA] fetch from queue %0d with head %0d = tail", pick, sq_head[pick]);
  a_slots: assert property (32'(cf_count) + 32'($countones(slot_free)) <= NSLOT)
    else $error("[NVME-SVA] %0d commands wait with %0d slots free", cf_count, $countones(slot_free));
  a_cq_room: assert property (c_adv |-> ((c_tail == c_size) ? 12'd0 : c_tail + 12'd1) != c_head)
    else $error("[NVME-SVA] entry written into a full CQ%0d (tail %0d, head %0d)", c_cq, c_tail, c_head);
  a_off_idle: assert property (c_st == OFF |-> !f_busy && !p_busy && !c_active)
    else $error("[NVME-SVA] engine busy with the controller off");
  a_start_on: assert property (xf_start |-> c_st == ON)
    else $error("[NVME-SVA] transfer started with the controller in state %0d", c_st);
  a_post_on: assert property (c_post |-> c_st == ON)
    else $error("[NVME-SVA] entry posted with the controller in state %0d", c_st);
  for (genvar q = 0; q < NQ; q++) begin : g_range
    a_sq_range: assert property (sq_en[q] |-> sq_head[q] <= sq_size[q] && sq_tail[q] <= sq_size[q])
      else $error("[NVME-SVA] SQ%0d head %0d tail %0d size %0d", q, sq_head[q], sq_tail[q], sq_size[q] + 12'd1);
    a_cq_range: assert property (cq_en[q] |-> cq_head[q] <= cq_size[q] && cq_tail[q] <= cq_size[q])
      else $error("[NVME-SVA] CQ%0d head %0d tail %0d size %0d", q, cq_head[q], cq_tail[q], cq_size[q] + 12'd1);
  end

  // Rules across clocks. They are checked at each clock edge on the values
  // before that edge's updates, against the values one clock earlier kept
  // here (Verilator's $past of an array port element is not usable).
  logic [11:0] p_sqh [NQ];
  logic [11:0] p_cqt [NQ];
  logic        p_ph  [NQ];
  logic        p_adv, p_wrap, p_msix, p_init;
  logic [2:0]  p_cq;
  logic [3:0]  p_ep;
  logic [1:0]  p_st;

  always @(posedge clk) begin
    if (!rst_n) begin
      p_init = 1'b0;
    end else begin
      if (p_init) begin
        for (int q = 0; q < NQ; q++) begin
          if (sq_head[q] != p_sqh[q])
            a_sq_head_step: assert (sq_head[q] == 12'd0 || sq_head[q] == p_sqh[q] + 12'd1)
              else $error("[NVME-SVA] SQ%0d head %0d -> %0d", q, p_sqh[q], sq_head[q]);
          if (cq_tail[q] != p_cqt[q])
            a_cq_tail_step: assert (cq_tail[q] == 12'd0 ||
                                    (p_adv && p_cq == 3'(q) && cq_tail[q] == p_cqt[q] + 12'd1))
              else $error("[NVME-SVA] CQ%0d tail %0d -> %0d", q, p_cqt[q], cq_tail[q]);
          if (cq_phase[q] != p_ph[q])
            a_phase: assert (cq_tail[q] == 12'd0 && (cq_phase[q] || (p_wrap && p_cq == 3'(q))))
              else $error("[NVME-SVA] CQ%0d phase flipped to %0d away from a wrap", q, cq_phase[q]);
        end
        if (epoch != p_ep)
          a_epoch: assert (p_st == RST && c_st == OFF && epoch == p_ep + 4'd1)
            else $error("[NVME-SVA] epoch %0d -> %0d outside a controller reset", p_ep, epoch);
        if (msix_req && !p_msix)
          a_msix_after_entry: assert (p_adv)
            else $error("[NVME-SVA] MSI-X request without an entry written");
      end
      for (int q = 0; q < NQ; q++) begin
        p_sqh[q] = sq_head[q];
        p_cqt[q] = cq_tail[q];
        p_ph[q]  = cq_phase[q];
      end
      p_adv  = c_adv;
      p_wrap = c_adv && (c_tail == c_size);
      p_cq   = c_cq;
      p_msix = msix_req;
      p_ep   = epoch;
      p_st   = c_st;
      p_init = 1'b1;
    end
  end

endmodule : nvme_checker

`default_nettype wire
