`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// axi2apb
//
// AXI4 slave (64-bit) to an APB4 bus (32-bit) with NSLOT peripherals of 4 KiB
// each: slot = address[15:12] within the 64 KiB APB window.
//
// One AXI transaction at a time, writes first when both are waiting. Each
// beat becomes APB transfers of one 32-bit word each:
//   * a narrow beat (AxSIZE = 2): the one word it addresses
//   * a 64-bit beat, read: both words, lower first
//   * a 64-bit beat, write: each word with a non-zero strobe, lower first
// Bursts of 64-bit beats step through the words in order.
//
// A slot whose SLOT_EN bit is clear answers without an APB transfer: read
// data 0 and an error. Any APB error (PSLVERR) or missing slot in a beat makes
// that R beat, or the transaction's B, SLVERR.
//
// Registers with read side effects must be read with 32-bit accesses, since a
// 64-bit read touches both words.
// -----------------------------------------------------------------------------

module axi2apb #(
  parameter  int               IDW     = 4,
  parameter  int               NSLOT   = 8,
  parameter  logic [NSLOT-1:0] SLOT_EN = '1,
  localparam int               SW      = (NSLOT > 1) ? $clog2(NSLOT) : 1
) (
  input  wire                        clk,
  input  wire                        rst_n,

  input  wire  [IDW-1:0]             s_awid,
  input  wire  [31:0]                s_awaddr,
  input  wire  [7:0]                 s_awlen,
  input  wire  [2:0]                 s_awsize,
  input  wire  [2:0]                 s_awprot,
  input  wire                        s_awvalid,
  output logic                       s_awready,
  input  wire  [63:0]                s_wdata,
  input  wire  [7:0]                 s_wstrb,
  input  wire                        s_wlast,
  input  wire                        s_wvalid,
  output logic                       s_wready,
  output logic [IDW-1:0]             s_bid,
  output logic [1:0]                 s_bresp,
  output logic                       s_bvalid,
  input  wire                        s_bready,

  input  wire  [IDW-1:0]             s_arid,
  input  wire  [31:0]                s_araddr,
  input  wire  [7:0]                 s_arlen,
  input  wire  [2:0]                 s_arsize,
  input  wire  [2:0]                 s_arprot,
  input  wire                        s_arvalid,
  output logic                       s_arready,
  output logic [IDW-1:0]             s_rid,
  output logic [63:0]                s_rdata,
  output logic [1:0]                 s_rresp,
  output logic                       s_rlast,
  output logic                       s_rvalid,
  input  wire                        s_rready,

  output logic [NSLOT-1:0]           psel,
  output logic                       penable,
  output logic [15:0]                paddr,
  output logic                       pwrite,
  output logic [31:0]                pwdata,
  output logic [3:0]                 pstrb,
  output logic [2:0]                 pprot,
  input  wire  [NSLOT-1:0][31:0]     prdata,
  input  wire  [NSLOT-1:0]           pready,
  input  wire  [NSLOT-1:0]           pslverr
);

  typedef enum logic [2:0] {
    IDLE,     // wait for AW or AR
    W_BEAT,   // wait for the next W beat
    XFER,     // APB transfers of the current beat
    R_BEAT,   // present the R beat
    B_RESP    // present B
  } st_t;

  st_t         st;
  logic        is_write;
  logic [IDW-1:0] id_q;
  logic [15:0] base_q;     // window offset of the current beat, 8-byte aligned
  logic        narrow_q;   // AxSIZE = 2
  logic        nlane_q;    // the word a narrow beat addresses
  logic [7:0]  left_q;     // beats after the current one
  logic [2:0]  prot_q;
  logic [63:0] wdata_q;
  logic [7:0]  wstrb_q;
  logic        wlast_q;
  logic [63:0] rdata_q;
  logic        err_beat_q;
  logic        err_txn_q;
  logic        word_q;     // word of the beat being transferred
  logic        access_q;   // APB ACCESS phase
  logic [1:0]  todo_q;     // words of this beat still to transfer

  wire take_aw = (st == IDLE) && s_awvalid;
  wire take_ar = (st == IDLE) && !s_awvalid && s_arvalid;

  assign s_awready = take_aw;
  assign s_arready = take_ar;
  assign s_wready  = (st == W_BEAT);
  assign s_bvalid  = (st == B_RESP);
  assign s_bid     = id_q;
  assign s_bresp   = err_txn_q ? 2'b10 : 2'b00;
  assign s_rvalid  = (st == R_BEAT);
  assign s_rid     = id_q;
  assign s_rdata   = rdata_q;
  assign s_rresp   = err_beat_q ? 2'b10 : 2'b00;
  assign s_rlast   = (left_q == 8'd0);

  // Words a beat needs: narrow -> the addressed word; read -> both; write ->
  // the words with a strobe.
  function automatic logic [1:0] words_of(input logic narrow, input logic lane,
                                          input logic write, input logic [7:0] strb);
    if (narrow)     return lane ? 2'b10 : 2'b01;
    else if (write) return {|strb[7:4], |strb[3:0]};
    else            return 2'b11;
  endfunction

  wire [1:0] w_todo = words_of(narrow_q, nlane_q, 1'b1, s_wstrb);

  // Current APB transfer.
  wire [15:0]    xfer_addr = base_q + {13'd0, word_q, 2'b00};
  wire [SW-1:0]  xfer_slot = xfer_addr[12 +: SW];
  // With 16 slots every slot number is in range (4'(16) would be 0).
  logic          in_range;
  if (NSLOT >= 16) begin : g_all_slots
    assign in_range = 1'b1;
  end else begin : g_some_slots
    assign in_range = (xfer_addr[15:12] < 4'(NSLOT));
  end
  wire           slot_ok   = in_range && SLOT_EN[xfer_slot];
  wire           xfer_ok   = (st == XFER) && todo_q[word_q];

  always_comb begin
    psel = '0;
    if (xfer_ok && slot_ok) psel[xfer_slot] = 1'b1;
  end
  assign penable = (st == XFER) && access_q && slot_ok;
  assign paddr   = xfer_addr;
  assign pwrite  = is_write;
  assign pwdata  = word_q ? wdata_q[63:32] : wdata_q[31:0];
  assign pstrb   = is_write ? (word_q ? wstrb_q[7:4] : wstrb_q[3:0]) : 4'b0000;
  assign pprot   = prot_q;

  wire        done_ok  = access_q && pready[xfer_slot];
  wire        xfer_end = xfer_ok && (!slot_ok || done_ok);
  wire [31:0] word_in  = slot_ok ? prdata[xfer_slot] : 32'd0;
  wire        word_err = !slot_ok || pslverr[xfer_slot];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st         <= IDLE;
      is_write   <= 1'b0;
      id_q       <= '0;
      base_q     <= '0;
      narrow_q   <= 1'b0;
      nlane_q    <= 1'b0;
      left_q     <= '0;
      prot_q     <= '0;
      wdata_q    <= '0;
      wstrb_q    <= '0;
      wlast_q    <= 1'b0;
      rdata_q    <= '0;
      err_beat_q <= 1'b0;
      err_txn_q  <= 1'b0;
      word_q     <= 1'b0;
      access_q   <= 1'b0;
      todo_q     <= '0;
    end else begin
      case (st)
        IDLE: begin
          err_txn_q <= 1'b0;
          if (take_aw) begin
            is_write <= 1'b1;
            id_q     <= s_awid;
            base_q   <= {s_awaddr[15:3], 3'b000};
            narrow_q <= (s_awsize == 3'd2);
            nlane_q  <= s_awaddr[2];
            left_q   <= s_awlen;
            prot_q   <= s_awprot;
            st       <= W_BEAT;
          end else if (take_ar) begin
            is_write   <= 1'b0;
            id_q       <= s_arid;
            base_q     <= {s_araddr[15:3], 3'b000};
            narrow_q   <= (s_arsize == 3'd2);
            nlane_q    <= s_araddr[2];
            left_q     <= s_arlen;
            prot_q     <= s_arprot;
            rdata_q    <= '0;
            err_beat_q <= 1'b0;
            todo_q     <= words_of(s_arsize == 3'd2, s_araddr[2], 1'b0, 8'h00);
            word_q     <= (s_arsize == 3'd2) ? s_araddr[2] : 1'b0;
            access_q   <= 1'b0;
            st         <= XFER;
          end
        end

        W_BEAT: if (s_wvalid) begin
          wdata_q <= s_wdata;
          wstrb_q <= s_wstrb;
          wlast_q <= s_wlast;
          if (w_todo == 2'b00) begin
            // No strobe in this beat: nothing to write.
            if (s_wlast) st <= B_RESP;
            else         base_q <= base_q + 16'd8;
          end else begin
            todo_q   <= w_todo;
            word_q   <= !w_todo[0];
            access_q <= 1'b0;
            st       <= XFER;
          end
        end

        XFER: begin
          if (!todo_q[word_q]) begin
            // Skip a word this beat does not touch.
            word_q <= 1'b1;
          end else if (!access_q && slot_ok) begin
            access_q <= 1'b1;  // SETUP done, ACCESS next
          end else if (xfer_end) begin
            access_q <= 1'b0;
            if (!is_write) begin
              if (word_q) rdata_q[63:32] <= word_in;
              else        rdata_q[31:0]  <= word_in;
            end
            if (word_err) begin
              err_beat_q <= 1'b1;
              err_txn_q  <= 1'b1;
            end
            if (word_q == 1'b0 && todo_q[1]) begin
              word_q <= 1'b1;
            end else if (is_write) begin
              if (wlast_q) begin
                st <= B_RESP;
              end else begin
                base_q <= base_q + 16'd8;
                st     <= W_BEAT;
              end
            end else begin
              st <= R_BEAT;
            end
          end
        end

        R_BEAT: if (s_rready) begin
          if (s_rlast) begin
            st <= IDLE;
          end else begin
            base_q     <= base_q + 16'd8;
            left_q     <= left_q - 1'b1;
            rdata_q    <= '0;
            err_beat_q <= 1'b0;
            todo_q     <= 2'b11;
            word_q     <= 1'b0;
            st         <= XFER;
          end
        end

        B_RESP: if (s_bready) begin
          st <= IDLE;
        end

        default: st <= IDLE;
      endcase
    end
  end

  // Upper address bits are decoded by the crossbar; write bursts end on WLAST.
  /* verilator lint_off UNUSEDSIGNAL */
  wire unused_ok = ^{s_awaddr[31:16], s_araddr[31:16], s_awaddr[1:0], s_araddr[1:0]};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule : axi2apb

`default_nettype wire
