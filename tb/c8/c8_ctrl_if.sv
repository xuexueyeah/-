// -----------------------------------------------------------------------------
// c8_ctrl_if — Audio I2S C8 enter/exit control + whitebox observe points
// -----------------------------------------------------------------------------
interface c8_ctrl_if(input logic clk, input logic rst_n);

  // SoC / IP handshake
  logic C8_Fence_Req;
  logic C8_Fence_Ack;
  logic C8_DMA_Idle;
  logic C8_INT_Idle;

  // Whitebox (DUT internals observed for functional checking)
  logic stop_access_req;
  logic stop_access_ack;
  logic stop_access_rej;
  logic switch_to_refclk;
  logic selbout;
  logic int_mask;
  logic i2s_intr_level;
  logic dma_intr_level;
  logic audio_i2s_intr_out;
  logic audio_dma_intr_out;

  // Convenience: both idles high (SoC may assert fence_req)
  wire both_idle = C8_DMA_Idle && C8_INT_Idle;

  // Default: drive SoC-side inputs from TB; DUT drives ack/whitebox
  modport dut (
    input  clk, rst_n,
    input  C8_Fence_Req, C8_DMA_Idle, C8_INT_Idle,
    output C8_Fence_Ack,
    output stop_access_req, stop_access_ack, stop_access_rej,
    output switch_to_refclk, selbout, int_mask,
    output i2s_intr_level, dma_intr_level,
    output audio_i2s_intr_out, audio_dma_intr_out
  );

  modport mon (
    input clk, rst_n,
    input C8_Fence_Req, C8_Fence_Ack, C8_DMA_Idle, C8_INT_Idle,
    input stop_access_req, stop_access_ack, stop_access_rej,
    input switch_to_refclk, selbout, int_mask,
    input i2s_intr_level, dma_intr_level,
    input audio_i2s_intr_out, audio_dma_intr_out,
    input both_idle
  );

  modport tb (
    input  clk, rst_n, C8_Fence_Ack,
    input  stop_access_req, stop_access_ack, stop_access_rej,
    input  switch_to_refclk, selbout, int_mask,
    input  i2s_intr_level, dma_intr_level,
    input  audio_i2s_intr_out, audio_dma_intr_out,
    output C8_Fence_Req, C8_DMA_Idle, C8_INT_Idle
  );

endinterface
