# Test A — Camera-synchronous deterministic HyperRAM frame verification

## Purpose

Test A checks whether a complete deterministic frame survives the existing Test 4 capture FIFO, HyperRAM writer, HyperRAM read adapter, line readout, UART packetizer, and MATLAB receiver.

It deliberately keeps the real GC0308 timing. This is **not** a free-running 24 MHz test and it is **not** a replacement for the camera timing controller.

## Clock and timing contract

- The only clock for camera-side pattern generation, valid/data pipeline, RGB565 packer, and capture FIFO write port is the real `cam_pclk`.
- The unchanged `camera_interface` observes real `cam_vsync` and `cam_hsync`/HREF and produces `cam_byte_valid`, `cam_frame_done`, and `cam_frame_error`.
- The pattern source advances its byte index only when `cam_byte_valid` is asserted.
- Data, valid, frame-done, and frame-error are delayed together by two PCLK cycles.
- VSYNC and HSYNC/HREF are control/timing signals, not clocks.
- The capture FIFO write side remains in the `cam_pclk` domain. Its read side and the HyperRAM write/read logic remain in the generated HyperRAM `usr_clk` domain, with the existing asynchronous FIFO as the CDC boundary.

## Test pattern

For every four consecutive camera-qualified valid bytes, the shared RGB565 packer must emit:

`word[n] = 0xA5000000 XOR n`

where `n` is the zero-based 32-bit word index from the beginning of the one-shot capture.

The byte source emits each word MSB first. First expected words:

```text
A5000000
A5000001
A5000002
A5000003
A5000004
...
```

This makes the expected value at every word position explicit. It is stronger for locating shifts/reordering than a small repeating color pattern.

## Expected 640x480 capture

- 640 x 480 pixels
- 2 source bytes per RGB565 pixel
- 614,400 valid source bytes
- 153,600 packed 32-bit words
- 19,200 HyperRAM bursts of 8 words
- Expected capture CRC32 (MSB-first, init FFFFFFFF, no final XOR): `0x8152206C`

## Build

Open `TEST_A_CAMERA_SYNC_HYPERRAM.gprj` in Gowin EDA.

The project reuses the Test 4 top-level and shared production RTL, but includes the Test A pattern-source file **instead of** `../src/test3_pattern_camera_pclk_source.vhd`. Do not add both pattern source files because they intentionally implement the same VHDL entity name.

The existing Test 4 writer, reader, UART protocol, constraints, PLLs, and HyperRAM IP are not modified by Test A. The project paths assume the repository directory structure is preserved.

## MATLAB

Run:

```matlab
report = testA_receive_uart("/dev/ttyUSB0");
```

The receiver uses the existing Test 4 packet protocol, checks each packet CRC-16, validates all line sequence numbers and DONE telemetry, reconstructs the RGB565 byte stream from the received RGB888 pixels, and checks the full-frame CRC32 against `0x8152206C`. It saves `testA_capture.png` and `testA_report.mat`.

The image is an intentionally synthetic pattern, not a photograph. The important result is complete line reception and matching integrity checks.

## Run procedure

1. Open and compile this project in Gowin EDA.
2. Check that all relative source paths resolve and that the top-level entity is `Test4_CameraTiming_Test3Pattern_HyperRAM`.
3. Program the board only after successful synthesis and place-and-route.
4. Connect the UART at 115200 baud, 8-N-1.
5. Start `testA_receive_uart` in MATLAB, then press KEY1 once to trigger camera configuration/capture.
6. Save the complete MATLAB console output and report file.
7. Append the run date, bitstream/commit, board result, counters, CRCs, and first error information to `../TEST_LOG.md`.

## Pass criteria

A PASS requires all of the following:

- all 480 LINE packets received exactly once (the MATLAB receiver rejects missing and duplicate lines);
- all 153,600 reconstructed 32-bit words match `0xA5000000 XOR word_index` exactly;
- no packet CRC16 errors;
- DONE reports 614,400 source/capture bytes and 153,600 write/read-ingress words;
- capture, writer, read-ingress, FPGA readback, and MATLAB reconstructed CRC32 values all agree;
- capture CRC32 equals `0x8152206C`;
- no error/mismatch status bits are asserted and SYSTEM_OK is set.

A matching CRC alone is not treated as proof of every individual word. The host checks every reconstructed 32-bit word, packet CRC16, line sequence/count, payload lengths, and full-frame expected CRC.

## Validation status

Source files and expected CRC are prepared. This session has **not** run Gowin compile, synthesis, place-and-route, bitstream generation, or a physical-board test. Therefore Test A is not yet declared PASS. Record actual hardware results in `../TEST_LOG.md`.
