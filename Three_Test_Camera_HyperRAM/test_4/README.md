# Test 4 — Camera Timing with Test 3 Synthetic Pattern

## Objective

This is the requested combination: preserve the real GC0308 timing and capture path from `gowin_cameradrive`, but replace the camera pixel values with the deterministic synthetic byte pattern used by Test 3.

The camera remains connected and supplies PCLK, VSYNC, and HREF/HSYNC. The camera interface still detects frame/line boundaries and qualifies each byte. The synthetic source advances its byte index only when that camera-qualified byte-valid event occurs.

## Clock and synchronization

- Pixel/capture domain: real `cam_pclk`.
- Frame boundary: real `cam_vsync`, interpreted by the unchanged `camera_interface`.
- Active line window: real `cam_hsync` (GC0308 HREF/HSYNC), interpreted by the unchanged `camera_interface`.
- Synthetic data: Test 3's deterministic pattern formula, generated in the PCLK domain.
- HyperRAM user interface: generated HyperRAM user clock, with the existing asynchronous FIFO crossing retained.

VSYNC and HREF are control/timing inputs, not clocks. The source, byte-valid pipeline, packer, and capture FIFO write side are clocked by PCLK.

## Pattern

For byte index (i):

`byte[i] = i[7:0] XOR i[15:8] XOR i[23:16] XOR i[31:24] XOR 0xA5`

The formula is the same as Test 3. Unlike standalone Test 3, the index advances only on camera-qualified valid-byte events, so horizontal blanking, vertical blanking, line timing, and actual camera PCLK cadence are preserved.

## Data path

```
GC0308 PCLK / VSYNC / HREF
          |
          v
unchanged camera_interface
          | byte_valid / frame_done / frame_error
          v
Test-3-pattern source (cam_pclk)
          | synthetic byte + aligned valid/done/error
          v
RGB565 frame packer
          v
capture FIFO (cam_pclk -> HyperRAM usr_clk)
          v
existing HyperRAM writer / generated IP
          v
HyperRAM -> read adapter -> line readout -> UART
```

The real camera data bus is not used as the pixel payload. It remains connected to the camera interface ports for pinout and unchanged capture-controller compatibility.

## Build

Open `TEST4_CAMERA_TIMING_TEST3_PATTERN.gprj` in Gowin EDA. Keep this directory beside `gowin_cameradrive` and `test_2`; shared production RTL/IP and the camera timing constraints are referenced by relative paths. The CST/SDC files are reused from Test 2 because the top-level external port list is unchanged.

## Expected 640x480 RGB565 counts

- 614,400 source bytes
- 153,600 32-bit words
- 307,200 pixels
- 19,200 eight-word HyperRAM bursts
- Expected capture CRC under the documented MSB-first convention: `0x81BD9BFE`

## Validation status

This project is assembled from the existing Test 2 camera-timing implementation and the exact deterministic pattern formula used by Test 3. No Gowin compile, synthesis, place-and-route, timing closure, bitstream generation, or physical-board test has been run in this session. In particular, verify the generated project paths and PCLK timing in Gowin before programming the board.

## Test execution history and Test A

All attempts and measured outcomes under this directory are recorded append-only in [TEST_LOG.md](TEST_LOG.md).

### Test A — deterministic word-index frame

Open `test_A/TEST_A_CAMERA_SYNC_HYPERRAM.gprj`. Test A keeps the real GC0308 PCLK/VSYNC/HREF timing and reuses the existing Test 4 HyperRAM capture/readback/UART path, but substitutes a word-index pattern whose packed words are `0xA5000000 XOR word_index`.

The camera-side source advances only on camera-qualified valid-byte events in `cam_pclk`. The expected full-frame CRC32 is `0x8152206C`. MATLAB receiver: `test_A/host/testA_receive_uart.m`.

Test A is source-prepared only until a successful Gowin build and physical-board run are entered in `TEST_LOG.md`. Do not treat source creation or a calculated expected CRC as hardware validation.
