// -----------------------------------------------------------------------------
// c8_tb_stub — Thin stimulus harness for c8_scb / assertions / cover
//
// Drives SoC-legal sequences (fence_req only when both idle; idle drop clears
// fence_req) plus abnormal timings listed in c8_pkg::c8_scenario_e.
// DUT whitebox ports are stubbed with a behavioral C8 model so the scoreboard
// and SVA can be smoke-tested without RTL.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module c8_tb_stub;

  import c8_pkg::*;

  logic clk;
  logic rst_n;

  initial begin
    clk = 0;
    forever #5 clk = ~clk;
  end

  c8_ctrl_if c8_if (.clk(clk), .rst_n(rst_n));

  // Behavioral DUT stub (functional intent model — not production RTL)
  c8_dut_stub u_dut (.vif(c8_if));

  // Checkers
  c8_assertions u_assert (.vif(c8_if));
  c8_cover      u_cover  (.vif(c8_if));

  // Non-UVM scoreboard runner (mirrors c8_scb checks without requiring UVM)
  c8_scb_lite u_scb (.vif(c8_if));

  int scenario;
  string scen_name;

  initial begin
    rst_n = 0;
    c8_if.C8_Fence_Req = 0;
    c8_if.C8_DMA_Idle  = 1;
    c8_if.C8_INT_Idle  = 1;
    repeat (4) @(posedge clk);
    rst_n = 1;
    repeat (2) @(posedge clk);

    // ---- Normal enter / exit ----
    run_normal_enter_exit();

    // ---- Abnormal timings ----
    run_fence_pulse_short();
    run_fence_drop_during_sync();
    run_idle_drop_before_stop_req();
    run_idle_drop_after_stop_req();
    run_rej_then_reattempt();
    run_exit_with_levels_under_mask();
    run_irq_under_mask_then_unmask();

    repeat (20) @(posedge clk);
    $display("c8_tb_stub: scenarios complete");
    $finish;
  end

  // Keep SoC constraint: if idle drops, drop fence_req within 1 cycle
  always @(posedge clk) begin
    if (rst_n && c8_if.C8_Fence_Req && !(c8_if.C8_DMA_Idle && c8_if.C8_INT_Idle))
      c8_if.C8_Fence_Req <= 1'b0;
  end

  task automatic wait_clks(int n);
    repeat (n) @(posedge clk);
  endtask

  task automatic drive_both_idle(bit v);
    c8_if.C8_DMA_Idle = v;
    c8_if.C8_INT_Idle = v;
  endtask

  task automatic assert_fence_if_idle();
    if (c8_if.C8_DMA_Idle && c8_if.C8_INT_Idle)
      c8_if.C8_Fence_Req = 1;
    else
      $error("TB: attempted fence_req without both idle");
  endtask

  task automatic run_normal_enter_exit();
    scen_name = "NORMAL_ENTER_EXIT";
    $display("SCENARIO: %s", scen_name);
    drive_both_idle(1);
    wait_clks(2);
    assert_fence_if_idle();
    wait_clks(2);
    // Inject internal IRQ under mask once in C8 (levels only)
    wait (c8_if.C8_Fence_Ack);
    wait_clks(5);
    c8_if.C8_Fence_Req = 0; // exit (other-IP style; both idle stay high)
    wait (!c8_if.C8_Fence_Ack);
    wait_clks(10);
  endtask

  task automatic run_fence_pulse_short();
    scen_name = "FENCE_PULSE_SHORT";
    $display("SCENARIO: %s", scen_name);
    drive_both_idle(1);
    wait_clks(2);
    assert_fence_if_idle();
    wait_clks(2); // drop before stop/ack
    c8_if.C8_Fence_Req = 0;
    wait_clks(15);
  endtask

  task automatic run_fence_drop_during_sync();
    scen_name = "FENCE_DROP_DURING_SYNC";
    $display("SCENARIO: %s", scen_name);
    drive_both_idle(1);
    wait_clks(1);
    assert_fence_if_idle();
    // Wait until stop_access_req likely, then drop before ack if possible
    wait_clks(8);
    if (!c8_if.stop_access_ack)
      c8_if.C8_Fence_Req = 0;
    wait_clks(20);
  endtask

  task automatic run_idle_drop_before_stop_req();
    scen_name = "IDLE_DROP_BEFORE_STOP_REQ";
    $display("SCENARIO: %s", scen_name);
    drive_both_idle(1);
    wait_clks(1);
    assert_fence_if_idle();
    wait_clks(2);
    c8_if.C8_INT_Idle = 0; // SoC must drop fence_req (always block)
    wait_clks(20);
    drive_both_idle(1);
    wait_clks(5);
  endtask

  task automatic run_idle_drop_after_stop_req();
    scen_name = "IDLE_DROP_AFTER_STOP_REQ";
    $display("SCENARIO: %s", scen_name);
    drive_both_idle(1);
    wait_clks(1);
    assert_fence_if_idle();
    wait (c8_if.stop_access_req || c8_if.stop_access_ack || !c8_if.C8_Fence_Req);
    if (c8_if.stop_access_req && !c8_if.stop_access_ack) begin
      c8_if.C8_DMA_Idle = 0; // expect rej path, not ack
    end
    wait_clks(25);
    drive_both_idle(1);
    wait_clks(5);
  endtask

  task automatic run_rej_then_reattempt();
    scen_name = "REJ_THEN_REATTEMPT";
    $display("SCENARIO: %s", scen_name);
    drive_both_idle(1);
    wait_clks(1);
    assert_fence_if_idle();
    wait (c8_if.stop_access_req);
    c8_if.C8_INT_Idle = 0; // force rej
    wait_clks(15);
    drive_both_idle(1);
    wait_clks(3);
    assert_fence_if_idle(); // re-attempt
    wait (c8_if.C8_Fence_Ack);
    wait_clks(3);
    c8_if.C8_Fence_Req = 0;
    wait (!c8_if.C8_Fence_Ack);
    wait_clks(10);
  endtask

  task automatic run_exit_with_levels_under_mask();
    scen_name = "EXIT_WITH_LEVELS_UNDER_MASK";
    $display("SCENARIO: %s", scen_name);
    drive_both_idle(1);
    wait_clks(1);
    assert_fence_if_idle();
    wait (c8_if.C8_Fence_Ack && c8_if.int_mask);
    // Force levels high under mask via stub hooks
    u_dut.force_i2s_level = 1;
    u_dut.force_dma_level = 1;
    wait_clks(5);
    // Outs must remain low
    if (c8_if.audio_i2s_intr_out || c8_if.audio_dma_intr_out)
      $error("TB check: outs not masked under int_mask");
    c8_if.C8_Fence_Req = 0;
    wait (!c8_if.int_mask);
    wait_clks(c8_pkg::C8_UNMASK_MAX + 2);
    // After unmask, pending levels should propagate
    if (!(c8_if.audio_i2s_intr_out && c8_if.audio_dma_intr_out))
      $error("TB check: pending levels did not propagate after unmask");
    u_dut.force_i2s_level = 0;
    u_dut.force_dma_level = 0;
    wait_clks(10);
  endtask

  task automatic run_irq_under_mask_then_unmask();
    scen_name = "IRQ_UNDER_MASK_THEN_UNMASK";
    $display("SCENARIO: %s", scen_name);
    drive_both_idle(1);
    wait_clks(1);
    assert_fence_if_idle();
    wait (c8_if.int_mask);
    u_dut.force_i2s_level = 1;
    wait_clks(4);
    if (c8_if.audio_i2s_intr_out)
      $error("TB check: i2s out not masked");
    // Complete enter/exit to release mask
    wait (c8_if.C8_Fence_Ack);
    c8_if.C8_Fence_Req = 0;
    wait (!c8_if.int_mask);
    wait_clks(c8_pkg::C8_UNMASK_MAX + 1);
    if (!c8_if.audio_i2s_intr_out)
      $error("TB check: i2s level did not propagate after unmask");
    u_dut.force_i2s_level = 0;
    wait_clks(10);
  endtask

