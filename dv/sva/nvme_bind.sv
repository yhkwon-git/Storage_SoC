// Binds nvme_checker (dv/sva/nvme_checker.sv) into every nvme_ctrl.

bind nvme_ctrl nvme_checker #(.NQ(NQ), .NSLOT(NSLOT)) u_nvme_chk (
  .clk (clk), .rst_n (rst_n), .c_st (c_st), .epoch (epoch),
  .sq_head (sq_head), .sq_tail (sq_tail), .cq_head (cq_head), .cq_tail (cq_tail),
  .sq_size (sq_size), .cq_size (cq_size), .cq_phase (cq_phase), .sq_en (sq_en), .cq_en (cq_en),
  .can_fetch (can_fetch), .pick (pick),
  .c_adv (c_adv), .c_cq (c_cq), .c_tail (c_tail), .c_head (c_head), .c_size (c_size),
  .f_busy (f_busy), .p_busy (p_busy), .c_active (c_active), .xf_start (xf_start), .c_post (c_post),
  .slot_free (slot_free), .cf_count (cf_count), .msix_req (msix_req)
);
