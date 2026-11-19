# HyperRAM Storage Self-Test — Design Plan

## 1. Purpose

This branch replaces the GC0308 data source with a deterministic FPGA pattern generator while preserving the camera project's storage and readout path.

The test must answer independently:

1. Did the source generate the expected frame?
2. Did the input FIFO preserve every packed 32-bit word?
3. Did the HyperRAM write interface receive the correct burst data?
4. Did HyperRAM return the same words on read?
5. Did the output FIFO preserve the read data?
6. Did the RGB565 serializer and UART/MATLAB transport preserve the expected pixels and line order?

The original camera branch is not modified.

## 2. Branch and baseline

- Repository: `13mrk81/camera_project`
- Base branch: `feature/matlab-line-stream`
- Test branch: `feature/hyperram-storage-selftest`
- Existing camera path and HyperRAM reader/writer are the baseline.
- New source module: `src/storage_test_pattern_generator.vhd`

## 3. Frame geometry and storage format

The test uses the same default geometry and data format as the camera capture:

| Parameter | Value |
|---|---:|
| Width | 640 pixels |
| Height | 480 lines |
| Input format | RGB565 |
| Bytes per pixel | 2 |
| Bytes per line | 1,280 |
| 32-bit words per line | 320 |
| Words per 8-word burst | 8 |
| Bursts per line | 40 |
| Total raw bytes | 614,400 |
| Total 32-bit words | 153,600 |
| RGB888 bytes sent to MATLAB | 921,600 |

The memory writer must continue to load a complete 8-word burst before issuing its write sequence. Existing command spacing and address stride are not changed as part of the first test.

The project baseline uses `G_CMD_INTERVAL_CYCLES=21` and address stride 16. Gowin IPUG944-2.1E specifies a minimum Tcmd of 19 user clocks for burst length 32 at HyperRAM speeds up to 166 MHz, and 24 clocks above 166 MHz; sequential burst addresses advance by burst length/2 (=16) user-address units. Therefore 21 is consistent only while the configured HyperRAM operating speed remains at or below 166 MHz. Do not shorten the interval; verify the actual IP configuration and generated example before changing it. Reference: https://cdn.gowinsemi.com.cn/IPUG944E.pdf.

## 4. Synthetic source pattern

For pixel coordinate `(x,y)`, generate the 16-bit RGB565 word:

```text
P(x,y) = (251*x + 911*y + 13*x*y + 0xA65C) mod 65536
```

The generator emits each pixel MSB first:

- byte 0: `P[15:8]`
- byte 1: `P[7:0]`

MATLAB must independently calculate the same pattern using sufficiently wide integer arithmetic (for example `uint64`) and then apply the exact RGB565-to-RGB888 expansion used by `rgb565_line_serializer.vhd`. For the default 640x480 frame, the expected raw-byte CRC32 (MSB-first, init FFFFFFFF, no final XOR) is `0xA3734E43`; the MATLAB reference function asserts this regression value.

This pattern varies across both coordinates and both bytes. A byte swap, bit shift, repeated/missing byte, wrong word order, or line displacement should produce a deterministic mismatch.

## 5. Camera-like source cadence

The generator runs from the same 24 MHz clock domain used to clock the camera master clock in the existing top. It emits one valid byte per clock during each active line and inserts explicit horizontal and vertical blanking intervals.

The synthetic source now follows the register values explicitly written by the camera project's `C_INIT_TABLE`, rather than the sensor's power-on defaults:
- P0:0x01 = 0x32 and P0:0x0F = 0x01 -> Hb = 0x132 = 306 PCLKs
- P0:0x02 = 0x0C and P0:0x0F = 0x01 -> Vb = 0x00C = 12 line periods
- P0:0x09/0x0A configure a 488-row sensor window, while the FPGA capture path retains 480 rows
- P0:0x28 = 0x00 -> no programmed clock division

For 1,280 active byte clocks per captured line:
- line period = 1,280 + 306 = 1,586 clocks
- the source models 8 non-payload window rows plus 12 VBlank rows: 20 * 1,586 = 31,720 blank clocks
- frame period = 480 * 1,586 + 31,720 = 793,000 clocks
- at 24 MHz, nominal frame rate is approximately 30.26 frames/s

