# Camera + HyperRAM — Three-Test Consolidated Workspace

Target: Sipeed Tang Nano 4K / GW1NSR-LV4CQN48PC6/I5, GC0308 DVP camera, Gowin EDA.

This folder groups three complementary experiment stages while retaining each original Gowin project and its source set.

## Test 1 — Real camera capture baseline
Open `gowin_cameradrive/HYPER_RAM_CONTROL.gprj`. This is the original camera-to-RGB565 packer/FIFO/HyperRAM/readback/UART path. It captures real DVP pixel values using cam_pclk.

## Test 2 — Real camera timing, synthetic payload
Open `test_2/TEST2_CAMERA_SYNTH_HYPERRAM.gprj`. GC0308 remains connected and supplies real PCLK/VSYNC/HREF; only pixel-byte payload is replaced with a deterministic synthetic sequence. This isolates data-value sampling from timing/valid cadence.

## Test 3 — Independent 24 MHz synthetic source
Open `test_3/TEST3_24MHZ_SYNTH_HYPERRAM.gprj`. The synthetic byte generator, RGB565 packer, and capture FIFO write port use the PLL-derived 24 MHz clock; HyperRAM user-side logic remains on the generated IP user clock.

## Test 4 — Test 3 pattern with real camera timing
Open `test_4/TEST4_CAMERA_TIMING_TEST3_PATTERN.gprj`. It preserves the real GC0308 PCLK/VSYNC/HREF capture timing and the production HyperRAM/UART path, while generating the Test 3 deterministic byte pattern in the camera PCLK domain. The byte index advances only on camera-qualified valid-byte events. See `test_4/README.md` for the exact architecture and validation limitations.

## Additional Test 3 snapshots
- `test_3_24mhz_independent/`
- `test_3_clk24_independent/`

These source snapshots are retained separately because their top-level/constraints/docs are not guaranteed to be identical. Compare before selecting a canonical Test 3 revision.

## Shared dependencies
Test 2 and Test 3 GPRJ files intentionally reference `../gowin_cameradrive/src/`. Keep this directory layout intact. It contains shared RTL, Gowin PLL generated source/configuration, HyperRAM generated IP source/configuration, constraints, FIFO, CDC, packer, readout, and UART modules.

## Build
1. Open/build Test 1 independently.
2. Open/build Test 2 independently.
3. Open/build Test 3 independently.
4. Do not add all three top-level VHDL files to one GPRJ simultaneously: these are separate experiments with distinct top-level entities and potentially duplicate design units.
5. For each, verify source paths, device, CST/SDC, PLL clocks, HyperRAM calibration, CDC constraints, synthesis, place-and-route, and timing reports in Gowin EDA.

## Validation status
This is source consolidation, not proof of successful compilation or hardware validation. No bitstream, physical capture, or passing result is asserted.

## Documented synthetic frame
For 640x480 RGB565: 614,400 bytes, 153,600 32-bit words, and 19,200 8-word bursts. The documented deterministic byte pattern has expected capture CRC32 0x81BD9BFE under the stated MSB-first CRC-32 convention. Confirm against each selected RTL revision and host receiver before treating it as a pass criterion.