endmodule

// ---------------------------------------------------------------------------
// Behavioral C8 DUT stub — implements functional enter/exit timing bounds
// ---------------------------------------------------------------------------
module c8_dut_stub (
  c8_ctrl_if.dut vif
);

  import c8_pkg::*;

  bit force_i2s_level;
  bit force_dma_level;

  typedef enum logic [2:0] {
    ST_IDLE, ST_SYNC, ST_DECIDE, ST_SWITCH, ST_C8, ST_EXIT_SW, ST_EXIT_CLR
  } st_e;

  st_e st;
  int  sync_cnt, sw_cnt, clr_cnt;

  // Sync fence_req into local domain (abstract ~few cycles)
  logic fence_req_q1, fence_req_q2;
  always_ff @(posedge vif.clk or negedge vif.rst_n) begin
    if (!vif.rst_n) begin
      fence_req_q1 <= 0;
      fence_req_q2 <= 0;
    end else begin
      fence_req_q1 <= vif.C8_Fence_Req;
      fence_req_q2 <= fence_req_q1;
    end
  end

  always_ff @(posedge vif.clk or negedge vif.rst_n) begin
    if (!vif.rst_n) begin
      st <= ST_IDLE;
      sync_cnt <= 0; sw_cnt <= 0; clr_cnt <= 0;
      vif.C8_Fence_Ack     <= 0;
      vif.stop_access_req  <= 0;
      vif.stop_access_ack  <= 0;
      vif.stop_access_rej  <= 0;
      vif.switch_to_refclk <= 0;
      vif.selbout          <= 0;
      vif.int_mask         <= 0;
      vif.i2s_intr_level   <= 0;
      vif.dma_intr_level   <= 0;
      vif.audio_i2s_intr_out <= 0;
      vif.audio_dma_intr_out <= 0;
      force_i2s_level <= 0;
      force_dma_level <= 0;
    end else begin
      // Interrupt levels + mask gating (functional)
      vif.i2s_intr_level <= force_i2s_level;
      vif.dma_intr_level <= force_dma_level;
      vif.audio_i2s_intr_out <= (!vif.int_mask) && vif.i2s_intr_level;
      vif.audio_dma_intr_out <= (!vif.int_mask) && vif.dma_intr_level;

      unique case (st)
        ST_IDLE: begin
          vif.stop_access_rej <= 0;
          if (fence_req_q2) begin
            st <= ST_SYNC;
            sync_cnt <= 0;
          end
        end
        ST_SYNC: begin
          sync_cnt <= sync_cnt + 1;
          if (sync_cnt >= 5) begin
            vif.stop_access_req <= 1;
            st <= ST_DECIDE;
          end
          if (!fence_req_q2) begin
            vif.stop_access_req <= 0;
            st <= ST_IDLE;
          end
        end
        ST_DECIDE: begin
          if (!(vif.C8_DMA_Idle && vif.C8_INT_Idle)) begin
            vif.stop_access_rej <= 1;
            vif.stop_access_ack <= 0;
            vif.stop_access_req <= 0;
            st <= ST_IDLE;
          end else if (!fence_req_q2) begin
            vif.stop_access_req <= 0;
            st <= ST_IDLE;
          end else begin
            vif.stop_access_ack <= 1;
            vif.int_mask        <= 1;
            vif.switch_to_refclk <= 1;
            sw_cnt <= 0;
            st <= ST_SWITCH;
          end
        end
        ST_SWITCH: begin
          // Commit: idle/fence chatter does not abort
          sw_cnt <= sw_cnt + 1;
          if (sw_cnt == 18) vif.selbout <= 1;
          if (sw_cnt == 20) vif.selbout <= 0;
          if (sw_cnt >= 24) begin
            vif.C8_Fence_Ack <= 1;
            st <= ST_C8;
          end
        end
        ST_C8: begin
          if (!fence_req_q2) begin
            sw_cnt <= 0;
            st <= ST_EXIT_SW;
          end
        end
        ST_EXIT_SW: begin
          sw_cnt <= sw_cnt + 1;
          if (sw_cnt == 10) vif.selbout <= 0;
          if (sw_cnt >= 18) begin
            vif.C8_Fence_Ack <= 0;
            clr_cnt <= 0;
            st <= ST_EXIT_CLR;
          end
        end
        ST_EXIT_CLR: begin
          clr_cnt <= clr_cnt + 1;
          if (clr_cnt == 1) vif.stop_access_req <= 0;
          if (clr_cnt >= 2) begin
            vif.stop_access_ack  <= 0;
            vif.int_mask         <= 0;
            vif.switch_to_refclk <= 0;
            st <= ST_IDLE;
          end
        end
        default: st <= ST_IDLE;
      endcase
    end
  end

