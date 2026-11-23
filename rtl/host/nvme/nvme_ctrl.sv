`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// nvme_ctrl
//
// NVMe-style controller registers and queues (step 2-2, docs/11_nvme_queues.md),
// in clk_sys next to the transaction layer.
//
// Host side, BAR0 0x0000-0x1FFF through the transaction layer's register port
// (one DW per write, two DWs readable at once):
//   0x00 CAP (64-bit)  MQES 1023, CQR, TO 1, DSTRD 0, CSS NVM, MPSMIN/MAX 4 KiB
//   0x08 VS            1.4.0
//   0x0C INTMS, 0x10 INTMC, 0x20 NSSR: read 0, writes ignored (MSI-X only)
//   0x14 CC            EN, CSS, MPS, AMS, SHN, IOSQES, IOCQES
//   0x1C CSTS          RDY, CFS, SHST
//   0x24 AQA, 0x28 ASQ (64-bit), 0x30 ACQ (64-bit)
//   0x1000 + 8y        submission queue y tail doorbell, y = 0..4
//   0x1004 + 8y        completion queue y head doorbell
//
// Controller enable follows CC.EN as a level. With EN set and the controller
// off, the admin queue pair (queue 0) is loaded from AQA, ASQ and ACQ and
// CSTS.RDY rises. With EN clear and the controller on, fetching stops; once
// no fetch is in flight, every queue is deleted (I/O queue enables cleared),
// waiting commands are dropped, every command buffer slot is freed, and RDY
// falls. CC.SHN, written while the controller is on, sets SHST to
// "processing", and to "complete" once no fetch is in flight.
//
// Queues 1 to 4 are set up by firmware in nvme_regs (APB slot 8) as it handles
// the admin commands that create them; enabling a queue sets its pointers to
// 0 (a completion queue's phase to 1). A doorbell write to a queue that is not
// enabled, or with a value beyond its size, is ignored and reported (EVENT
// DB_ERR, DB_ERR).
//
// Fetch: the submission queues with entries between head and tail are served
// round robin, one command per turn. A command is fetched when a command
// buffer slot is free: one 64-byte memory read through the transaction
// layer's bus master, host address SQ base + 64 x head, into SRAM at CMDBUF +
// 64 x slot. When it completes, {queue, slot} goes into the command FIFO that
// firmware reads through CMD, and the head moves on. Firmware returns the slot
// with SLOT_FREE. A fetch that fails (an error completion, a timeout) sets
// CSTS.CFS and stops fetching until the next controller reset.
// -----------------------------------------------------------------------------

module nvme_ctrl #(
  parameter int NSLOT = 16
) (
  input  wire           clk,
  input  wire           rst_n,

  // Firmware side: APB slot 8
  input  wire           psel,
  input  wire           penable,
  input  wire  [11:0]   paddr,
  input  wire           pwrite,
  input  wire  [31:0]   pwdata,
  input  wire  [3:0]    pstrb,
  output logic [31:0]   prdata,
  output logic          pready,
  output logic          pslverr,

  // Host side: BAR0 0x0000-0x1FFF from the transaction layer
  input  wire           reg_we,
  input  wire  [10:0]   reg_dw,
  input  wire  [3:0]    reg_be,
  input  wire  [31:0]   reg_wdata,
  output logic [31:0]   reg_rd0,       // DW reg_dw
  output logic [31:0]   reg_rd1,       // DW reg_dw + 1

  // Bus master requests (tl_core's NVMe port)
  output logic          bm_valid,
  input  wire           bm_ready,
  output logic          bm_d2h,
  output logic [63:2]   bm_haddr,
  output logic [31:2]   bm_laddr,
  output logic [17:0]   bm_len,
  input  wire           bm_done,
  input  wire  [2:0]    bm_cause,

  output logic          irq,           // INTC source 3
  output logic          idle
);

  localparam int NQ = 5;
  localparam int SW = $clog2(NSLOT);

  // ---------------------------------------------------------------------------
  // Firmware registers
  // ---------------------------------------------------------------------------
  nvme_regs_pkg::nvme_regs__in_t  hwif_in;
  nvme_regs_pkg::nvme_regs__out_t hwif_out;

  nvme_regs u_regs (
    .clk           (clk),
    .arst_n        (rst_n),
    .s_apb_psel    (psel),
    .s_apb_penable (penable),
    .s_apb_pwrite  (pwrite),
    .s_apb_pprot   (3'b000),
    .s_apb_paddr   (paddr),
    .s_apb_pwdata  (pwdata),
    .s_apb_pstrb   (pstrb),
    .s_apb_pready  (pready),
    .s_apb_prdata  (prdata),
    .s_apb_pslverr (pslverr),
    .hwif_in       (hwif_in),
    .hwif_out      (hwif_out)
  );

  // ---------------------------------------------------------------------------
  // Host registers
  // ---------------------------------------------------------------------------
  localparam logic [31:0] CAP_LO = {8'd1, 5'd0, 2'b00, 1'b1, 16'd1023};  // TO 1, CQR, MQES 1023
  localparam logic [31:0] CAP_HI = 32'h0000_0020;                         // CSS: NVM command set
  localparam logic [31:0] VS     = 32'h0001_0400;
  localparam logic [31:0] CC_RW  = 32'h00FF_FFF1;
  localparam logic [31:0] AQA_RW = 32'h0FFF_0FFF;

  logic [31:0] cc, aqa, asq_lo, asq_hi, acq_lo, acq_hi;
  logic        rdy, cfs;
  logic [1:0]  shst;

  wire [31:0] m = {{8{reg_be[3]}}, {8{reg_be[2]}}, {8{reg_be[1]}}, {8{reg_be[0]}}};

  function automatic logic [31:0] host_rd(input logic [10:0] dw, input logic [31:0] cc_v,
                                          input logic [31:0] csts_v, input logic [31:0] aqa_v,
                                          input logic [31:0] asql, input logic [31:0] asqh,
                                          input logic [31:0] acql, input logic [31:0] acqh);
    case (dw)
      11'd0:   return CAP_LO;
      11'd1:   return CAP_HI;
      11'd2:   return VS;
      11'd5:   return cc_v;
      11'd7:   return csts_v;
      11'd9:   return aqa_v;
      11'd10:  return asql;
      11'd11:  return asqh;
      11'd12:  return acql;
      11'd13:  return acqh;
      default: return 32'd0;   // INTMS, INTMC, NSSR, reserved, doorbells
    endcase
  endfunction

  wire [31:0] csts = {26'd0, 1'b0, 1'b0, shst, cfs, rdy};

  assign reg_rd0 = host_rd(reg_dw,          cc, csts, aqa, asq_lo, asq_hi, acq_lo, acq_hi);
  assign reg_rd1 = host_rd(reg_dw + 11'd1,  cc, csts, aqa, asq_lo, asq_hi, acq_lo, acq_hi);

  // Doorbell writes: DW 0x400 + 2y (SQ tail) and 0x401 + 2y (CQ head).
  wire        db_w   = reg_we && (reg_dw[10:4] == 7'h40) && (reg_dw[3:0] < 4'd10);
  wire [2:0]  db_q   = reg_dw[3:1];
  wire        db_cq  = reg_dw[0];
  wire [15:0] db_val = reg_wdata[15:0];

  // ---------------------------------------------------------------------------
  // Queue state
  // ---------------------------------------------------------------------------
  logic [11:0] sq_head [NQ];
  logic [11:0] sq_tail [NQ];
  logic [11:0] cq_head [NQ];
  logic [11:0] cq_tail [NQ];
  logic        cq_phase[NQ];

  // Configuration: queue 0 from the admin registers loaded at enable, queues
  // 1 to 4 from firmware.
  logic [63:12] adm_sqb, adm_cqb;
  logic [11:0]  adm_sqs, adm_cqs;

  typedef enum logic [1:0] {C_OFF, C_ON, C_RESET} cst_t;
  cst_t c_st;

  logic [NQ-1:0] sq_en, cq_en;
  logic [11:0]   sq_size [NQ];
  logic [11:0]   cq_size [NQ];
  logic [63:12]  sq_base [NQ];

  always_comb begin
    sq_en[0]   = (c_st == C_ON);
    cq_en[0]   = (c_st == C_ON);
    sq_size[0] = adm_sqs;
    cq_size[0] = adm_cqs;
    sq_base[0] = adm_sqb;
    for (int i = 1; i < NQ; i++) begin
      sq_en[i]   = (c_st == C_ON) && hwif_out.IOQ[i-1].SQ_CFG.en.value;
      cq_en[i]   = (c_st == C_ON) && hwif_out.IOQ[i-1].CQ_CFG.en.value;
      sq_size[i] = hwif_out.IOQ[i-1].SQ_CFG.size.value;
      cq_size[i] = hwif_out.IOQ[i-1].CQ_CFG.size.value;
      sq_base[i] = {hwif_out.IOQ[i-1].SQB_HI.base.value, hwif_out.IOQ[i-1].SQB_LO.base.value};
    end
  end

  // Enable edges of the I/O queues reset their pointers.
  logic [NQ-1:1] sq_en_q, cq_en_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sq_en_q <= '0;
      cq_en_q <= '0;
    end else begin
      sq_en_q <= sq_en[NQ-1:1];
      cq_en_q <= cq_en[NQ-1:1];
    end
  end

  // Doorbell checks: the queue is enabled and the value is below its size.
  wire db_ok = db_cq ? (cq_en[db_q] && (db_val <= {4'd0, cq_size[db_q]}))
                     : (sq_en[db_q] && (db_val <= {4'd0, sq_size[db_q]}));

  // ---------------------------------------------------------------------------
  // Command buffer slots and the command FIFO
  // ---------------------------------------------------------------------------
  logic [NSLOT-1:0] slot_free;
  logic [SW-1:0]    alloc;
  logic             have_slot;
  always_comb begin
    alloc     = '0;
    have_slot = 1'b0;
    for (int i = NSLOT - 1; i >= 0; i--) begin
      if (slot_free[i]) begin
        alloc     = SW'(i);
        have_slot = 1'b1;
      end
    end
  end

  // Command FIFO: {queue, slot}, one entry per slot in use, so it never
  // overflows. A controller reset empties it in one clock.
  logic          cf_push, cf_pop, cf_empty, cf_flush;
  logic [SW+2:0] cf_din, cf_dout;
  logic [SW+2:0] cf_mem [NSLOT];
  logic [SW:0]   cf_wp, cf_rp;
  wire  [SW:0]   cf_count = cf_wp - cf_rp;

  assign cf_empty = (cf_wp == cf_rp);
  assign cf_dout  = cf_mem[cf_rp[SW-1:0]];
  assign cf_pop   = hwif_out.CMD.slot.swacc && !cf_empty;

  always_ff @(posedge clk) if (cf_push) cf_mem[cf_wp[SW-1:0]] <= cf_din;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cf_wp <= '0;
      cf_rp <= '0;
    end else if (cf_flush) begin
      cf_wp <= '0;
      cf_rp <= '0;
    end else begin
      if (cf_push) cf_wp <= cf_wp + 1'b1;
      if (cf_pop)  cf_rp <= cf_rp + 1'b1;
    end
  end

  // SLOT_FREE, like a TX write, is used one clock after the write.
  logic free_wr;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) free_wr <= 1'b0;
    else        free_wr <= hwif_out.SLOT_FREE.slot.swmod;
  end
  wire [SW-1:0] free_slot = hwif_out.SLOT_FREE.slot.value[SW-1:0];

  // ---------------------------------------------------------------------------
  // Fetch engine
  // ---------------------------------------------------------------------------
  logic [NQ-1:0] pending;
  always_comb
    for (int i = 0; i < NQ; i++) pending[i] = sq_en[i] && (sq_head[i] != sq_tail[i]);

  logic [2:0] rr;          // queue served last
  logic [2:0] pick;
  logic       any;
  always_comb begin
    pick = 3'd0;
    any  = 1'b0;
    for (int k = NQ; k >= 1; k--) begin
      logic [2:0] q;
      q = 3'((int'(rr) + k) % NQ);
      if (pending[q]) begin
        pick = 3'(q);
        any  = 1'b1;
      end
    end
  end

  logic          f_busy;     // a fetch is in flight
  logic          f_req;      // its request waits for the bus master
  logic [2:0]    f_q;
  logic [SW-1:0] f_slot;
  logic [63:2]   f_haddr;
  logic [31:0]   n_fetch;

  wire can_fetch = (c_st == C_ON) && !cfs && (shst == 2'b00) && any && have_slot && !f_busy;

  assign bm_valid = f_req;
  assign bm_d2h   = 1'b0;
  assign bm_haddr = f_haddr;
  assign bm_laddr = {hwif_out.CMDBUF.base.value, f_slot, 4'd0};
  assign bm_len   = 18'd16;

  // ---------------------------------------------------------------------------
  // Controller state and queue pointers
  // ---------------------------------------------------------------------------
  wire [11:0] next_head = (sq_head[f_q] == sq_size[f_q]) ? 12'd0 : sq_head[f_q] + 12'd1;
  wire        f_ok      = bm_done && (bm_cause == 3'd0) && (c_st == C_ON);

  logic ev_enable, ev_reset, ev_shut, ev_fetch_err, ev_db;
  logic clr_ioq;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cc <= 32'd0; aqa <= 32'd0; asq_lo <= 32'd0; asq_hi <= 32'd0; acq_lo <= 32'd0; acq_hi <= 32'd0;
      rdy <= 1'b0; cfs <= 1'b0; shst <= 2'b00;
      c_st <= C_OFF;
      adm_sqb <= '0; adm_cqb <= '0; adm_sqs <= 12'd0; adm_cqs <= 12'd0;
      for (int i = 0; i < NQ; i++) begin
        sq_head[i] <= 12'd0; sq_tail[i] <= 12'd0;
        cq_head[i] <= 12'd0; cq_tail[i] <= 12'd0; cq_phase[i] <= 1'b1;
      end
      slot_free <= '1;
      f_busy <= 1'b0; f_req <= 1'b0; f_q <= 3'd0; f_slot <= '0; f_haddr <= '0;
      rr <= 3'(NQ - 1);
      n_fetch <= 32'd0;
      ev_enable <= 1'b0; ev_reset <= 1'b0; ev_shut <= 1'b0; ev_fetch_err <= 1'b0; ev_db <= 1'b0;
      clr_ioq <= 1'b0;
      cf_flush <= 1'b0;
    end else begin
      ev_enable <= 1'b0; ev_reset <= 1'b0; ev_shut <= 1'b0; ev_fetch_err <= 1'b0; ev_db <= 1'b0;
      clr_ioq  <= 1'b0;
      cf_flush <= 1'b0;

      // Host register writes
      if (reg_we) begin
        case (reg_dw)
          11'd5: begin
            cc <= ((cc & ~m) | (reg_wdata & m)) & CC_RW;
            if (reg_be[1] && reg_wdata[15:14] != 2'b00 && shst == 2'b00 && cc[15:14] == 2'b00 &&
                c_st == C_ON) begin
              shst   <= 2'b01;
              ev_shut <= 1'b1;
            end
          end
          11'd9:  aqa    <= ((aqa & ~m) | (reg_wdata & m)) & AQA_RW;
          11'd10: asq_lo <= ((asq_lo & ~m) | (reg_wdata & m)) & 32'hFFFF_F000;
          11'd11: asq_hi <= (asq_hi & ~m) | (reg_wdata & m);
          11'd12: acq_lo <= ((acq_lo & ~m) | (reg_wdata & m)) & 32'hFFFF_F000;
          11'd13: acq_hi <= (acq_hi & ~m) | (reg_wdata & m);
          default: ;
        endcase
      end
      if (db_w) begin
        if (!db_ok)      ev_db <= 1'b1;
        else if (db_cq)  cq_head[db_q] <= db_val[11:0];
        else             sq_tail[db_q] <= db_val[11:0];
      end

      // Shutdown completes once no fetch is in flight.
      if (shst == 2'b01 && !f_busy) shst <= 2'b10;

      // Controller enable and reset, CC.EN as a level
      case (c_st)
        C_OFF: if (cc[0]) begin
          adm_sqb <= {asq_hi, asq_lo[31:12]};
          adm_cqb <= {acq_hi, acq_lo[31:12]};
          adm_sqs <= aqa[11:0];
          adm_cqs <= aqa[27:16];
          sq_head[0] <= 12'd0; sq_tail[0] <= 12'd0;
          cq_head[0] <= 12'd0; cq_tail[0] <= 12'd0; cq_phase[0] <= 1'b1;
          rdy       <= 1'b1;
          ev_enable <= 1'b1;
          c_st      <= C_ON;
        end
        C_ON: if (!cc[0]) c_st <= C_RESET;
        default: if (!f_busy) begin  // C_RESET
          for (int i = 0; i < NQ; i++) begin
            sq_head[i] <= 12'd0; sq_tail[i] <= 12'd0;
            cq_head[i] <= 12'd0; cq_tail[i] <= 12'd0; cq_phase[i] <= 1'b1;
          end
          slot_free <= '1;
          cf_flush  <= 1'b1;
          clr_ioq   <= 1'b1;
          rdy <= 1'b0; cfs <= 1'b0; shst <= 2'b00;
          ev_reset <= 1'b1;
          c_st     <= C_OFF;
        end
      endcase

      // An I/O queue enabled by firmware starts empty.
      for (int i = 1; i < NQ; i++) begin
        if (sq_en[i] && !sq_en_q[i]) begin sq_head[i] <= 12'd0; sq_tail[i] <= 12'd0; end
        if (cq_en[i] && !cq_en_q[i]) begin
          cq_head[i] <= 12'd0; cq_tail[i] <= 12'd0; cq_phase[i] <= 1'b1;
        end
      end

      // Fetch
      if (can_fetch) begin
        f_busy  <= 1'b1;
        f_req   <= 1'b1;
        f_q     <= pick;
        f_slot  <= alloc;
        f_haddr <= {sq_base[pick], 10'd0} + {50'd0, sq_head[pick]} * 62'd16;
        slot_free[alloc] <= 1'b0;
        rr      <= pick;
      end
      if (f_req && bm_ready) f_req <= 1'b0;
      if (bm_done && f_busy) begin
        f_busy <= 1'b0;
        if (f_ok) begin
          sq_head[f_q] <= next_head;
          n_fetch      <= n_fetch + 32'd1;
        end else begin
          slot_free[f_slot] <= 1'b1;
          if (bm_cause != 3'd0) begin
            cfs          <= 1'b1;
            ev_fetch_err <= 1'b1;
          end
        end
      end
      if (free_wr && c_st != C_RESET) slot_free[free_slot] <= 1'b1;
    end
  end

  assign cf_push = bm_done && f_busy && f_ok;
  assign cf_din  = {f_q, f_slot};

  // ---------------------------------------------------------------------------
  // Firmware register inputs
  // ---------------------------------------------------------------------------
  logic [SW:0] n_free;
  always_comb begin
    n_free = '0;
    for (int i = 0; i < NSLOT; i++) n_free = n_free + (SW+1)'(slot_free[i]);
  end

  always_comb begin
    hwif_in.STATUS.rdy.next  = rdy;
    hwif_in.STATUS.cfs.next  = cfs;
    hwif_in.STATUS.en.next   = cc[0];
    hwif_in.STATUS.shst.next = shst;
    hwif_in.STATUS.cmds.next = 5'(cf_count);
    hwif_in.STATUS.free.next = 5'(n_free);

    hwif_in.EVENT.enable.hwset    = ev_enable;
    hwif_in.EVENT.reset.hwset     = ev_reset;
    hwif_in.EVENT.shutdown.hwset  = ev_shut;
    hwif_in.EVENT.db_err.hwset    = ev_db;
    hwif_in.EVENT.fetch_err.hwset = ev_fetch_err;

    hwif_in.CC.value.next     = cc;
    hwif_in.AQA.value.next    = aqa;
    hwif_in.ASQ_LO.value.next = asq_lo;
    hwif_in.ASQ_HI.value.next = asq_hi;
    hwif_in.ACQ_LO.value.next = acq_lo;
    hwif_in.ACQ_HI.value.next = acq_hi;

    hwif_in.CMD.slot.next  = cf_empty ? 4'd0 : 4'(cf_dout[SW-1:0]);
    hwif_in.CMD.sqid.next  = cf_empty ? 3'd0 : cf_dout[SW+2:SW];
    hwif_in.CMD.valid.next = !cf_empty;

    hwif_in.DB_ERR.qid.next   = db_q;
    hwif_in.DB_ERR.qid.we     = db_w && !db_ok;
    hwif_in.DB_ERR.cq.next    = db_cq;
    hwif_in.DB_ERR.cq.we      = db_w && !db_ok;
    hwif_in.DB_ERR.value.next = db_val;
    hwif_in.DB_ERR.value.we   = db_w && !db_ok;

    hwif_in.FETCHES.count.next = n_fetch;

    for (int i = 0; i < NQ - 1; i++) begin
      hwif_in.IOQ[i].SQ_CFG.en.hwclr = clr_ioq;
      hwif_in.IOQ[i].CQ_CFG.en.hwclr = clr_ioq;
    end
    for (int i = 0; i < NQ; i++) begin
      hwif_in.SQ_PTR[i].head.next  = sq_head[i];
      hwif_in.SQ_PTR[i].tail.next  = sq_tail[i];
      hwif_in.CQ_PTR[i].head.next  = cq_head[i];
      hwif_in.CQ_PTR[i].tail.next  = cq_tail[i];
      hwif_in.CQ_PTR[i].phase.next = cq_phase[i];
    end
  end

  assign irq  = (hwif_out.CTRL.ien_cmd.value && !cf_empty) ||
                |({hwif_out.EVENT.fetch_err.value, hwif_out.EVENT.db_err.value,
                   hwif_out.EVENT.shutdown.value, hwif_out.EVENT.reset.value,
                   hwif_out.EVENT.enable.value} & hwif_out.EVENT_EN.en.value);
  assign idle = !f_busy;

  // Completion queue bases and interrupt settings, and a submission queue's
  // completion queue, are used from step 2-3 on.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [NQ-2:0] unused_cq;
  always_comb
    for (int i = 0; i < NQ - 1; i++)
      unused_cq[i] = ^{hwif_out.IOQ[i].CQB_LO.base.value, hwif_out.IOQ[i].CQB_HI.base.value,
                       hwif_out.IOQ[i].CQ_CFG.iv.value, hwif_out.IOQ[i].CQ_CFG.ien.value,
                       hwif_out.IOQ[i].SQ_CFG.cqid.value};
  wire unused_ok = ^{adm_cqb, reg_wdata[31:16], unused_cq};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule : nvme_ctrl

`default_nettype wire
