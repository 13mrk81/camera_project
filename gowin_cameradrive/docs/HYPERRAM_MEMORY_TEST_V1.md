# HyperRAM Memory Test — Version 1

## Purpose

This project separates camera capture validation from HyperRAM data integrity.

- The GC0308 is configured through the existing camera interface.
- The FPGA receives and validates one complete DVP frame (640 x 480 by default).
- Camera bytes are intentionally discarded; they are not connected to the HyperRAM write-data path.
- After a valid frame is observed, the FPGA writes a deterministic test pattern to HyperRAM, reads the same address range, and compares every 32-bit word.

## Test memory layout

The test covers the same 32-bit storage footprint as the RGB565 camera path:

- 640 x 480 pixels
- 2 RGB565 pixels per 32-bit word
- 153,600 words total
- 8 words per burst
- 19,200 bursts
- Base address: 0
- Burst address stride: 16 (preserved from the existing Gowin IP integration)

The test pattern is address-dependent:

`test_word[i] = 0xCAFE0000 XOR i`

Using a different word at each logical index helps detect address increment errors and aliasing; a single repeated constant would not expose all such faults.

## Sequence

1. Wait for PLL stability and HyperRAM `init_calib`.
2. KEY1 starts the GC0308 configuration and one-frame capture.
3. The camera interface checks active-line byte counts and frame height. Its pixel-byte outputs are left unconnected intentionally.
4. After the frame-done event crosses into the HyperRAM user-clock domain, write the complete test pattern starting at address 0.
5. After the final write burst, wait the configured guard interval (default 63 user-clock cycles).
6. Start readback from address 0, using the same burst stride and word order.
7. Compare each returned word against the expected pattern for that logical index.
8. Assert `test_pass_o` only if all words were written/read, no mismatch was found, and the write/read CRC values match.

## Debug signals for GAO/ILA

Probe these internal signals in `Camera_HyperRAM_MemoryTest`:

- `test_state`
- `camera_frame_seen`, `camera_error_sync`
- `init_calib`
- `write_addr`, `read_addr`
- `write_word_index`, `read_word_index`
- `write_word_count`, `read_word_count`
- `write_crc`, `read_crc`
- `mismatch_found`, `first_mismatch_addr`
- `first_expected`, `first_actual`
- `test_error`
- `read_data_valid`, `read_data`
- `mem_cmd`, `mem_cmd_en`, `mem_addr`, `mem_wr_data`

Expected successful end state:

- `test_state = ST_DONE`
- `write_word_count = 153600`
- `read_word_count = 153600`
- `write_crc = read_crc`
- `mismatch_found = 0`
- `test_error = 0`
- `test_pass_o = 1`

On mismatch, inspect the first mismatch address, expected word, and actual word.

## Important limitations

The generated HyperRAM IP exposes no explicit write-ready or write-complete output in the current wrapper. The writer therefore preserves the existing command/data cadence (8 beats, 21 user-clock cycles between burst commands) and waits 63 user-clock cycles after the final write burst before readback. This is a timing guard, not an independently observed physical write-completion acknowledgement. Confirm this cadence and guard against the exact Gowin-generated IP example/documentation before treating a PASS as sign-off.

The read adapter also preserves the existing one-cycle pipeline on `rd_data_valid` and the existing read-command convention. These assumptions must be validated against the IP's generated example.

This source revision has not been compiled, synthesized, timing-closed, or run on the Tang Nano 4K in this environment. Run Gowin synthesis and inspect warnings before programming the board.
