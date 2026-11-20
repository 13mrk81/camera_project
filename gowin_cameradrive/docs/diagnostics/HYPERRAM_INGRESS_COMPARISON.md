# HyperRAM Ingress Path: Synthetic Generator vs. GC0308

**Branch:** feature/hyperram-storage-selftest  
**Project:** gowin_cameradrive  
**Status:** Initial RTL inspection — no RTL changes made  
**Purpose:** Track architectural differences, measured/calculated rates, proposed fixes, and verification tests for the data path from source to HyperRAM.

---

## 1. Investigation objective

Compare these two source-to-memory paths:

1. **Synthetic self-test:** storage_test_pattern_generator → RGB565 packer → capture FIFO → write engine → HyperRAM.
2. **Camera capture:** GC0308 DVP interface → RGB565 packer → capture FIFO → write engine → HyperRAM.

The central question is whether the two paths become identical at the packer/FIFO boundary, and whether the camera can supply data at a rate that the FIFO and HyperRAM write engine can sustain without dropping bytes or words.

The successful synthetic self-test validates the synthetic source and the tested storage/readout/UART path. It does **not** by itself validate the GC0308 sampling path.

## 2. Initial finding: the FIFO write-clock domains differ

The current RTL connects the capture FIFO write clock differently in the two top-level designs.

| Item | Synthetic self-test | GC0308 camera |
|---|---|---|
| Top-level | HyperRAM_Storage_SelfTest.vhd | Camera_HyperRAM_OneFrame.vhd |
| Source | storage_test_pattern_generator | camera_interface |
| Source/packer clock | clk24 | cam_pclk |
| Packer clock port | cam_pclk => clk24 | cam_pclk => cam_pclk |
| Capture FIFO write clock | wr_clk => clk24 | wr_clk => cam_pclk |
| Capture FIFO read clock | rd_clk => usr_clk | rd_clk => usr_clk |
| FIFO implementation | async_fifo_32 | async_fifo_32 |

Relevant source locations:

- Synthetic top-level: HyperRAM_Storage_SelfTest.vhd, around lines 605–673.
- Camera top-level: Camera_HyperRAM_OneFrame.vhd, around lines 673–743.
- FIFO implementation: async_fifo_32.vhd.

This is a real clock-domain difference, not merely a naming difference. In the synthetic design, the packer and FIFO write side run from the 24 MHz fabric clock. In the camera design, they run from the sensor's DVP pixel clock, cam_pclk.

The FIFO read side is connected to usr_clk in both designs. The asynchronous FIFO is therefore already the CDC boundary from the source/write-clock domain into the HyperRAM user-clock domain. Do not add another CDC block before this FIFO unless a separate clock-domain crossing is identified and justified.

## 3. Synthetic generator rate from RTL

File: storage_test_pattern_generator.vhd

The generator's RTL states that it emits **one RGB565 byte per clk_i cycle during active line periods**. It emits two bytes per pixel, MSB first and then LSB.

In the synthetic top-level:

- clk_i => clk24
- G_LINE_BLANK_CYCLES => 306
- G_FRAME_BLANK_CYCLES => 31720
- Frame geometry: 640 × 480 pixels.

At 24 MHz:

- Active bytes per line = 640 × 2 = 1280 bytes.
- Active-line duration = 1280 cycles.
- Horizontal blank duration = 306 cycles.
- Total line duration = 1586 cycles.
- Frame duration in generator clock cycles = 480 × 1586 + 31720 = 793000 cycles.
- Frame time = 793000 / 24 MHz ≈ 33.0417 ms.
- Frame rate ≈ 30.27 frames/s.
- Payload per frame = 640 × 480 × 2 = 614400 bytes.
- Average payload rate over the complete generated frame period ≈ 18.59 MB/s.
- Instantaneous payload rate while an active line is being emitted = 24 MB/s.

These are RTL-derived values, not a measurement of the physical camera timing.

## 4. Camera clock: what is and is not established

The camera top-level has a cam_pclk input. The capture FSM in camera_interface.vhd is clocked on rising_edge(cam_pclk); the RGB565 packer and capture FIFO write side also use cam_pclk.

The top-level also has cam_clk_i, connected to the camera interface as clkcam. This is distinct from cam_pclk:

- cam_clk_i is the clock supplied to/used for the sensor master-clock function in the current design.
- cam_pclk is the DVP pixel clock used to sample the sensor's parallel output.

Do not assume that cam_pclk is 24 MHz, 48 MHz, or any other nominal value without checking the configured sensor timing and measuring the actual pin. The exact active-pixel byte cadence also depends on the capture FSM's HSync/VSync/valid qualification, not just the raw PCLK frequency.

**Current unknowns to resolve:**

1. Actual measured cam_pclk frequency on the board.
2. Whether one accepted byte is produced on every PCLK cycle during the active region.
3. Whether pixel_byte_valid_sig has any gaps inside an active line.
4. Actual line period, active bytes per line, frame period, and blanking intervals.
5. Whether the camera's configured output timing matches the generator's modeled timing.

## 5. Important distinction: do not add a new camera clock or CDC yet

The current camera capture path already uses the sensor's cam_pclk domain through:

