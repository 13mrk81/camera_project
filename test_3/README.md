# Test 3 — 24 MHz Independent Synthetic Data to HyperRAM

## Objective

Test 3 removes the camera pixel clock and camera timing signals from the capture/write data path. It asks whether a deterministic 640×480 RGB565 stream generated entirely in the FPGA's 24 MHz clock domain can pass through the packer, capture FIFO, HyperRAM writer, HyperRAM, reader, and UART readback path.

This test is independent of camera PCLK, VSYNC, HREF, SCCB, and camera pixel data. The camera connector ports remain in the top-level entity only to preserve the existing board pin-constraint file; they are unused. The camera master-clock output is held low.

## Clocking

The existing board clock input is 8 MHz on `clk8`. The existing Gowin PLL block `Gowin_PLLVR_1` is reused. Its configuration declares `FCLKIN="8"`, `FBDIV_SEL=2`, and `ODIV_SEL=32`, producing the established 24 MHz `clk24` clock.

No `cam_pclk` signal is used to generate, qualify, pack, or write synthetic bytes.

## Data path

```text
8 MHz board oscillator
        |
        v
Gowin_PLLVR_1
        |
        +---- clk24 (24 MHz)
                  |
                  +--> test3_synthetic_frame_source
                  |      one byte / clk24 cycle
                  |      614,400 bytes / frame
                  |
                  +--> rgb565_frame_packer (clocked by clk24)
                  |      4 bytes -> 1 x 32-bit word
                  |      CRC32 + byte/word counters
                  |
                  +--> async FIFO #1 write side (wr_clk = clk24)
                             |
                             | asynchronous CDC
                             v
                      HyperRAM usr_clk read side
                             |
                             v
                      existing HyperRAM writer
                             |
                             v
                         HyperRAM
                             |
                             v
                   existing read adapter / line reader
                             |
                             v
                      FIFO #2 / serializer
                             |
                             v
                       UART / MATLAB
```

The existing HyperRAM IP, writer state machine, read adapter, line readout, serializer, UART packet protocol, and telemetry checker are retained from Test 2. Capture FIFO #1 remains asynchronous because its read side is clocked by HyperRAM `usr_clk`.

## Synthetic frame definition

- Resolution: 640×480 pixels.
- Format: RGB565 byte stream, 2 bytes/pixel.
- Total bytes: 614,400.
- Packer output: 153,600 words of 32 bits.
- HyperRAM burst: 8 words, 19,200 bursts/frame.
- Source cadence: one byte per 24 MHz cycle while active.
- Nominal source duration: 614,400 / 24 MHz = 25.6 ms.
- Pattern: `byte[index] = index[7:0] XOR index[15:8] XOR index[23:16] XOR index[31:24] XOR 0xA5`.
- Expected capture CRC32: `0x81BD9BFE` (MSB-first CRC-32/04C11DB7, init `0xFFFFFFFF`, no final XOR).

The pattern is identical to Test 2, so the expected capture CRC remains the same. Unlike Test 2, the source counter advances every 24 MHz cycle while active; it does not wait for camera byte-valid events.

## Trigger and readiness

- KEY2 resets the design.
- The existing PLL must lock and pass its stability counter before the synthetic source is marked ready to the UART protocol.
- KEY1 triggers the one-shot transfer.
- The existing transfer-start event crosses from `clk8` into `clk24` through the pulse-toggle CDC.
- The source emits one complete frame and then stops.

No camera must be connected. The retained camera pins are not part of the experiment.

## Build

Open `TEST3_24MHZ_SYNTH_HYPERRAM.gprj` in Gowin EDA from the repository checkout. The project reuses unchanged dependencies under `../gowin_cameradrive/src/`, including the generated HyperRAM IP and PLL files. Do not copy only `test_3` out of the repository; relative source dependencies must remain available.

The constraints retain the same board pin assignments as Test 2. Camera connector pins are unused but remain present in the top-level port list for pinout compatibility.

## Run

1. Connect the Tang Nano 4K and HyperRAM as in the existing hardware setup. The camera may remain disconnected.
2. Program the Test 3 bitstream.
3. Wait for PLL lock/stability and HyperRAM calibration.
4. Run `test3_receive_uart` in MATLAB and select the FPGA USB-UART port.
5. Press KEY1 once.
6. Inspect packet CRC warnings, line count, DONE telemetry, and the CRC/count checkpoints.

## Interpretation

- **Capture CRC and Writer CRC match, but Read-ingress CRC differs:** the mismatch remains downstream of the writer input-data checkpoint. Investigate HyperRAM command/data acceptance, address progression, physical write/read transaction, and read-response alignment.
- **Capture CRC differs from `0x81BD9BFE`:** investigate the 24 MHz source, packer, or source-to-packer timing.
- **Capture CRC equals expected, Writer CRC differs:** investigate capture FIFO crossing, FIFO read-valid handling, and writer burst assembly.
- **Writer CRC equals capture CRC, Read-ingress CRC differs:** the synthetic source and capture FIFO are not the first observed divergence; the writer/IP/memory/read path remains the main suspect.
- **UART packet CRC16 errors or missing image lines:** treat this as a separate UART/protocol/host-receiver integrity problem. Do not interpret missing UART lines as proof of HyperRAM corruption.

## Validation status

This directory is a source-level experiment derived from Test 2. It has not been compiled, simulated, synthesized, placed/routed, timing-closed, programmed, or tested on physical hardware in this session. The 24 MHz PLL configuration is reused from the checked-in source, but generated-clock propagation and CDC/timing paths must be verified in Gowin before relying on hardware results.

The previous Test 2 UART log showed widespread packet CRC16 mismatches and ended with 322 missing image lines. That host-stream problem is independent of PCLK versus 24 MHz source generation. Test 3 reuses the same packet format and receiver implementation, so it does not claim to fix that issue.

## MATLAB receiver

```matlab
report = test3_receive_uart("/dev/ttyUSB0"); % Linux
% report = test3_receive_uart("COM5");       % Windows
```

Without an argument, the receiver lists available serial ports and prompts for a numeric selection. It saves `test3_capture.png` and `test3_report.mat` in the current MATLAB directory.
