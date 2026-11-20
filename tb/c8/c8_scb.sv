// -----------------------------------------------------------------------------
// c8_scb — Functional UVM scoreboard for audio I2S C8 enter/exit
//
// Checks PROTOCOL INTENT, not RTL next-state mirroring:
//   1. Interrupt masking: while int_mask, outs stay quiet even if levels assert;
//      after int_mask falls, pending levels must propagate (mask-release check).
//   2. Ack vs rej based on idle state; mutual exclusion.
//   3. Once stop_access_ack commits enter, progress to fence_ack (no mid-enter hang).
//   4. Exit completeness after fence_req drop in C8.
//   5. SoC constraints: fence_req only when both idle; idle drop clears fence_req.
//   6. Reject path and abnormal timings do not deadlock (watchdog counters).
//
// Pair with c8_assertions.sv for concurrent SVA; this class tracks phase,
// prints diagnostics, and flags bounded-progress failures.
// Compile with +define+UVM (and UVM library) when integrating into a UVM env.
// For standalone smoke, use c8_scb_lite in c8_tb_stub.sv.
// -----------------------------------------------------------------------------
`ifndef C8_SCB_SV
`define C8_SCB_SV

`ifdef UVM
package c8_scb_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import c8_pkg::*;

class c8_scb extends uvm_component;
  `uvm_component_utils(c8_scb)

  virtual c8_ctrl_if.mon vif;

  c8_phase_e phase;
  c8_phase_e phase_prev;

  bit fence_req_d, fence_ack_d, stop_req_d, stop_ack_d, stop_rej_d;
  bit int_mask_d, dma_idle_d, int_idle_d;
  bit i2s_lvl_d, dma_lvl_d;

  int unsigned enter_wait_cnt;
  int unsigned exit_wait_cnt;
  int unsigned rej_wait_cnt;
  int unsigned unmask_wait_cnt;
  bit          pending_i2s_at_unmask;
  bit          pending_dma_at_unmask;
  bit          waiting_unmask_prop;

  int unsigned err_cnt;
  int unsigned enter_ok_cnt;
  int unsigned exit_ok_cnt;
  int unsigned rej_cnt;
  int unsigned mask_hold_cnt;
  bit fatal_freeze;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    phase = C8_PHASE_IDLE;
  endfunction

  function void build_phase(uvm_phase phase_uvm);
    super.build_phase(phase_uvm);
    void'(uvm_config_db#(virtual c8_ctrl_if.mon)::get(this, "", "vif", vif));
  endfunction

  task run_phase(uvm_phase phase_uvm);
    if (vif == null) begin
      `uvm_fatal(get_type_name(), "vif is null — set uvm_config_db virtual c8_ctrl_if.mon")
    end
    forever begin
      @(posedge vif.clk);
      if (!vif.rst_n) begin
        reset_state();
        continue;
      end
      if (!fatal_freeze)
        sample_and_check();
      capture_prev();
    end
  endtask

  function void reset_state();
    phase               = C8_PHASE_IDLE;
    enter_wait_cnt      = 0;
    exit_wait_cnt       = 0;
    rej_wait_cnt        = 0;
    unmask_wait_cnt     = 0;
    waiting_unmask_prop = 0;
    pending_i2s_at_unmask = 0;
    pending_dma_at_unmask = 0;
  endfunction

  function void capture_prev();
    fence_req_d = vif.C8_Fence_Req;
    fence_ack_d = vif.C8_Fence_Ack;
    stop_req_d  = vif.stop_access_req;
    stop_ack_d  = vif.stop_access_ack;
    stop_rej_d  = vif.stop_access_rej;
    int_mask_d  = vif.int_mask;
    dma_idle_d  = vif.C8_DMA_Idle;
    int_idle_d  = vif.C8_INT_Idle;
    i2s_lvl_d   = vif.i2s_intr_level;
    dma_lvl_d   = vif.dma_intr_level;
    phase_prev  = phase;
  endfunction

  function bit rose(bit cur, bit prev);
    return cur && !prev;
  endfunction

  function bit fell(bit cur, bit prev);
    return !cur && prev;
  endfunction

  function void fail(string msg);
    err_cnt++;
    `uvm_error(get_type_name(), $sformatf("[%s] %s", c8_phase_name(phase), msg))
  endfunction

  function void note(string msg);
    `uvm_info(get_type_name(), $sformatf("[%s] %s", c8_phase_name(phase), msg), UVM_MEDIUM)
  endfunction

  function void sample_and_check();
    check_interrupt_masking();
    check_ack_rej();
    check_soc_constraints();
    update_phase_and_progress();
  endfunction

  // ---- 1) Interrupt masking + unmask propagation ----
  function void check_interrupt_masking();
    if (vif.int_mask) begin
      mask_hold_cnt++;
      if (vif.audio_i2s_intr_out)
        fail("audio_i2s_intr_out high while int_mask (must stay masked)");
      if (vif.audio_dma_intr_out)
        fail("audio_dma_intr_out high while int_mask (must stay masked)");
    end

    if (fell(vif.int_mask, int_mask_d)) begin
      pending_i2s_at_unmask = i2s_lvl_d || vif.i2s_intr_level;
      pending_dma_at_unmask = dma_lvl_d || vif.dma_intr_level;
      if (pending_i2s_at_unmask || pending_dma_at_unmask) begin
        waiting_unmask_prop = 1;
        unmask_wait_cnt     = 0;
        note("int_mask fell with pending level(s) — expect out propagation");
      end
    end

    if (waiting_unmask_prop) begin
      bit i2s_ok = !pending_i2s_at_unmask || vif.audio_i2s_intr_out || !vif.i2s_intr_level;
      bit dma_ok = !pending_dma_at_unmask || vif.audio_dma_intr_out || !vif.dma_intr_level;
      if (i2s_ok && dma_ok) begin
        waiting_unmask_prop = 0;
        note("pending interrupt(s) propagated after int_mask release");
      end else begin
        unmask_wait_cnt++;
        if (unmask_wait_cnt > C8_UNMASK_MAX)
          fail("pending IRQ did not propagate within C8_UNMASK_MAX after int_mask fall");
      end
    end
  endfunction

  // ---- 2) Ack / rej ----
  function void check_ack_rej();
    if (vif.stop_access_ack && vif.stop_access_rej)
      fail("stop_access_ack and stop_access_rej both asserted");

    if (rose(vif.stop_access_ack, stop_ack_d)) begin
      if (!vif.both_idle)
        fail("stop_access_ack rose without both C8_DMA_Idle and C8_INT_Idle");
      else
        note("enter committed (stop_access_ack rose)");
    end

    if (rose(vif.stop_access_rej, stop_rej_d)) begin
      rej_cnt++;
      note("enter rejected (stop_access_rej)");
    end
  endfunction

  // ---- 3) SoC constraints (no "IRQ before enter still enters C8") ----
  function void check_soc_constraints();
    if (rose(vif.C8_Fence_Req, fence_req_d) && !vif.both_idle)
      fail("C8_Fence_Req rose while not both idle (illegal SoC)");
    if ((fell(vif.C8_DMA_Idle, dma_idle_d) || fell(vif.C8_INT_Idle, int_idle_d))
        && vif.C8_Fence_Req)
      note("idle dropped while fence_req — expect SoC to deassert fence_req");
  endfunction

  // ---- Phase + bounded progress ----
  function void update_phase_and_progress();
    unique case (phase)
      C8_PHASE_IDLE: begin
        enter_wait_cnt = 0;
        exit_wait_cnt  = 0;
        rej_wait_cnt   = 0;
        if (rose(vif.C8_Fence_Req, fence_req_d) && vif.both_idle)
          phase = C8_PHASE_ENTER_SYNC;
      end

      C8_PHASE_ENTER_SYNC: begin
        enter_wait_cnt++;
        if (fell(vif.C8_Fence_Req, fence_req_d) && !vif.stop_access_ack) begin
          note("fence_req dropped during enter sync — abort, return IDLE");
          phase = C8_PHASE_IDLE;
        end
        else if (rose(vif.stop_access_rej, stop_rej_d))
          phase = C8_PHASE_REJECTED;
        else if (rose(vif.stop_access_ack, stop_ack_d))
          phase = C8_PHASE_ENTER_COMMIT;
        else if (enter_wait_cnt > C8_ACK_PROG_MAX)
          fail("ENTER_SYNC watchdog — stuck mid-enter (no ack/rej/abort)");
        else if (!vif.both_idle && vif.C8_Fence_Req && enter_wait_cnt > 3)
          fail("idle low but fence_req still high during ENTER_SYNC");
      end

      C8_PHASE_ENTER_COMMIT: begin
        enter_wait_cnt++;
        if (!vif.int_mask)
          fail("int_mask must stay high after stop_access_ack commit");
        if (rose(vif.C8_Fence_Ack, fence_ack_d)) begin
          enter_ok_cnt++;
          note("C8 entered (C8_Fence_Ack rose)");
          phase = C8_PHASE_IN_C8;
          enter_wait_cnt = 0;
        end
        else if (enter_wait_cnt > C8_ACK_PROG_MAX)
          fail("ENTER_COMMIT watchdog — deadlock mid-switch (no fence_ack)");
      end

      C8_PHASE_IN_C8: begin
        if (!vif.C8_Fence_Ack)
          fail("unexpected fence_ack low while phase IN_C8");
        if (!vif.int_mask)
          fail("int_mask dropped while still in C8 (fence_ack high)");
        if (fell(vif.C8_Fence_Req, fence_req_d)) begin
          note("exit started (fence_req fell while in C8)");
          phase = C8_PHASE_EXIT_SYNC;
          exit_wait_cnt = 0;
        end
      end

      C8_PHASE_EXIT_SYNC: begin
        exit_wait_cnt++;
        if (fell(vif.C8_Fence_Ack, fence_ack_d))
          note("fence_ack fell — expect stop_access_req then ack/mask clear");
        if (!vif.C8_Fence_Ack && !vif.stop_access_req &&
            !vif.stop_access_ack && !vif.int_mask) begin
          exit_ok_cnt++;
          note("C8 exit complete");
          phase = C8_PHASE_IDLE;
        end
        else if (exit_wait_cnt > C8_ACK_PROG_MAX)
          fail("EXIT_SYNC watchdog — stuck mid-exit");
      end

      C8_PHASE_REJECTED: begin
        rej_wait_cnt++;
        if (!vif.stop_access_req && !vif.stop_access_rej && !vif.C8_Fence_Ack) begin
          note("reject path cleared — back to IDLE");
          phase = C8_PHASE_IDLE;
        end
        else if (rej_wait_cnt > C8_SYNC_MAX)
          fail("REJECTED watchdog — hung after stop_access_rej");
      end

      default: phase = C8_PHASE_IDLE;
    endcase
  endfunction

  function void report_phase(uvm_phase phase_uvm);
    `uvm_info(get_type_name(),
      $sformatf("C8 SCB summary: enter_ok=%0d exit_ok=%0d rej=%0d mask_cycles=%0d errs=%0d",
                enter_ok_cnt, exit_ok_cnt, rej_cnt, mask_hold_cnt, err_cnt),
      UVM_LOW)
    if (err_cnt)
      `uvm_error(get_type_name(), $sformatf("%0d functional check error(s)", err_cnt))
  endfunction

endclass

endpackage
`endif // UVM

`endif // C8_SCB_SV