This is a first-order timing model derived from the project's register table and 480-row capture contract, not a measured waveform guarantee. Verify the actual DVP PCLK, HSYNC line period, and VSYNC frame period with ILA/oscilloscope before claiming exact sensor-rate equivalence. GC0308 register definitions are in the datasheet: https://min.at/prinz/fp-content/attachs/GC0308.pdf.

## 6. Required data-path architecture

```text
storage_test_pattern_generator
        |
        | byte + valid, camera-like cadence
        v
rgb565_frame_packer
        |
        | 32-bit words + capture CRC/counts
        v
Input asynchronous FIFO (#1)
        |
        | eight words loaded into burst_buffer
        v
Existing HyperRAM write engine
        |
        | 8-word burst + configured inter-burst spacing
        v
HyperRAM IP / physical memory
        |
        | read commands with existing command interval
        v
Existing HyperRAM line reader
        |
        | read-data ingress checkpoint
        v
Output asynchronous FIFO (#2)
        |
        | 32-bit words
        v
rgb565_line_serializer
        |
        | RGB888 byte stream
        v
Existing UART packet protocol
        |
        v
MATLAB reference comparison and diagnostic report
```

Do not rewrite the FIFO, writer, reader, serializer, or UART path before the baseline test. The first implementation should replace only the camera source and its clock/data-valid connection.

## 7. Integrity checkpoints

A single end-to-end CRC is insufficient to localize a fault. Use independent checkpoints:

| Checkpoint | Where measured | What a mismatch means |
|---|---|---|
| Generator expected pattern | MATLAB reference | Independent oracle |
| Generator byte count | Synthetic source output | Confirms the expected number of generated bytes |
| Capture CRC/count | Packer input, before FIFO #1 | Source-to-packer integrity |
| Write CRC/count | Words consumed from FIFO #1 and presented to HyperRAM writer | Detects loss/reordering in FIFO #1 or burst loading |
| Read-ingress CRC/count | HyperRAM read-data-valid beats, before FIFO #2 | Detects HyperRAM read/address/beat corruption |
| Serializer CRC/count | Words read from FIFO #2 | Detects FIFO #2 loss/reordering |
| UART packet CRC/sequence | MATLAB receiver | Detects UART framing, packet, or line-order errors |
| Reconstructed RGB comparison | MATLAB image | Detects pixel byte order, bit shifts, channel mapping, and geometry errors |

Important distinction:
- The existing writer CRC is calculated on words presented by the write engine; it does not independently prove the physical memory cells retained the data.
- The serializer CRC is calculated after output FIFO #2; it cannot by itself distinguish a bad HyperRAM read beat from corruption in FIFO #2.
- Therefore, add a read-ingress CRC before FIFO #2 as a separate checkpoint.

## 8. Final FPGA report to MATLAB

The 46-byte DONE payload now preserves the original 16-byte stream summary and appends:

