# Test 2 — Real Camera Timing with Synthetic Pixel Payload

## Purpose

This experiment isolates the camera pixel *values* from the camera's real
capture timing while preserving the production HyperRAM and host pipeline.

The GC0308 remains connected, powered, initialized over SCCB, and supplies
real `cam_pclk`, `cam_vsync`, and `cam_hsync` signals. The existing
`camera_interface` remains unchanged and continues to qualify the active
frame/line windows and generate `cam_byte_valid`, `cam_frame_done`, and
`cam_frame_error`.

Only the byte payload presented to `rgb565_frame_packer` is replaced.

## Data path

```text
Real GC0308
  |-- PCLK / VSYNC / HREF -------------------------------+
  |                                                     |
  |--> unchanged camera_interface (SCCB + DVP control)  |
              | cam_byte_valid / frame_done / error     |
              v                                         |
      camera_synthetic_byte_source <--------------------+
              | synthetic byte + delayed valid/done/error
              v
      unchanged rgb565_frame_packer
              v
      unchanged FIFO #1 (cam_pclk -> HyperRAM usr_clk)
              v
      unchanged HyperRAM Writer and generated HyperRAM IP
              v
      unchanged HyperRAM Reader / FIFO #2 / serializer
              v
      unchanged UART protocol and PC receiver
```

## Exact substitution behavior

- Source event: the existing `cam_byte_valid` pulse from the real camera
  capture controller.
- Payload: deterministic byte sequence
  `byte[index] = index[7:0] XOR index[15:8] XOR index[23:16] XOR index[31:24] XOR 0xA5`.
- Index increments exactly once per asserted source-valid event.
- Pipeline latency: two complete `cam_pclk` periods.
- `valid`, `frame_done`, and `frame_error` are delayed by the same two
  periods as the payload path.
- The original camera DVP data bus remains connected to the camera controller,
  but its pixel values are not used by the frame packer in this test.
- The packer, FIFO #1, HyperRAM Writer, HyperRAM IP, Reader, FIFO #2, UART
  serializer, packet protocol, and host receiver are reused without RTL changes.

## Expected counts for 640x480 RGB565

- Camera-qualified bytes: 614,400
- Packed 32-bit words: 153,600
- Pixels: 307,200
- HyperRAM bursts at 8 words/burst: 19,200
- Words per line: 320
- Bursts per line: 40

The source byte count is expected to equal the camera controller's qualified
byte count. The packer must report exactly 614,400 bytes and 153,600 words.
Capture CRC, Writer CRC, Read-ingress CRC, and host-reconstructed RGB565 CRC
must agree when calculated over the same byte ordering and with the same CRC
convention.

## How to build

Open `TEST2_CAMERA_SYNTH_HYPERRAM.gprj` in Gowin EDA. The project references
the unchanged production dependencies under `../gowin_cameradrive/src/`,
including the exact generated HyperRAM IP and PLL files. The Test 2 top-level
and synthetic source are local to this directory.

Use the same Tang Nano 4K pinout as the production project. The copied CST
retains the original port pin assignments because the top-level external port
names are unchanged.

## How to run

1. Connect the GC0308 and HyperRAM normally.
2. Program the Test 2 bitstream.
3. Wait for camera SCCB initialization to complete.
4. Press KEY1 once to trigger the one-shot capture, as in the production design.
5. Receive the UART frame using the corrected host receiver.
6. Compare all reported counts, status flags, and CRCs.

Do not disconnect the camera or substitute a free-running synthetic clock:
real camera PCLK/VSYNC/HREF are essential to this experiment.

## Interpretation

- **Test 2 passes (all counts and CRCs agree):** real camera timing and the
  camera-qualified valid cadence can traverse the FIFO/HyperRAM path with
  synthetic payload. This shifts suspicion toward real camera DVP data
  sampling/byte values or the relationship between sampled data and valid.
  It does not prove the sensor's RGB565 configuration or image quality.
- **Test 2 fails with capture/write CRC mismatch:** investigate the synthetic
  source, byte-valid cadence, packer, or FIFO write-side behavior first.
- **Capture/write CRC agree but read-ingress CRC differs:** the fault remains
  downstream of the capture CRC point, in the write/IP/memory/read path; the
  synthetic source alone does not exonerate the memory interface.
- **Counts differ:** inspect the first count divergence and sticky error flags;
  do not interpret CRC mismatch in isolation.

## Important limitations

This test deliberately keeps the camera's real timing and camera controller.
It is not a test with the camera disconnected. It also adds a small amount of
logic and two PCLK cycles of latency. The production HyperRAM and UART RTL are
not modified.

The project has been created from source. Gowin synthesis, place-and-route,
timing analysis, programming, and physical capture have NOT been executed here.
The PCLK frequency and electrical timing must still be validated on the board.
