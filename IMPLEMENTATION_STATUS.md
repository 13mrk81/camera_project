# Implementation Status — One-way MATLAB RGB888 Line Stream

Last updated: 2026-11-19

## Repository safety

- Working branch: feature/matlab-line-stream (this is the existing branch matching the prior MATLAB-line work; no separate branch named matlab-line exists).
- Repository: 13mrk81/camera_project.
- All changes for this implementation are being made on this branch only.
- No merge or change to main is intended.

## Baseline inspected

The current branch was inspected before editing. The default frame is 640 x 480. Camera pixels are captured in RGB565, packed two pixels per 32-bit HyperRAM word, then expanded to RGB888 by the line serializer. The original UART protocol required PC-to-FPGA START and per-line ACK/NACK; that host RX dependency is now removed from the active main Gowin top.

## Changed in this implementation

- [x] Replaced UART RX START with Tang Nano 4K onboard KEY1 active-low trigger on FPGA pin 14; two-flop synchronizer and 20 ms debounce generate one trigger pulse.
- [x] Kept UART TX as the only serial data path. The main top no longer instantiates UART RX or contains RX command/echo/self-test selection.
- [x] Replaced the stop-and-wait host protocol with common framed packets: A5 5A, type, sequence, length, payload, CRC16.
- [x] Added STAGE logs for trigger accepted, camera configured, and frame stored; READY, LINE, DONE, and ERROR packet types.
- [x] Defined CRC-16/CCITT-FALSE over TYPE + sequence + payload length + payload; CRC trailer is high byte first.
- [x] Defined every RGB888 line as R,G,B triplets for pixels left-to-right; line sequence is the zero-based row number.
- [x] Added 20 ms inter-packet quiet time, including the final LINE -> DONE boundary and safe ERROR recovery after a truncated line.
- [x] Added configurable 25 us UART inter-byte idle spacing (200 clk8 cycles) in the UART TX physical layer.
- [x] Changed line advance to a local FPGA acknowledgement only after CRC_LO has completed its UART stop bit and TX returns idle; host ACK/NACK and retransmission are removed.
- [x] Tied readout retry inputs inactive; retained the existing full-line output FIFO, ready/valid serializer, and Gray-pointer asynchronous FIFO.
- [x] Added clk24 -> clk8 camera-config status synchronizers and usr_clk -> clk8 reader-error synchronizer.
- [x] Rewrote MATLAB receiver as receive-only, with packet CRC validation, zero-based row mapping, RGB triplet reconstruction, sliding-SOF resynchronization, DONE counter checks, and ERROR handling.
- [x] MATLAB reads available serial data in chunks up to 8,192 bytes and records RX/queue/parser-buffer diagnostics. The modern `serialport` API manages receive buffering automatically; it has no documented configurable `InputBufferSize`.
- [x] Changed the active Gowin project file list to remove UART RX from the main top build.
- [x] Changed the UART constraint to FPGA TX pin 32 only and added KEY1 trigger pin 14 with LVCMOS18.

## Data-rate and buffering design

At the 8 MHz clock, the current UART divider is 69 clocks/bit, or approximately 115942 baud. At 640 x 480, a LINE packet is 1929 bytes (1920 RGB payload + 9 framing/CRC bytes). With a 25 us inter-byte idle interval and 20 ms inter-packet gaps, estimated transfer time is approximately 112.7 s, excluding capture and HyperRAM write time.

Output FIFO #2 is 512 x 32 bits, compared with 320 words for one 640-pixel line. The readout engine only requests the next row after the current row packet is physically complete and the local acknowledgement crosses to usr_clk. This is the intended no-overrun flow-control mechanism; the no-reverse-channel link still cannot retransmit a row lost outside the FPGA.

## Remaining work — must not be reported as completed

- [ ] Verify all VHDL source syntax and named port maps in Gowin EDA.
- [ ] Simulate packet header/payload/CRC sequencing and UART-ready/valid timing.
- [ ] Confirm the CRC implementation against the standard 123456789 -> 0x29B1 vector in HDL and MATLAB.
- [ ] Simulate a full row, source starvation, readout error mid-row, and ERROR packet resynchronization.
- [ ] Confirm exact Tang Nano 4K KEY1 pin/bank voltage against the board revision and measure trigger/UART signals.
- [ ] Verify actual USB-UART baud tolerance and host buffering under a ~113 s transfer; inspect the new MATLAB queue/buffer counters.
- [ ] Run Gowin synthesis, timing analysis and bitstream generation.
- [ ] Test on Tang Nano 4K + GC0308 + HyperRAM and compare a known-color test image.

## Known validation limitation

No GHDL, NVC, MATLAB, or Gowin compiler/IDE was executed as part of this connector-based edit. No VHDL compilation, simulation, synthesis, bitstream generation, or hardware test is claimed. The top still has an unresolved reset sign-off item: rst_n is held high internally and PLL-derived ip_rst_n is consumed across clock domains. Static checks and protocol reference checks are recorded separately in VALIDATION.md.

## Recovery procedure

If the session is interrupted, fetch the latest branch head from feature/matlab-line-stream, then read this file, DESIGN_NOTES.md, UART_ONE_WAY_PROTOCOL.md, and VALIDATION.md. Do not replay an old patch over newer work.
