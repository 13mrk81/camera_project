# Test 4 — Test execution log

This file is the persistent record for every experiment performed under `test_4`. Add a new entry for each compile, programming attempt, and physical run. Never overwrite an earlier result; append a dated entry.

## Test index

| Test | Purpose | Data source / timing | HyperRAM path | Current status |
|---|---|---|---|---|
| Test 4 baseline | Test 3 synthetic byte pattern through real camera timing and HyperRAM/readback/UART | Pattern advances on real camera-qualified valid-byte events in `cam_pclk`; real VSYNC/HREF | Existing Test 4 capture FIFO, writer, reader | FAIL reported by user: synthetic data does not pass end-to-end CRC/readback validation; exact failing stage/log still to be attached |
| Test A | Verify a full deterministic frame with a word-index pattern | Real `cam_pclk`; real VSYNC/HREF qualify every byte; no free-running payload generation | Reuses Test 4 FIFO, HyperRAM writer, reader, UART | SOURCE PREPARED; compile and hardware run pending |

## Shared timing rules

- Camera-side logic is clocked only by real `cam_pclk`.
- Real `cam_vsync` and `cam_hsync`/HREF define frame and active-line timing through `camera_interface`.
- VSYNC and HSYNC/HREF are not clocks.
- Synthetic payload advances only on the camera-qualified `cam_byte_valid` event.
- The capture FIFO write clock is `cam_pclk`; its read clock is the HyperRAM IP `usr_clk`.
- A Test A PASS must include full-frame counters, CRC chain, packet/line completeness, and MATLAB reconstruction. Do not infer success from a single counter or CRC.

## Run entry template

Copy this block for each attempt and fill in actual measured values:

```text
Date/time:
Test:
Git branch / commit:
Gowin version:
Synthesis:
Place & Route:
Bitstream generated:
Board programmed:
Camera config result:
Frame dimensions:
Expected source bytes / words:
Measured capture bytes / words:
FIFO overflow:
Writer word count:
Read-ingress word count:
MATLAB packet count:
Missing / duplicate lines:
Packet CRC16 errors:
Capture CRC32:
Writer CRC32:
Read-ingress CRC32:
FPGA readback CRC32:
MATLAB reconstructed CRC32:
First mismatch address / word index:
Overall result: NOT RUN / PASS / FAIL
Notes / console log file:
```

## Historical observations

### 2026-11-24 — Test 4 baseline

- User reports the synthetic Test 4 data also exhibits missing/corrupted portions; MATLAB does not reconstruct a valid frame.
- CRC-16 packet validation / end-to-end integrity checks were used to establish that the received data is not valid.
- No numeric board log or exact first failing packet was included in this entry yet. Add the raw MATLAB console output before drawing a more specific conclusion.

### 2026-11-24 — Test A prepared

- Added a deterministic 32-bit word-index pattern: `0xA5000000 XOR word_index`.
- Pattern bytes are generated only on real camera-qualified `cam_byte_valid` events and clocked by `cam_pclk`.
- Real VSYNC/HREF timing, capture FIFO CDC, existing HyperRAM writer/readback, and UART packet protocol are retained.
- Expected 640x480 capture CRC32: `0x8152206C` (CRC-32/04C11DB7, MSB-first, init FFFFFFFF, no final XOR).
- Source preparation only; no Gowin build or board execution has been performed in this session.
