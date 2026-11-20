// -----------------------------------------------------------------------------
// c8_pkg — Parameters and types for functional C8 scoreboard / assertions
// Timing windows are bounds for progress/safety checkers, NOT exact RTL delays.
// -----------------------------------------------------------------------------
package c8_pkg;

  // Sync / switch cycle bounds (parameterized; tune per SoC timing)
  parameter int unsigned C8_SYNC_MIN      = 1;
  parameter int unsigned C8_SYNC_MAX      = 16;   // covers ~6 clk fence→stop_req sync
  parameter int unsigned C8_SWITCH_MIN    = 1;
  parameter int unsigned C8_SWITCH_MAX    = 40;   // covers ~20 clk enter switch
  parameter int unsigned C8_EXIT_SW_MAX   = 32;   // covers ~15 clk exit switch
  parameter int unsigned C8_SELBOUT_MIN   = 1;
  parameter int unsigned C8_SELBOUT_MAX   = 8;    // covers ~2 clk SELBOUT pulse
  parameter int unsigned C8_ACK_PROG_MAX  = 80;   // watchdog: enter/exit must complete
  parameter int unsigned C8_UNMASK_MAX    = 4;    // cycles for pending IRQ to propagate after unmask

  // Scoreboard protocol phase (functional, not RTL FSM copy)
  typedef enum logic [3:0] {
    C8_PHASE_IDLE,          // not in C8; waiting for fence_req while both idle
    C8_PHASE_ENTER_SYNC,    // fence_req seen; awaiting stop_access_req / decision
    C8_PHASE_ENTER_COMMIT,  // stop_access_ack risen; clock switch committed
    C8_PHASE_IN_C8,         // fence_ack high; deep sleep / C8 held
    C8_PHASE_EXIT_SYNC,     // fence_req fallen while in C8; exiting
    C8_PHASE_REJECTED       // stop_access_rej; expect return to idle (no hang)
  } c8_phase_e;

  // Abnormal / corner scenario tags for coverage
  typedef enum logic [4:0] {
    C8_SCN_NORMAL_ENTER_EXIT,
    C8_SCN_FENCE_PULSE_SHORT,
    C8_SCN_FENCE_DROP_DURING_SYNC,
    C8_SCN_IDLE_DROP_BEFORE_STOP_REQ,
    C8_SCN_IDLE_DROP_AFTER_STOP_REQ,
    C8_SCN_IDLE_CHATTER_AFTER_ACK,
    C8_SCN_REJ_THEN_REATTEMPT,
    C8_SCN_EXIT_WITH_LEVELS_UNDER_MASK,
    C8_SCN_IRQ_LEVEL_DURING_MASK,
    C8_SCN_UNMASK_PENDING_PROPAGATE,
    C8_SCN_FENCE_WHILE_NOT_IDLE,   // illegal SoC; checker may flag / assume false
    C8_SCN_EXIT_OTHER_IP           // fence drop while both idle stay high
  } c8_scenario_e;

  function automatic string c8_phase_name(c8_phase_e p);
    case (p)
      C8_PHASE_IDLE:         return "IDLE";
      C8_PHASE_ENTER_SYNC:   return "ENTER_SYNC";
      C8_PHASE_ENTER_COMMIT: return "ENTER_COMMIT";
      C8_PHASE_IN_C8:        return "IN_C8";
      C8_PHASE_EXIT_SYNC:    return "EXIT_SYNC";
      C8_PHASE_REJECTED:     return "REJECTED";
      default:               return "UNKNOWN";
    endcase
  endfunction

endpackage
