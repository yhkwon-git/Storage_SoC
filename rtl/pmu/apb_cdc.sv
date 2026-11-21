`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// apb_cdc
//
// APB4 across two unrelated clocks with a four-phase request/acknowledge
// handshake (docs/01, section 2: the request/acknowledge crossing). The
// source side (s_*) is an APB slave in clk_s; the destination side (m_*) is
// an APB master in clk_d. Only req and ack are synchronized: the address,
// write data and response sit in registers that do not change while the bit
// that announces them is high.
//
//   source                         destination
//   SETUP seen, capture, req = 1
//                                  req seen: SETUP, ACCESS until PREADY,
//                                  capture response, ack = 1
//   ack seen: take response,
//   req = 0, PREADY next clock
//                                  req low seen: ack = 0
//   ack low seen: next transfer
//
// One access costs about three clk_d cycles plus synchronizer delays on each
// side. Either side may be reset alone: a source reset drops req and the
// destination finishes its access and lowers ack; the source waits for ack to
// be low before it starts again.
// -----------------------------------------------------------------------------

module apb_cdc #(
  parameter int AW = 12
) (
  // Source: APB slave
  input  wire          clk_s,
  input  wire          rst_s_n,
  input  wire          s_psel,
  input  wire          s_penable,
  input  wire [AW-1:0] s_paddr,
  input  wire          s_pwrite,
  input  wire  [31:0]  s_pwdata,
  input  wire  [3:0]   s_pstrb,
  output logic [31:0]  s_prdata,
  output logic         s_pready,
  output logic         s_pslverr,

  // Destination: APB master
  input  wire          clk_d,
  input  wire          rst_d_n,
  output logic         m_psel,
  output logic         m_penable,
  output logic [AW-1:0] m_paddr,
  output logic         m_pwrite,
  output logic [31:0]  m_pwdata,
  output logic [3:0]   m_pstrb,
  input  wire  [31:0]  m_prdata,
  input  wire          m_pready,
  input  wire          m_pslverr
);

  // ---------------------------------------------------------------------------
  // Source side
  // ---------------------------------------------------------------------------
  typedef enum logic [1:0] {S_IDLE, S_WAIT, S_DONE} s_state_e;
  s_state_e s_state;

  logic          req;
  logic [AW-1:0] q_addr;
  logic          q_write;
  logic [31:0]   q_wdata;
  logic [3:0]    q_strb;
  logic          ack_s;
  logic [31:0]   d_rdata;    // destination's response register
  logic          d_slverr;
  logic          ack;

  cdc_sync_2ff #(.WIDTH(1)) u_ack_sync (.clk(clk_s), .rst_n(rst_s_n), .din_async(ack), .dout(ack_s));

  wire s_start = (s_state == S_IDLE) && s_psel && !ack_s;

  // The request registers have no reset: a source reset while the destination
  // is still using them must not change them.
  always_ff @(posedge clk_s) begin
    if (s_start) begin
      q_addr  <= s_paddr;
      q_write <= s_pwrite;
      q_wdata <= s_pwdata;
      q_strb  <= s_pstrb;
    end
  end

  always_ff @(posedge clk_s or negedge rst_s_n) begin
    if (!rst_s_n) begin
      s_state   <= S_IDLE;
      req       <= 1'b0;
      s_prdata  <= 32'd0;
      s_pslverr <= 1'b0;
    end else begin
      case (s_state)
        S_IDLE: begin
          if (s_start) begin
            req     <= 1'b1;
            s_state <= S_WAIT;
          end
        end
        S_WAIT: begin
          if (ack_s) begin
            s_prdata  <= d_rdata;
            s_pslverr <= d_slverr;
            req       <= 1'b0;
            s_state   <= S_DONE;
          end
        end
        S_DONE: begin
          if (s_psel && s_penable) s_state <= S_IDLE;
        end
        default: s_state <= S_IDLE;
      endcase
    end
  end

  assign s_pready = (s_state == S_DONE);

  // ---------------------------------------------------------------------------
  // Destination side
  // ---------------------------------------------------------------------------
  typedef enum logic [1:0] {D_IDLE, D_SETUP, D_ACCESS, D_ACK} d_state_e;
  d_state_e d_state;
  logic     req_d;

  cdc_sync_2ff #(.WIDTH(1)) u_req_sync (.clk(clk_d), .rst_n(rst_d_n), .din_async(req), .dout(req_d));

  always_ff @(posedge clk_d or negedge rst_d_n) begin
    if (!rst_d_n) begin
      d_state  <= D_IDLE;
      ack      <= 1'b0;
      d_rdata  <= 32'd0;
      d_slverr <= 1'b0;
    end else begin
      case (d_state)
        D_IDLE:   if (req_d) d_state <= D_SETUP;
        D_SETUP:  d_state <= D_ACCESS;
        D_ACCESS: begin
          if (m_pready) begin
            d_rdata  <= m_prdata;
            d_slverr <= m_pslverr;
            ack      <= 1'b1;
            d_state  <= D_ACK;
          end
        end
        D_ACK: begin
          if (!req_d) begin
            ack     <= 1'b0;
            d_state <= D_IDLE;
          end
        end
        default: d_state <= D_IDLE;
      endcase
    end
  end

  // The request registers are stable while req is high, which covers the
  // whole destination access.
  assign m_psel    = (d_state == D_SETUP) || (d_state == D_ACCESS);
  assign m_penable = (d_state == D_ACCESS);
  assign m_paddr   = q_addr;
  assign m_pwrite  = q_write;
  assign m_pwdata  = q_wdata;
  assign m_pstrb   = q_strb;

endmodule : apb_cdc

`default_nettype wire
