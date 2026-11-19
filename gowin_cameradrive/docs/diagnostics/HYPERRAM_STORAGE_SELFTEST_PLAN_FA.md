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

## 4. Synthetic source pattern

For pixel coordinate `(x,y)`, generate the 16-bit RGB565 word:

```text
P(x,y) = (251*x + 911*y + 13*x*y + 0xA65C) mod 65536
```

The generator emits each pixel MSB first:

- byte 0: `P[15:8]`
- byte 1: `P[7:0]`

MATLAB must independently calculate the same pattern using sufficiently wide integer arithmetic (for example `uint64`) and then apply the exact RGB565-to-RGB888 expansion used by `rgb565_line_serializer.vhd`.

This pattern varies across both coordinates and both bytes. A byte swap, bit shift, repeated/missing byte, wrong word order, or line displacement should produce a deterministic mismatch.

## 5. Camera-like source cadence

The generator runs from the same 24 MHz clock domain used to clock the camera master clock in the existing top. It emits one valid byte per clock during each active line and inserts explicit horizontal and vertical blanking intervals.

Current defaults are based on the GC0308 register defaults documented for:
- P0:0x01 horizontal blanking = 0x6A (106 pixel clocks)
- P0:0x02 vertical blanking = 0x70 (112 line periods)
- P0:0x28 clock divider = 0x00 (no programmed division)

For 1,280 active byte clocks per line:
- line period = 1,280 + 106 = 1,386 clocks
- vertical blank = 112 * 1,386 = 155,232 clocks
- frame period = 480 * 1,386 + 155,232 = 820,512 clocks
- at 24 MHz, nominal frame rate is approximately 29.25 frames/s

These are datasheet-default-derived values, not a claim that the configured physical sensor has already been measured at exactly this timing. Reference: GC0308 datasheet, register table for P0:0x01, P0:0x02 and P0:0x28: https://min.at/prinz/fp-content/attachs/GC0308.pdf. The configured sensor's actual PCLK and HSYNC/VSYNC timing should be measured and the generator generics adjusted if necessary.

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

The final report should include at least:

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

The FPGA report must be transmitted after the final LINE packet and before or as part of DONE. Do not label the local UART line-complete handshake as a MATLAB acknowledgement; the existing link is one-way.

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
- [ ] Standalone simulation and byte/line timing verification.
- [ ] New storage-test top-level without camera hardware ports.
- [ ] Input FIFO and HyperRAM write path integration.
- [ ] Read-ingress CRC checkpoint before output FIFO #2.
- [ ] Expanded FPGA status report and MATLAB reference comparison.
- [ ] Gowin project file and constraints for the storage-test top-level.
- [ ] Hardware validation and fault-injection regression.