endmodule

// ---------------------------------------------------------------------------
// Lightweight non-UVM scoreboard (same functional rules as c8_scb)
// ---------------------------------------------------------------------------
module c8_scb_lite (
  c8_ctrl_if.mon vif
);

  import c8_pkg::*;

  c8_phase_e phase;
  int unsigned enter_wait, exit_wait, rej_wait, unmask_wait, err_cnt;
  bit fence_req_d, fence_ack_d, stop_ack_d, stop_rej_d, int_mask_d;
  bit pending_i2s, pending_dma, wait_unmask;

  always_ff @(posedge vif.clk or negedge vif.rst_n) begin
    if (!vif.rst_n) begin
      phase <= C8_PHASE_IDLE;
      enter_wait <= 0; exit_wait <= 0; rej_wait <= 0; unmask_wait <= 0;
      err_cnt <= 0; wait_unmask <= 0;
      fence_req_d <= 0; fence_ack_d <= 0; stop_ack_d <= 0;
      stop_rej_d <= 0; int_mask_d <= 0;
    end else begin
      // int_mask gating
      if (vif.int_mask && (vif.audio_i2s_intr_out || vif.audio_dma_intr_out)) begin
        $error("c8_scb_lite: outs asserted under int_mask");
        err_cnt <= err_cnt + 1;
      end
      if (!vif.int_mask && int_mask_d) begin
        pending_i2s <= vif.i2s_intr_level;
        pending_dma <= vif.dma_intr_level;
        if (vif.i2s_intr_level || vif.dma_intr_level) begin
          wait_unmask <= 1;
          unmask_wait <= 0;
        end
      end
      if (wait_unmask) begin
        if (( !pending_i2s || vif.audio_i2s_intr_out || !vif.i2s_intr_level) &&
            ( !pending_dma || vif.audio_dma_intr_out || !vif.dma_intr_level))
          wait_unmask <= 0;
        else begin
          unmask_wait <= unmask_wait + 1;
          if (unmask_wait > C8_UNMASK_MAX) begin
            $error("c8_scb_lite: unmask propagation timeout");
            err_cnt <= err_cnt + 1;
            wait_unmask <= 0;
          end
        end
      end

      if (vif.stop_access_ack && vif.stop_access_rej) begin
        $error("c8_scb_lite: ack/rej mutex");
        err_cnt <= err_cnt + 1;
      end
      if (vif.C8_Fence_Req && !fence_req_d && !vif.both_idle) begin
        $error("c8_scb_lite: fence_req without both idle");
        err_cnt <= err_cnt + 1;
      end

      // Phase + watchdog
      unique case (phase)
        C8_PHASE_IDLE: begin
          enter_wait <= 0; exit_wait <= 0; rej_wait <= 0;
          if (vif.C8_Fence_Req && !fence_req_d && vif.both_idle)
            phase <= C8_PHASE_ENTER_SYNC;
        end
        C8_PHASE_ENTER_SYNC: begin
          enter_wait <= enter_wait + 1;
          if (!vif.C8_Fence_Req && !vif.stop_access_ack)
            phase <= C8_PHASE_IDLE;
          else if (vif.stop_access_rej && !stop_rej_d)
            phase <= C8_PHASE_REJECTED;
          else if (vif.stop_access_ack && !stop_ack_d)
            phase <= C8_PHASE_ENTER_COMMIT;
          else if (enter_wait > C8_ACK_PROG_MAX) begin
            $error("c8_scb_lite: ENTER_SYNC deadlock");
            err_cnt <= err_cnt + 1;
            phase <= C8_PHASE_IDLE;
          end
        end
        C8_PHASE_ENTER_COMMIT: begin
          enter_wait <= enter_wait + 1;
          if (vif.C8_Fence_Ack && !fence_ack_d)
            phase <= C8_PHASE_IN_C8;
          else if (enter_wait > C8_ACK_PROG_MAX) begin
            $error("c8_scb_lite: ENTER_COMMIT deadlock");
            err_cnt <= err_cnt + 1;
            phase <= C8_PHASE_IDLE;
          end
        end
        C8_PHASE_IN_C8: begin
          if (!vif.C8_Fence_Req && fence_req_d)
            phase <= C8_PHASE_EXIT_SYNC;
        end
        C8_PHASE_EXIT_SYNC: begin
          exit_wait <= exit_wait + 1;
          if (!vif.C8_Fence_Ack && !vif.stop_access_req &&
              !vif.stop_access_ack && !vif.int_mask)
            phase <= C8_PHASE_IDLE;
          else if (exit_wait > C8_ACK_PROG_MAX) begin
            $error("c8_scb_lite: EXIT deadlock");
            err_cnt <= err_cnt + 1;
            phase <= C8_PHASE_IDLE;
          end
        end
        C8_PHASE_REJECTED: begin
          rej_wait <= rej_wait + 1;
          if (!vif.stop_access_req && !vif.stop_access_rej)
            phase <= C8_PHASE_IDLE;
          else if (rej_wait > C8_SYNC_MAX) begin
            $error("c8_scb_lite: REJECT hang");
            err_cnt <= err_cnt + 1;
            phase <= C8_PHASE_IDLE;
          end
        end
        default: phase <= C8_PHASE_IDLE;
      endcase

      fence_req_d <= vif.C8_Fence_Req;
      fence_ack_d <= vif.C8_Fence_Ack;
      stop_ack_d  <= vif.stop_access_ack;
      stop_rej_d  <= vif.stop_access_rej;
      int_mask_d  <= vif.int_mask;
    end
  end

  final begin
    $display("c8_scb_lite: final err_cnt=%0d phase=%s", err_cnt, c8_phase_name(phase));
  end

endmodule
