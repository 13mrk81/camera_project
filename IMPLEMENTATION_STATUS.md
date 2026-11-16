# Implementation Status — MATLAB Line Stream

Last updated: 2026-11-16

## Repository safety
- Working branch: `feature/matlab-line-stream`.
- Base branch: `main`.
- All implementation commits target this feature branch only.
- The feature branch is 19 commits ahead of `main`, 0 behind (last checked 2026-11-16).
- No merge or changes to `main` have been made.

## Baseline inspected
The current branch baseline and existing UART protocol sources were inspected before editing. The camera design defaults to 640x480. RGB565 is stored as two pixels per 32-bit HyperRAM word. Existing MATLAB code already implements the READY/LINE/DONE protocol, RGB888, CRC-16/CCITT-FALSE and ACK/NACK.

## Completed and saved
- [x] Created this status log, `DESIGN_NOTES.md`, and `VALIDATION.md`.
- [x] Added `camera_uart_frame_protocol.vhd`, adapted from the existing UART protocol. START is decoded as byte 0xC1; it triggers capture, then waits for HyperRAM write completion/error before READY.
- [x] Added `pulse_toggle_cdc.vhd` for sparse control-event crossings.
- [x] Copied UART RX/TX into `gowin_cameradrive/src` and added all new VHDL files to `HYPER_RAM_CONTROL.gprj`.
- [x] Replaced raw UART falling-edge camera trigger with decoded START and clk8-to-clk24 CDC.
- [x] Connected physical UART RX/TX at 8 MHz / 115200 baud / 8N1.
- [x] Routed RGB888 serializer bytes into the protocol source ready/valid channel.
- [x] Started HyperRAM readout only after READY has been acknowledged and the first LINE header is sent.
- [x] Changed the line reader to advance only on host ACK; NACK/ACK timeout rewinds the same line address and retries after FIFO #2 is empty.
- [x] Changed serializer accounting to checkpoint per-line CRC and counters, commit line count only on ACK, and restore counters on retry.
- [x] Separated UART-domain ACK/NACK pulses from synchronized HyperRAM-domain ACK/NACK events.
- [x] Added a bundled final-statistics CDC snapshot to the HyperRAM-domain integrity checker.
- [x] Added `gowin_cameradrive/matlab/matlab_gc0308_hyperram_receiver.m` for the camera stream.

## Remaining work
- [ ] Run a VHDL compiler/elaboration pass and resolve any compile-time issues.
- [ ] Run protocol-focused simulation: START/capture wait, READY ACK, valid line ACK, NACK retry, ACK timeout retry, final-line ACK, DONE ACK.
- [ ] Verify CRC and RGB byte order against MATLAB with a known test pattern.
- [ ] Open the Gowin project and run synthesis, timing analysis, and bitstream generation.
- [ ] Test on Tang Nano 4K + GC0308 + HyperRAM + USB-UART.
- [ ] Record board-level results and any timing/throughput adjustments.

## Known validation limitation
No GHDL, NVC, Vivado, or Gowin command-line compiler is available in the current execution environment. A direct Git clone also failed because outbound DNS access to github.com is unavailable. GitHub connector reads/writes work. Therefore, current validation is static source/port-map checking only; no compile, synthesis, simulation, or hardware test is claimed.

## Recovery procedure
If work is interrupted, read this file first, then `DESIGN_NOTES.md` and `VALIDATION.md`. Fetch the latest files from `feature/matlab-line-stream` before editing; never apply an old patch blindly.
