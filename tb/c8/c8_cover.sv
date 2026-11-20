// -----------------------------------------------------------------------------
// c8_cover — Covergroup for normal + abnormal C8 fence/idle timings
// -----------------------------------------------------------------------------
module c8_cover (
  c8_ctrl_if.mon vif
);

  import c8_pkg::*;

  bit fence_req_d, fence_ack_d, stop_req_d, stop_ack_d, stop_rej_d;
  bit dma_idle_d, int_idle_d, int_mask_d;

  always_ff @(posedge vif.clk or negedge vif.rst_n) begin
    if (!vif.rst_n) begin
      fence_req_d <= 0; fence_ack_d <= 0;
      stop_req_d  <= 0; stop_ack_d  <= 0; stop_rej_d <= 0;
      dma_idle_d  <= 1; int_idle_d  <= 1; int_mask_d <= 0;
    end else begin
      fence_req_d <= vif.C8_Fence_Req;
      fence_ack_d <= vif.C8_Fence_Ack;
      stop_req_d  <= vif.stop_access_req;
      stop_ack_d  <= vif.stop_access_ack;
      stop_rej_d  <= vif.stop_access_rej;
      dma_idle_d  <= vif.C8_DMA_Idle;
      int_idle_d  <= vif.C8_INT_Idle;
      int_mask_d  <= vif.int_mask;
    end
  end

  wire rose_fence_req =  vif.C8_Fence_Req   && !fence_req_d;
  wire fell_fence_req = !vif.C8_Fence_Req   &&  fence_req_d;
  wire rose_fence_ack =  vif.C8_Fence_Ack   && !fence_ack_d;
  wire fell_fence_ack = !vif.C8_Fence_Ack   &&  fence_ack_d;
  wire rose_stop_ack  =  vif.stop_access_ack && !stop_ack_d;
  wire rose_stop_rej  =  vif.stop_access_rej && !stop_rej_d;
  wire fell_idle      = (!vif.C8_DMA_Idle && dma_idle_d) ||
                        (!vif.C8_INT_Idle && int_idle_d);
  wire fell_int_mask  = !vif.int_mask && int_mask_d;

  // Sampled scenario tags (one-hot style events)
  logic [3:0] evt_enter;
  logic [3:0] evt_abn;
  logic [2:0] evt_mask;

  always_comb begin
    evt_enter = 4'b0;
    evt_abn   = 4'b0;
    evt_mask  = 3'b0;
    if (rose_fence_req)              evt_enter[0] = 1;
    if (rose_stop_ack)               evt_enter[1] = 1;
    if (rose_fence_ack)              evt_enter[2] = 1;
    if (fell_fence_ack)              evt_enter[3] = 1;

    if (fell_fence_req && !vif.stop_access_ack && !vif.C8_Fence_Ack)
      evt_abn[0] = 1; // short pulse / drop during sync
    if (fell_idle && vif.C8_Fence_Req && !vif.stop_access_req)
      evt_abn[1] = 1; // idle drop before stop_req
    if (fell_idle && vif.stop_access_req && !vif.stop_access_ack)
      evt_abn[2] = 1; // idle drop after stop_req
    if (fell_fence_req && vif.C8_Fence_Ack && vif.both_idle)
      evt_abn[3] = 1; // exit while both idle (other IP)

    if (vif.int_mask && (vif.i2s_intr_level || vif.dma_intr_level) &&
        !vif.audio_i2s_intr_out && !vif.audio_dma_intr_out)
      evt_mask[0] = 1; // levels under mask, outs quiet
    if (fell_int_mask)
      evt_mask[1] = 1;
    if (rose_stop_rej)
      evt_mask[2] = 1;
  end

  covergroup cg_c8_scenarios @(posedge vif.clk iff vif.rst_n);
    option.per_instance = 1;

    cp_enter: coverpoint evt_enter {
      bins req   = {4'b0001};
      bins ack   = {4'b0010};
      bins in_c8 = {4'b0100};
      bins exit  = {4'b1000};
    }

    cp_abnormal: coverpoint evt_abn {
      bins fence_drop_early      = {4'b0001};
      bins idle_before_stop_req  = {4'b0010};
      bins idle_after_stop_req   = {4'b0100};
      bins exit_other_ip         = {4'b1000};
    }

    cp_mask: coverpoint evt_mask {
      bins irq_under_mask = {3'b001};
      bins unmask_edge    = {3'b010};
      bins got_rej        = {3'b100};
    }

    cp_idle_fence: coverpoint {vif.both_idle, vif.C8_Fence_Req} {
      bins idle_with_req    = {2'b11};
      bins idle_without_req = {2'b10};
      bins busy_no_req      = {2'b00};
      illegal_bins busy_with_req = {2'b01};
    }

    cp_outs_under_mask: coverpoint {vif.int_mask, vif.audio_i2s_intr_out,
                                    vif.audio_dma_intr_out} {
      bins masked_quiet = {3'b100};
      illegal_bins masked_i2s = {3'b110, 3'b111};
      illegal_bins masked_dma = {3'b101};
    }
  endgroup

  cg_c8_scenarios cg;

  initial cg = new();

endmodule