camera_interface → rgb565_frame_packer → async_fifo_32 write port.

The FIFO then crosses into usr_clk, which is the memory-controller user-clock domain.

Therefore, generating a new cam_clk is not automatically the right fix. The sensor's DVP data must be sampled in the clock domain specified by its interface timing — normally the sensor-provided PCLK. Replacing that with an unrelated internally generated clock could violate the sensor's data setup/hold timing.

If the measured camera byte rate is too high for the downstream service rate, the likely remedies are to increase buffering, ensure the write engine drains the FIFO fast enough, or change the sensor output timing if supported. A new CDC is only appropriate if data is intentionally transferred between distinct clock domains; it does not solve a throughput deficit.

## 6. Shared and differing logic to verify next

The initial top-level inspection suggests the same packer entity and same asynchronous FIFO entity are instantiated in both projects. This is encouraging, but it does not yet prove the complete write paths are identical.

Next compare, line-by-line:

- Packer generics and port wiring.
- FIFO depth/generic values and reset behavior.
- FIFO read-enable generation.
- Burst assembly and burst length.
- Write-engine state machine and request/ready handshake.
- HyperRAM command/address/data timing.
- FIFO level thresholds and behavior when fewer than one burst's worth of words are available.
- Capture completion and end-of-frame drain behavior.

The two top-level files must be compared beyond the FIFO instance; do not infer identical write behavior solely from matching module names.

## 7. Proposed rate and buffering measurements

Add or expose telemetry only after confirming what already exists. The following measurements are desirable in both modes:

| Measurement | Capture point | Purpose |
|---|---|---|
| Source byte-valid count | Generator output / camera accepted-byte boundary | Number of bytes actually offered |
| Packer output word count | Packer output | Number of complete 32-bit words produced |
| FIFO write count | Accepted FIFO writes (wr_en && !full) | Number of words actually stored |
| FIFO overflow attempts | wr_en && full | Detect dropped words |
| FIFO maximum write-domain level | FIFO write-side level | Measure peak backlog |
| FIFO maximum read-domain level | FIFO read-side level | Observe occupancy from reader domain |
| FIFO read count | Accepted FIFO reads | Number of words consumed by writer |
| HyperRAM committed word count | Successful write transactions | Confirm memory-side completion |
| Write-engine busy/stall cycles | Write engine | Quantify service interruptions |

For each source, calculate:
- Peak input rate during active data.
- Average input rate over a full frame.
- Average and peak FIFO drain rate.
- Maximum FIFO occupancy.
- Longest interval during which the write engine does not consume data.
- Whether the FIFO can absorb that interval without reaching full.

A FIFO level alone is not sufficient to establish no data loss; count accepted writes and rejected write attempts.

## 8. Proposed verification sequence

### Test A — Establish synthetic baseline

1. Keep the known-good synthetic self-test unchanged.
2. Record the actual 24 MHz clock and generator timing.
3. Confirm 614400 source bytes and 153600 packed 32-bit words for 640×480 RGB565.
4. Record FIFO maximum occupancy, accepted writes, reads, and overflow attempts.

### Test B — Measure the camera DVP timing

1. Measure cam_pclk with an oscilloscope or logic analyzer.
2. Capture PCLK, HSync/HREF, VSync, and data together.
3. Determine active byte count per line, line period, frame period, and blanking.
4. Compare measured timing with the generator's modeled 1586-cycle line and 793000-cycle frame.

### Test C — Compare at the packer/FIFO boundary

1. Use the same frame geometry and pixel format in both modes.
2. Compare byte counts, packed-word counts, ordering, and CRC at the packer output.
3. Compare FIFO accepted-write counts and overflow attempts.
4. Keep the HyperRAM readout/UART path unchanged.

### Test D — Isolate source-side faults

If the camera-side packer output differs from the expected byte count or CRC while the synthetic mode passes, investigate camera sampling, PCLK edge, HSync/VSync qualification, sensor register configuration, and byte ordering before changing the HyperRAM writer.

## 9. Current conclusions

- **Confirmed:** The synthetic design writes the capture FIFO using clk24.
- **Confirmed:** The camera design writes the same FIFO entity using cam_pclk.
- **Confirmed:** Both FIFO instances read on usr_clk.
- **Confirmed:** The synthetic generator emits one byte per clk_i cycle during active line periods.
- **Not yet confirmed:** The actual camera PCLK frequency and accepted-byte rate.
- **Not yet confirmed:** Whether both top-level write engines are functionally identical in all control and end-of-frame cases.
- **Not yet confirmed:** Whether the camera input rate can be sustained without FIFO overflow under worst-case HyperRAM service stalls.
- **No RTL changes proposed or applied in this investigation note.**

## 10. Source files

- src/HyperRAM_Storage_SelfTest.vhd
- src/Camera_HyperRAM_OneFrame.vhd
- src/storage_test_pattern_generator.vhd
- src/camera_interface.vhd
- src/rgb565_frame_packer.vhd
- src/async_fifo_32.vhd
- src/hyperram_line_reader.vhd
- src/hyperram_line_readout.vhd

---
*Update this document as code differences are confirmed, experiments are run, and design changes are made. Record each change with its commit, rationale, expected behavior, and test result.*
