# Audio I2S C8 functional scoreboard

Verification IP that checks **C8 enter/exit protocol intent** on `c8_ctrl_if`, not RTL next-state mirroring.

## Layout

| File | Role |
|------|------|
| `c8_ctrl_if.sv` | Interface (SoC handshake + whitebox) |
| `c8_pkg.sv` | Timing bounds, phase enum, scenario tags |
| `c8_assertions.sv` | SVA: mask, ack/rej, progress, exit, covers |
| `c8_scb.sv` | UVM `c8_scb` (compile with `+define+UVM`) |
| `c8_cover.sv` | Covergroup for abnormal timings |
| `c8_tb_stub.sv` | Behavioral DUT stub + stimulus + `c8_scb_lite` |
| `filelist.f` | Compile order |

## Functional rules (summary)

1. **Interrupt masking** — while `int_mask`, `audio_*_intr_out` stay low even if `*_intr_level` assert; after unmask, pending levels propagate within `C8_UNMASK_MAX`.
2. **Ack vs rej** — mutual exclusion; ack only when both idles high; not-idle at stop → rej.
3. **SoC constraints** — `C8_Fence_Req` only when both idle; idle drop clears fence_req. No “IRQ before enter still enters C8”.
4. **Commit / exit progress** — bounded watchdogs; no stuck mid-enter or mid-exit.
5. **Abnormal coverage** — short fence pulse, drop during sync, idle drops, rej+reattempt, IRQ under mask, unmask propagate.

See project doc `docs/c8-scb-checks.md` for the full rule list.

## Integrate

```text
setenv C8_TB_DIR <path>/tb/c8
# UVM env: +define+UVM and bind/instantiate c8_assertions + c8_scb
# Smoke:   compile filelist.f and run c8_tb_stub
```
