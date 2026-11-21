`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// axi_channel_reg_slice
//
// Full register slice for one valid/ready channel, used for every AXI4 channel
// (the payload is the channel's fields packed together).
//
//   * The output register cuts the forward path (VALID and payload).
//   * The skid register takes the beat that arrives while the output stalls.
//   * s_ready is the complement of the skid flop, so it does not depend
//     combinationally on m_ready.
//
// With both sides ready it passes one beat per clock with one clock of
// latency. A downstream stall of k clocks blocks the upstream for k clocks.
//
// aresetn is asserted asynchronously and released synchronously. Only the
// valid flops are reset; payload flops are not.
//
// Origin: AXI_PCIe_Subsystem commit b64e36a, rtl/axi_register_slice.sv, module
// axi_channel_reg_slice. Logic and monitors unchanged; this header rewritten.
// -----------------------------------------------------------------------------

module axi_channel_reg_slice #(
  parameter int WIDTH = 32
) (
  input  wire                    aclk,
  input  wire                    aresetn,

  input  wire                    s_valid,
  output wire                    s_ready,
  input  wire [WIDTH-1:0]        s_data,

  output wire                    m_valid,
  input  wire                    m_ready,
  output wire [WIDTH-1:0]        m_data
);

  generate
    if (WIDTH < 1) begin : g_illegal_width
      initial $error("axi_channel_reg_slice: WIDTH must be >= 1");
    end
  endgenerate

  logic             m_valid_q;
  logic [WIDTH-1:0] m_data_q;
  logic             skid_valid_q;
  logic [WIDTH-1:0] skid_data_q;

  wire              m_load_en;
  wire              skid_load_en;
  wire              skid_clear;
  wire [WIDTH-1:0]  m_data_next;

  // Reverse-path register. READY falls only after the skid slot is occupied,
  // and it does not combinationally depend on m_ready.
  assign s_ready = ~skid_valid_q;

  // Output register can take a new beat when it is empty or the current beat
  // is accepted downstream in this cycle.
  assign m_load_en    = ~m_valid_q | m_ready;
  assign skid_load_en = s_valid & s_ready & ~m_load_en;
  assign skid_clear   = skid_valid_q & m_load_en;

  // Skid occupancy implies the output register is full, so a stored skid beat
  // is the older one and must advance first.
  assign m_data_next = skid_valid_q ? skid_data_q : s_data;

  always_ff @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
      m_valid_q    <= 1'b0;
      skid_valid_q <= 1'b0;
    end else begin
      if (m_load_en) begin
        m_valid_q <= skid_valid_q | (s_valid & s_ready);
        if (skid_valid_q | (s_valid & s_ready)) begin
          m_data_q <= m_data_next;
        end
      end

      if (skid_load_en) begin
        skid_valid_q <= 1'b1;
        skid_data_q  <= s_data;
      end else if (skid_clear) begin
        skid_valid_q <= 1'b0;
      end
    end
  end

  assign m_valid = m_valid_q;
  assign m_data  = m_data_q;

`ifndef SYNTHESIS
  // Protocol monitors. VALID and payload must stay put until READY, on both
  // the incoming beat and the beat this slice itself presents downstream.
  logic             s_valid_d;
  logic             s_ready_d;
  logic [WIDTH-1:0] s_data_d;
  logic             m_valid_d;
  logic             m_ready_d;
  logic [WIDTH-1:0] m_data_d;

  always_ff @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
      s_valid_d <= 1'b0;
      s_ready_d <= 1'b0;
      m_valid_d <= 1'b0;
      m_ready_d <= 1'b0;
    end else begin
      if (s_valid_d && !s_ready_d) begin
        if (!s_valid) begin
          $error("%m: upstream VALID dropped before READY");
        end
        if (s_data !== s_data_d) begin
          $error("%m: upstream payload changed before handshake");
        end
      end
      if (m_valid_d && !m_ready_d) begin
        if (!m_valid) begin
          $error("%m: slice dropped VALID before READY");
        end
        if (m_data !== m_data_d) begin
          $error("%m: slice payload changed before handshake");
        end
      end
      s_valid_d <= s_valid;
      s_ready_d <= s_ready;
      s_data_d  <= s_data;
      m_valid_d <= m_valid;
      m_ready_d <= m_ready;
      m_data_d  <= m_data;
    end
  end
`endif

endmodule : axi_channel_reg_slice

`default_nettype wire
