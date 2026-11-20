// -----------------------------------------------------------------------------
// c8_assertions — Functional SVA for audio I2S C8 enter/exit
//
// Rules encode protocol INTENT and SAFETY / PROGRESS, not RTL next-state.
// Bind to c8_ctrl_if (or instantiate with .vif(iface)).
// -----------------------------------------------------------------------------
module c8_assertions (
  c8_ctrl_if.mon vif
);

  import c8_pkg::*;

  // --------------------------------------------------------------------------
  // 1) Interrupt masking (required priority check)
  //    While int_mask high: external outs must stay masked even if levels assert.
  //    After int_mask falls: pending levels must propagate within C8_UNMASK_MAX.
  // --------------------------------------------------------------------------
  property p_i2s_masked_while_int_mask;
    @(posedge vif.clk) disable iff (!vif.rst_n)
      vif.int_mask |-> !vif.audio_i2s_intr_out;
  endproperty
  a_i2s_masked_while_int_mask: assert property (p_i2s_masked_while_int_mask)
    else $error("C8: audio_i2s_intr_out asserted while int_mask=1");

  property p_dma_masked_while_int_mask;
    @(posedge vif.clk) disable iff (!vif.rst_n)
      vif.int_mask |-> !vif.audio_dma_intr_out;
  endproperty
  a_dma_masked_while_int_mask: assert property (p_dma_masked_while_int_mask)
    else $error("C8: audio_dma_intr_out asserted while int_mask=1");

  // Levels may still go high under mask (allowed); outs must not.
  property p_i2s_level_under_mask_outs_quiet;
    @(posedge vif.clk) disable iff (!vif.rst_n)
      (vif.int_mask && vif.i2s_intr_level) |-> !vif.audio_i2s_intr_out;
  endproperty
  a_i2s_level_under_mask_outs_quiet: assert property (p_i2s_level_under_mask_outs_quiet);

  property p_dma_level_under_mask_outs_quiet;
    @(posedge vif.clk) disable iff (!vif.rst_n)
      (vif.int_mask && vif.dma_intr_level) |-> !vif.audio_dma_intr_out;
  endproperty
  a_dma_level_under_mask_outs_quiet: assert property (p_dma_level_under_mask_outs_quiet);

  // After unmask: if level was pending at fall of int_mask, out must rise
  // within C8_UNMASK_MAX (mask-release correctness).
  property p_i2s_unmask_propagates;
    @(posedge vif.clk) disable iff (!vif.rst_n)
      ($fell(vif.int_mask) && $past(vif.i2s_intr_level))
        |-> ##[0:C8_UNMASK_MAX] (vif.audio_i2s_intr_out || !vif.i2s_intr_level);
  endproperty
  a_i2s_unmask_propagates: assert property (p_i2s_unmask_propagates)
    else $error("C8: pending i2s_intr_level did not propagate after int_mask fall");

  property p_dma_unmask_propagates;
    @(posedge vif.clk) disable iff (!vif.rst_n)
      ($fell(vif.int_mask) && $past(vif.dma_intr_level))
        |-> ##[0:C8_UNMASK_MAX] (vif.audio_dma_intr_out || !vif.dma_intr_level);
  endproperty
  a_dma_unmask_propagates: assert property (p_dma_unmask_propagates)
    else $error("C8: pending dma_intr_level did not propagate after int_mask fall");

  // When unmasked and level high, out should follow (steady-state after settle)
  property p_i2s_follow_when_unmasked;
    @(posedge vif.clk) disable iff (!vif.rst_n)
      (!vif.int_mask && vif.i2s_intr_level)
        |-> ##[0:C8_UNMASK_MAX] (vif.audio_i2s_intr_out || vif.int_mask || !vif.i2s_intr_level);
  endproperty
  a_i2s_follow_when_unmasked: assert property (p_i2s_follow_when_unmasked);

  property p_dma_follow_when_unmasked;
    @(posedge vif.clk) disable iff (!vif.rst_n)
      (!vif.int_mask && vif.dma_intr_level)
        |-> ##[0:C8_UNMASK_MAX] (vif.audio_dma_intr_out || vif.int_mask || !vif.dma_intr_level);
  endproperty
  a_dma_follow_when_unmasked: assert property (p_dma_follow_when_unmasked);

  // --------------------------------------------------------------------------
  // 2) Ack vs rej — mutual exclusion; ack only when both idles allow stop
  // --------------------------------------------------------------------------
  property p_ack_rej_mutex;
    @(posedge vif.clk) disable iff (!vif.rst_n)
      !(vif.stop_access_ack && vif.stop_access_rej);
  endproperty
  a_ack_rej_mutex: assert property (p_ack_rej_mutex)
    else $error("C8: stop_access_ack and stop_access_rej both high");

  // Rising ack implies both idles were high at decision (sample at rise)
  property p_ack_implies_both_idle;
    @(posedge vif.clk) disable iff (!vif.rst_n)
      $rose(vif.stop_access_ack) |-> vif.both_idle;
  endproperty
  a_ack_implies_both_idle: assert property (p_ack_implies_both_idle)
    else $error("C8: stop_access_ack rose without both idles high");

  // If stop_access_req rises and not both idle → rej (not ack); ack must not rise
  property p_not_idle_yields_rej;
    @(posedge vif.clk) disable iff (!vif.rst_n)
      ($rose(vif.stop_access_req) && !vif.both_idle)
        |-> ##[0:C8_SYNC_MAX] (vif.stop_access_rej || !vif.stop_access_req);
  endproperty
  a_not_idle_yields_rej: assert property (p_not_idle_yields_rej)
    else $error("C8: enter with idle low should rej");

  property p_not_idle_never_ack;
    @(posedge vif.clk) disable iff (!vif.rst_n)
      ($rose(vif.stop_access_req) && !vif.both_idle)
        |-> (!vif.stop_access_ack) throughout
            ##[0:C8_SYNC_MAX] (vif.stop_access_rej || !vif.stop_access_req);
  endproperty
  a_not_idle_never_ack: assert property (p_not_idle_never_ack)
    else $error("C8: enter with idle low must not ack");

  // --------------------------------------------------------------------------
  // 3) SoC protocol constraints (assume / check stimulus legality)
  //    fence_req only when both idle; idle drop → fence_req drop
  // --------------------------------------------------------------------------
  property p_fence_req_only_when_both_idle;
    @(posedge vif.clk) disable iff (!vif.rst_n)
      $rose(vif.C8_Fence_Req) |-> vif.both_idle;
  endproperty
  a_fence_req_only_when_both_idle: assert property (p_fence_req_only_when_both_idle)
    else $error("C8: C8_Fence_Req rose while not both idle (illegal SoC)");

  // Idle drop while fence_req high → SoC must drop fence_req (enter abort or exit)
  property p_idle_drop_clears_fence_req;
    @(posedge vif.clk) disable iff (!vif.rst_n)
      (($fell(vif.C8_DMA_Idle) || $fell(vif.C8_INT_Idle)) && vif.C8_Fence_Req)
        |-> ##[0:2] !vif.C8_Fence_Req;
  endproperty
  a_idle_drop_clears_fence_req: assert property (p_idle_drop_clears_fence_req)
    else $error("C8: idle dropped but C8_Fence_Req stayed high");

  // --------------------------------------------------------------------------
  // 4) Commit once acknowledged — progress to fence_ack (no mid-enter hang)
  // --------------------------------------------------------------------------
  property p_ack_eventually_fence_ack;
    @(posedge vif.clk) disable iff (!vif.rst_n)
      $rose(vif.stop_access_ack) && vif.stop_access_req
        |-> ##[1:C8_ACK_PROG_MAX] $rose(vif.C8_Fence_Ack);
  endproperty
  a_ack_eventually_fence_ack: assert property (p_ack_eventually_fence_ack)
    else $error("C8: deadlock — stop_access_ack without eventual C8_Fence_Ack");

  // After commit, idle/fence chatter must not abort: fence_ack still arrives
  // (progress property above covers this; cover idle chatter separately).

  // int_mask must be high once stop_access_ack is held (enter committed)
  property p_ack_implies_int_mask;
    @(posedge vif.clk) disable iff (!vif.rst_n)
      (vif.stop_access_ack && vif.stop_access_req) |-> vif.int_mask;
  endproperty
  a_ack_implies_int_mask: assert property (p_ack_implies_int_mask)
    else $error("C8: stop_access_ack without int_mask");

  // --------------------------------------------------------------------------
  // 5) Exit completeness — fence_req↓ in C8 → fence_ack↓ → stop_req↓ →
  //    stop_ack↓ and int_mask↓ (bounded)
  // --------------------------------------------------------------------------
  property p_exit_fence_ack_falls;
    @(posedge vif.clk) disable iff (!vif.rst_n)
      ($fell(vif.C8_Fence_Req) && vif.C8_Fence_Ack)
        |-> ##[1:C8_ACK_PROG_MAX] $fell(vif.C8_Fence_Ack);
  endproperty
  a_exit_fence_ack_falls: assert property (p_exit_fence_ack_falls)
    else $error("C8: deadlock — fence_req fell in C8 without fence_ack fall");

  property p_exit_stop_req_after_ack_low;
    @(posedge vif.clk) disable iff (!vif.rst_n)
      $fell(vif.C8_Fence_Ack)
        |-> ##[1:4] !vif.stop_access_req;
  endproperty
  a_exit_stop_req_after_ack_low: assert property (p_exit_stop_req_after_ack_low)
    else $error("C8: stop_access_req stuck after fence_ack fell");

  property p_exit_ack_and_mask_clear;
    @(posedge vif.clk) disable iff (!vif.rst_n)
      ($fell(vif.C8_Fence_Ack) ##[1:4] $fell(vif.stop_access_req))
        |-> ##[1:4] (!vif.stop_access_ack && !vif.int_mask);
  endproperty
  a_exit_ack_and_mask_clear: assert property (p_exit_ack_and_mask_clear)
    else $error("C8: stop_access_ack/int_mask stuck after exit");

  // --------------------------------------------------------------------------
  // 6) Reject path — no hang after rej
  // --------------------------------------------------------------------------
  property p_rej_clears_stop_req;
    @(posedge vif.clk) disable iff (!vif.rst_n)
      $rose(vif.stop_access_rej)
        |-> ##[0:C8_SYNC_MAX] !vif.stop_access_req;
  endproperty
  a_rej_clears_stop_req: assert property (p_rej_clears_stop_req)
    else $error("C8: stop_access_req stuck after reject");

  // --------------------------------------------------------------------------
  // Covers — abnormal timings (stimulus should hit these)
  // --------------------------------------------------------------------------
  c_fence_pulse_short: cover property (
    @(posedge vif.clk) disable iff (!vif.rst_n)
      $rose(vif.C8_Fence_Req) ##[1:3] $fell(vif.C8_Fence_Req)
  );

  c_fence_drop_during_enter_sync: cover property (
    @(posedge vif.clk) disable iff (!vif.rst_n)
      $rose(vif.C8_Fence_Req) ##[1:C8_SYNC_MAX]
        ($fell(vif.C8_Fence_Req) && !vif.stop_access_ack && !vif.C8_Fence_Ack)
  );

  c_idle_drop_before_stop_req: cover property (
    @(posedge vif.clk) disable iff (!vif.rst_n)
      vif.C8_Fence_Req && !vif.stop_access_req &&
      ($fell(vif.C8_DMA_Idle) || $fell(vif.C8_INT_Idle))
  );

  c_idle_drop_after_stop_req: cover property (
    @(posedge vif.clk) disable iff (!vif.rst_n)
      vif.stop_access_req && !vif.stop_access_ack &&
      ($fell(vif.C8_DMA_Idle) || $fell(vif.C8_INT_Idle))
  );

  c_idle_chatter_after_ack: cover property (
    @(posedge vif.clk) disable iff (!vif.rst_n)
      vif.stop_access_ack && !vif.C8_Fence_Ack &&
      ($fell(vif.C8_DMA_Idle) || $fell(vif.C8_INT_Idle) || $fell(vif.C8_Fence_Req))
  );

  c_rej_then_reattempt: cover property (
    @(posedge vif.clk) disable iff (!vif.rst_n)
      $rose(vif.stop_access_rej) ##[1:C8_ACK_PROG_MAX]
        ($rose(vif.stop_access_ack) || $rose(vif.C8_Fence_Ack))
  );

  c_irq_level_during_mask: cover property (
    @(posedge vif.clk) disable iff (!vif.rst_n)
      vif.int_mask && (vif.i2s_intr_level || vif.dma_intr_level) &&
      !vif.audio_i2s_intr_out && !vif.audio_dma_intr_out
  );

  c_unmask_pending_propagate: cover property (
    @(posedge vif.clk) disable iff (!vif.rst_n)
      ($fell(vif.int_mask) && ($past(vif.i2s_intr_level) || $past(vif.dma_intr_level)))
        ##[0:C8_UNMASK_MAX] (vif.audio_i2s_intr_out || vif.audio_dma_intr_out)
  );

  c_exit_other_ip_both_idle: cover property (
    @(posedge vif.clk) disable iff (!vif.rst_n)
      $fell(vif.C8_Fence_Req) && vif.C8_Fence_Ack && vif.both_idle
  );

  c_normal_enter_exit: cover property (
    @(posedge vif.clk) disable iff (!vif.rst_n)
      $rose(vif.C8_Fence_Ack) ##[1:C8_ACK_PROG_MAX] $fell(vif.C8_Fence_Ack)
  );

endmodule