| Payload byte offsets (1-based) | Field |
|---|---|
| 1–16 | Existing height, line, pixel, UART byte counts and serializer RGB565 CRC |
| 17–20 | Capture CRC32 |
| 21–24 | HyperRAM writer CRC32 |
| 25–28 | HyperRAM read-ingress CRC32 (before output FIFO #2) |
| 29–32 | Generator byte count |
| 33–36 | Capture byte count |
| 37–40 | HyperRAM writer word count |
| 41–44 | HyperRAM read-ingress word count |
| 45–46 | 16-bit status flags |

The final report includes:

- source byte count, line count, source error
- capture byte/word counts and capture CRC
- input FIFO overflow flag and high-water mark
- HyperRAM write word count, write CRC, write error
- read command count and returned beat count
- read-ingress word count and CRC
- output FIFO overflow/error and high-water mark
- serializer raw byte, word, pixel, and UART byte counts
- serializer CRC and line count
- aggregate integrity status and a stage-specific error bitmask

MATLAB should compare:
1. all counts against the expected geometry;
2. capture CRC against its independently calculated pattern CRC;
3. capture CRC against write CRC;
4. read-ingress CRC against write CRC;
5. serializer CRC against read-ingress CRC;
6. every received RGB888 pixel against the independently generated expected image.

The FPGA report is transmitted in DONE after the final LINE packet and after serializer completion. Do not label the local UART line-complete handshake as a MATLAB acknowledgement; the existing link is one-way.

Current limitation: an early fatal capture/write/readout error still uses the existing 2-byte ERROR payload (error code + detail) and does not append the full 46-byte telemetry snapshot. The full stage CRC/count report is guaranteed on the completed readout/DONE path; extending the ERROR path with a partial telemetry snapshot is a follow-up improvement.

## 9. Test order

1. Compile and simulate the pattern generator alone; verify exactly 614,400 valid bytes, 480 lines, and the expected blanking/frame period.
2. Integrate the generator while keeping the existing packer and input FIFO unchanged.
3. Verify capture counts and CRC before enabling HyperRAM writes.
4. Enable the existing write engine and compare capture vs write CRC/counts.
5. Read back the same address range and add the read-ingress CRC before output FIFO #2.
6. Compare read-ingress CRC against write CRC.
7. Compare serializer CRC against read-ingress CRC.
8. Enable UART and compare every pixel in MATLAB; report first mismatch with byte index, word index, line, pixel, expected, and actual values.
9. Only after a repeatable baseline, inject controlled faults (byte swap, bit flip, dropped word, duplicated word, address offset) to prove that each diagnostic flag identifies the correct stage.

## 10. Current implementation status

- [x] Isolated Git branch created from `feature/matlab-line-stream`.
- [x] Deterministic RGB565 source module added.
- [x] Independent MATLAB pattern and CRC reference added.
- [x] Standalone storage-test top-level added; physical camera ports removed.
- [x] Existing input FIFO, burst writer, HyperRAM IP, reader, output FIFO and serializer reused.
- [x] Read-ingress CRC checkpoint added before output FIFO #2.
- [x] DONE payload expanded to 46 bytes with source/capture/write/read CRCs and counts.
- [x] MATLAB receiver parses the report and compares the reconstructed RGB888 frame against the independent pattern.
- [x] Separate Gowin project and camera-free pin constraints added.
- [x] Generator simulation testbench added.
- [ ] Run VHDL simulation and Gowin synthesis/implementation.
- [ ] Hardware validation and fault-injection regression.


## 11. Build and run

First run the standalone generator regression (requires GHDL):
```bash
cd gowin_cameradrive
bash sim/run_generator_tb.sh
```

Then:

1. Open `gowin_cameradrive/HYPERRAM_STORAGE_SELFTEST.gprj` in Gowin EDA.
2. Confirm the selected top module is `HyperRAM_Storage_SelfTest`.
3. Keep the generated HyperRAM IP and PLL files from the camera project; do not regenerate them as part of the baseline test.
4. Program Tang Nano 4K, connect FPGA UART TX to the USB-UART adapter RX, and connect ground.
5. In MATLAB, run `matlab/matlab_gc0308_hyperram_receiver.m`; then press KEY1 on the board.
6. The receiver independently creates the reference pattern. A successful run requires all source/capture/write/read CRCs and expected counts to match, all 480 LINE packets to be received, and every reconstructed RGB888 pixel to match.

The generator currently uses a 24 MHz source clock, 1,280 active byte clocks per captured line, 306 horizontal blank clocks, and 31,720 non-payload frame-blank clocks (8 window rows + 12 VBlank rows). This produces a nominal 30.26 frame/s cadence. These are explicit register-derived test parameters; if measured GC0308 DVP timing differs, adjust the generator generics before claiming exact camera-rate equivalence.

## 12. Status flag bit assignments

| Bit | Meaning when 1 |
|---:|---|
| 0 | Source/capture/input FIFO #1 error |
| 1 | HyperRAM writer error |
| 2 | HyperRAM reader/output FIFO #2 error |
| 3 | RGB565 serializer error |
| 4 | UART protocol error |
| 5 | Capture CRC differs from writer CRC |
| 6 | Writer CRC differs from read-ingress CRC |
| 7 | Capture byte count differs from expected frame size |
| 8 | Writer word count differs from expected frame size |
| 9 | Read-ingress word count differs from expected frame size |
| 10 | Generator byte count differs from capture byte count |
| 13 | Storage-stage checks passed |
| 11, 12, 14, 15 | Reserved; currently zero |
