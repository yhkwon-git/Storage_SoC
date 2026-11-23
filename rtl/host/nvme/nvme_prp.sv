`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// nvme_prp
//
// PRP data transfer engine of the NVMe controller (step 2-3,
// docs/12_nvme_data.md). Firmware gives it the command's PRP1 and PRP2, an
// SRAM address and a length; it moves the data between host memory and SRAM
// with the transaction layer's bus master, one transfer per memory page
// (4 KiB, CC.MPS 0), in the order of the data.
//
//   PRP1   the first page and the offset in it (DW aligned); it holds the
//          first 4096 - offset bytes
//   PRP2   when the rest fits in one page: that page (page aligned);
//          when it does not: a PRP list pointer (8-byte aligned)
//   list   page entries (page aligned), fetched into the local buffer in
//          batches of up to 8 (one bus-master read each). When more entries
//          are needed than are left in a list page, the page's last entry
//          points to the next list page.
//
// A length outside 4 bytes to 128 KiB (cause 8), or an entry with a bad
// offset (cause 9), ends the transfer before or between bus-master
// transfers; a bus-master error ends it with the bus master's cause (1 to
// 7). quit (a controller reset) ends it as soon as no bus-master transfer
// is in flight (cause 10). done pulses with the cause (0 for success).
// -----------------------------------------------------------------------------

module nvme_prp #(
  parameter logic [31:0] LBUF_BASE = 32'h5000_0000
) (
  input  wire           clk,
  input  wire           rst_n,

  input  wire           start,         // pulse, ignored while busy
  input  wire           d2h,           // SRAM to host
  input  wire  [63:0]   prp1,
  input  wire  [63:0]   prp2,
  input  wire  [31:2]   laddr,
  input  wire  [17:2]   len,           // DWs (bytes / 4); 0 is out of range
  input  wire           quit,
  output logic          busy,
  output logic          done,          // pulse
  output logic [3:0]    cause,

  // Bus-master requests
  output logic          bm_valid,
  input  wire           bm_ready,
  output logic          bm_d2h,
  output logic [63:2]   bm_haddr,
  output logic [31:2]   bm_laddr,
  output logic [17:0]   bm_len,
  input  wire           bm_done,
  input  wire  [2:0]    bm_cause,

  // Local buffer side port: PRP list entries in words 0 to 7
  output logic [3:0]    e_raddr,
  input  wire  [63:0]   e_rdata
);

  localparam logic [3:0] C_BADLEN = 4'd8, C_BADPRP = 4'd9, C_ABORT = 4'd10;
  localparam logic [16:0] MAX_DW = 17'd32768;   // 128 KiB

  typedef enum logic [2:0] {S_IDLE, S_REQ, S_WAIT, S_LIST, S_ENTRY, S_END} st_t;
  st_t st;

  logic        x_d2h;
  logic [63:2] x_prp2;
  logic [31:2] x_l;           // next SRAM address
  logic [16:0] x_rem;         // DWs still to move
  logic        x_list;        // PRP2 is a list pointer
  logic        x_second;      // the next chunk is PRP2's page (no list)
  logic [63:3] x_lp;          // next list slot to fetch
  logic [3:0]  x_k;           // entries in the batch in the local buffer
  logic [3:0]  x_i;           // next of them to use
  logic        x_chain;       // the batch's last entry points to the next list page
  logic        x_fetch;       // the request in flight fetches list entries
  logic [63:2] c_h;           // chunk: host address
  logic [10:0] c_n;           // chunk: DWs (1 to 1024)

  // Pages of data still to come, and list slots left in the list page.
  wire [6:0]  pages_left = 7'((x_rem + 17'd1023) >> 10);
  wire [9:0]  slots_left = 10'd512 - {1'b0, x_lp[11:3]};
  wire [9:0]  in_page    = ({3'd0, pages_left} > slots_left) ? slots_left : {3'd0, pages_left};
  wire [3:0]  batch      = (in_page > 10'd8) ? 4'd8 : in_page[3:0];
  wire        chains     = ({3'd0, pages_left} > slots_left) && (in_page <= 10'd8);

  // First chunk: up to the end of PRP1's page.
  wire [10:0] first_room = 11'd1024 - {1'b0, prp1[11:2]};
  wire [16:0] first_n    = ({1'b0, len} < {6'd0, first_room}) ? {1'b0, len} : {6'd0, first_room};
  wire [16:0] rest       = {1'b0, len} - first_n;

  wire [10:0] next_n     = (x_rem < 17'd1024) ? x_rem[10:0] : 11'd1024;

  assign e_raddr = x_i;

  assign bm_valid = (st == S_REQ);
  assign bm_d2h   = x_fetch ? 1'b0 : x_d2h;
  assign bm_haddr = x_fetch ? {x_lp, 1'b0} : c_h;
  assign bm_laddr = x_fetch ? LBUF_BASE[31:2] : x_l;
  assign bm_len   = x_fetch ? {13'd0, x_k, 1'b0} : {7'd0, c_n};

  assign busy = (st != S_IDLE);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st       <= S_IDLE;
      done     <= 1'b0;
      cause    <= 4'd0;
      x_d2h    <= 1'b0;
      x_prp2   <= '0;
      x_l      <= '0;
      x_rem    <= '0;
      x_list   <= 1'b0;
      x_second <= 1'b0;
      x_lp     <= '0;
      x_k      <= 4'd0;
      x_i      <= 4'd0;
      x_chain  <= 1'b0;
      x_fetch  <= 1'b0;
      c_h      <= '0;
      c_n      <= 11'd0;
    end else begin
      done <= 1'b0;
      case (st)
        S_IDLE: if (start) begin
          x_d2h  <= d2h;
          x_prp2 <= prp2[63:2];
          x_lp   <= prp2[63:3];
          x_fetch <= 1'b0;
          x_k    <= 4'd0;
          x_i    <= 4'd0;
          if (len == 16'd0 || {1'b0, len} > MAX_DW) begin
            cause <= C_BADLEN;
            st    <= S_END;
          end else if (prp1[1:0] != 2'b00 ||
                       (rest != 17'd0 && rest <= 17'd1024 && prp2[11:0] != 12'd0) ||
                       (rest > 17'd1024 && prp2[2:0] != 3'd0)) begin
            cause <= C_BADPRP;
            st    <= S_END;
          end else begin
            c_h      <= prp1[63:2];
            c_n      <= first_n[10:0];
            x_l      <= laddr;
            x_rem    <= {1'b0, len};
            x_list   <= (rest > 17'd1024);
            x_second <= (rest != 17'd0) && (rest <= 17'd1024);
            cause    <= 4'd0;
            st       <= S_REQ;
          end
        end

        // A request not yet taken may be withdrawn: the requester arbiter in
        // nvme_ctrl is not an AXI channel.
        S_REQ: if (bm_ready) begin
          st <= S_WAIT;
        end else if (quit) begin
          cause <= C_ABORT;
          st    <= S_END;
        end

        S_WAIT: if (bm_done) begin
          if (bm_cause != 3'd0) begin
            cause <= {1'b0, bm_cause};
            st    <= S_END;
          end else if (quit) begin
            cause <= C_ABORT;
            st    <= S_END;
          end else if (x_fetch) begin
            // A batch of list entries is in the local buffer.
            x_fetch <= 1'b0;
            x_i     <= 4'd0;
            st      <= S_ENTRY;
          end else begin
            // A chunk of data moved.
            x_l   <= x_l + {19'd0, c_n};
            x_rem <= x_rem - {6'd0, c_n};
            if (x_rem == {6'd0, c_n}) begin
              st <= S_END;
            end else if (x_second) begin
              x_second <= 1'b0;
              c_h      <= x_prp2;
              c_n      <= 11'(x_rem - {6'd0, c_n});
              st       <= S_REQ;
            end else if (x_list && x_i == x_k) begin
              st <= S_LIST;
            end else begin
              st <= S_ENTRY;
            end
          end
        end

        // Fetch the next batch of list entries. (A quit here, or in
        // S_ENTRY, is taken in S_REQ or after the transfer, one clock on.)
        S_LIST: begin
          x_k     <= batch;
          x_chain <= chains;
          x_fetch <= 1'b1;
          st      <= S_REQ;
        end

        // Use entry x_i of the batch (S_WAIT goes to S_LIST once all are used).
        S_ENTRY: if (x_chain && x_i == x_k - 4'd1) begin
          // Pointer to the next list page.
          if (e_rdata[2:0] != 3'd0) begin
            cause <= C_BADPRP;
            st    <= S_END;
          end else begin
            x_lp <= e_rdata[63:3];
            st   <= S_LIST;
          end
        end else if (e_rdata[11:0] != 12'd0) begin
          cause <= C_BADPRP;
          st    <= S_END;
        end else begin
          c_h  <= e_rdata[63:2];
          c_n  <= next_n;
          x_i  <= x_i + 4'd1;
          // the slot after this batch
          if (x_i == x_k - 4'd1) x_lp <= x_lp + {57'd0, x_k};
          st   <= S_REQ;
        end

        default: begin  // S_END
          done <= 1'b1;
          st   <= S_IDLE;
        end
      endcase
    end
  end

endmodule : nvme_prp

`default_nettype wire
