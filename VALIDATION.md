# Validation Log — One-way UART Camera Stream

## 2026-11-19 — Host buffering and UART byte pacing

- Removed the unsupported `InputBufferSize` Name-Value argument from MATLAB `serialport`. The modern API manages receive buffering automatically and does not document a user-configurable input-buffer size.
- MATLAB reads available serial data in chunks up to 8,192 bytes and records total-byte, maximum observed driver-queue, and maximum parser-buffer counters in the console report and saved MAT file.
- Added a configurable 25 us idle-high interval after every UART byte using 200 clk8 cycles at 8 MHz. UART bit timing remains 69 clocks/bit; the added interval is separate from the 8N1 frame.
- Updated the default transfer-time estimate to approximately 112.7 s, including inter-byte and inter-packet gaps.
- These are source changes only. MATLAB, VHDL compile/simulation, Gowin build, and hardware transfer have not yet been run.

## 2026-11-17 — One-way redesign

- Re-inspected the feature-branch HEAD, active Gowin top, protocol module, UART TX, line reader, readout wrapper, RGB565 serializer, asynchronous FIFO, MATLAB receiver, project file and pin constraints.
- Replaced RX command/ACK/NACK control with onboard KEY1 trigger and FPGA-TX-only framed packets.
- Updated the packet specification and MATLAB receive/parser state machine.
- Updated the active top and Gowin project file to remove UART RX from the build.
- Added two-flop synchronizers for camera-config status and reader error into clk8; retained existing toggle-based line-completion CDC and Gray-pointer async FIFOs.
- Added a local line acknowledgement only after final CRC byte's UART stop bit completes.
- Added a 20 ms gap between complete packets and after truncated-line abort before ERROR.
- Confirmed by source inspection that output FIFO #2 is 512 words at default settings and one 640-pixel row requires 320 words. The existing elaboration assertion enforces at least one full line of FIFO storage.
- Calculated the default transfer estimate: 925,993 UART bytes including all headers/CRC/status packets, approx. 79.87 s on the divider-derived 115942 baud, plus 9.68 s of inter-packet gaps, approx. 89.55 s total.
- Confirmed the MATLAB script contains no serial write call; it only reads available bytes and accepts CRC-valid packets.
- Confirmed the MATLAB resynchronizer can find a later CRC-valid ERROR packet even while an earlier LINE candidate is incomplete.

## Static checks performed

- The active top no longer contains uart_rx_i, u_uart_rx, protocol_rx_valid, protocol_line_retry, line_retry_usr, or the prior RX echo/self-test mux signals.
- The top connects the new protocol entity ports, including trigger, synchronized camera status, line serializer stream, and stats.
- The top ties both retry inputs of hyperram_line_readout inactive and keeps the one-way line-completion ACK path.
- Gowin project no longer compiles src/uart_rx.vhd; the file remains in the repository for unrelated standalone experiments.
- Pin constraints retain UART TX on pin 32 and map KEY1 trigger to pin 14 with LVCMOS18.
- MATLAB receiver does not transmit bytes.
- Packet field offsets and total length were checked against the common framing definition: total bytes = 9 + payload_length.

## Not run — do not treat as passed

- No VHDL compiler or simulator (GHDL/NVC) run.
- No Gowin EDA project analysis, synthesis, place-and-route, timing analysis, or bitstream generation.
- No MATLAB parser execution or serial-port run.
- No physical board test; KEY1 electrical level, USB-UART divider tolerance, camera capture and HyperRAM behavior still require measurement.
- No reset sign-off; top-level power-up/reset release is inherited and remains unresolved.

## Next validation sequence

1. Run Gowin project analysis/elaboration and fix any VHDL or port-map issue.
2. Simulate KEY1 debounce and exactly-one clk8-to-clk24 camera trigger.
3. Simulate STAGE/READY packets and compare CRC with the standard check vector.
4. Simulate RGB565 word expansion: verify the first 32-bit word emits R0,G0,B0,R1,G1,B1.
5. Simulate full 1920-byte LINE, inter-packet gap, local ACK only after final UART stop bit, and next-line sequencing.
6. Inject source starvation and readout error mid-LINE; verify ERROR follows UART idle + 20 ms and MATLAB resynchronizes.
7. Run the MATLAB receiver against generated test packets, then test the USB-UART path.
8. Verify KEY1 pin14 voltage, UART TX waveform/baud, and full-frame transfer on board.
9. Review reset release, HyperRAM timing/address semantics, and timing closure before sign-off.
