# HyperRAM Data-Path Investigation — Working Log

- Repository: `13mrk81/camera_project`
- Branch: `feature/hyperram-storage-selftest`
- Investigation date: 2026-11-20
- Scope: synthetic Frame Generator path versus real GC0308 capture path into HyperRAM.
- Constraint: **no RTL modifications**. This file is a research checkpoint only.
- Resume rule: continue from the latest section below; re-fetch the branch files before relying on line numbers because line numbers can move after commits.

## 0. Evidence baseline

The following files were fetched from the named branch during this investigation. Blob SHAs are recorded so that later work can detect source changes.

| File | Blob SHA |
|---|---|
| `gowin_cameradrive/src/HyperRAM_Storage_SelfTest.vhd` | `0614ee75dec1f0fe05ad9c540cbd1767f860122e` |
| `gowin_cameradrive/src/storage_test_pattern_generator.vhd` | `89be5e1408714e10b15b45b8d9779798bb004028` |
| `gowin_cameradrive/src/Camera_HyperRAM_OneFrame.vhd` | `711362b17a7dcc6090441e349a2240cb540e4c3a` |
| `gowin_cameradrive/src/camera_interface.vhd` | `a0f01a6af458f1d904166afeb8da109237371bd3` |
| `gowin_cameradrive/src/rgb565_frame_packer.vhd` | `82ed26cc84a93fe3653ad2c7debf22ca55b160ef` |
| `gowin_cameradrive/src/async_fifo_32.vhd` | `2ab8359667e60686ac9b85587dd79ad28f6eb0fa` |
| `gowin_cameradrive/src/frame_integrity_checker.vhd` | `08b556cb643b41413331cf9216588b818e846d89` |
| `gowin_cameradrive/src/hyperram_line_reader.vhd` | `e91459c060c2c2fedd998912505f87850922ff95` |
| `gowin_cameradrive/src/hyperram_line_readout.vhd` | fetched; verify blob SHA on resume |
| `gowin_cameradrive/src/gowin_hyperram_read_adapter.vhd` | `b61f7369df3963f1fb63d53ab1b6a6bd8fd8cb5b` |
| `gowin_cameradrive/src/gowin_pllvr/gowin_pllvr.vhd` | `ee1f9be7634f9d0c3ce9a4f45b542009b3805281` |
| `gowin_cameradrive/src/gowin_pllvr/gowin_pllvr_1.vhd` | `4ad6ceda7d320dfa6b38f66f7b59cde3b7a02d62` |

Project membership verified from:
- `gowin_cameradrive/HYPERRAM_STORAGE_SELFTEST.gprj`: Top-level file is `src/HyperRAM_Storage_SelfTest.vhd`; it includes `storage_test_pattern_generator.vhd`, `rgb565_frame_packer.vhd`, `async_fifo_32.vhd`, readout/telemetry modules and generated HyperRAM IP.
- `gowin_cameradrive/HYPER_RAM_CONTROL.gprj`: Top-level file is `src/Camera_HyperRAM_OneFrame.vhd`; it includes `camera_interface.vhd`, `rgb565_frame_packer.vhd`, `async_fifo_32.vhd`, readout/telemetry modules and generated HyperRAM IP.

These are separate Gowin project configurations. This proves the two modes are not simultaneously instantiated as alternate sources in one active top-level build. It does **not** by itself prove that their post-source storage logic differs.

## 1. Verified architecture so far

### 1.1 Synthetic source

```
8 MHz board clock
  -> Gowin_PLLVR_1 (8 MHz input, generated clk24)
  -> storage_test_pattern_generator (clk24, 8-bit byte + byte_valid)
  -> rgb565_frame_packer (clk24; four bytes -> 32-bit word)
  -> async_fifo_32 capture FIFO (write clk24, read usr_clk; default depth 2^11 = 2048 x 32-bit)
  -> usr_clk-domain burst writer (8 x 32-bit local burst buffer)
  -> HyperRAM_Memory_Interface_Top (32-bit wr_data, 22-bit addr, cmd/cmd_en)
```

Key evidence:
- `HyperRAM_Storage_SelfTest.vhd` lines 402–417: 8 MHz reference -> clk24 -> clk96 PLL chain.
- Same file lines 621–650 (recheck exact range on resume): generator is instantiated on clk24; byte stream is connected to the same RGB565 packer.
- Same file lines 652–674: capture FIFO is `async_fifo_32`, write clock clk24, read clock usr_clk, width 32; `G_FIFO_ADDR_BITS` default 11.
- Same file lines 735 onward: writer consumes FIFO in 8-word groups and stores them in `burst_buffer`.
- `storage_test_pattern_generator.vhd` lines 48–59: pixel function:
  `value = (x*251) + (y*911) + (x*y*13) + 16#A65C#`, output is value modulo 65536.
- Generator lines 100–115: one byte is emitted per clk24 cycle in active line; high byte first, then low byte; no ready/full input exists.

### 1.2 GC0308 source

```
8 MHz board clock
  -> Gowin_PLLVR_1 (8 MHz input, generated clk24)
  -> cam_clk output to sensor (clk24)
  -> GC0308 DVP: cam_pclk + cam_vsync + cam_hsync + cam_pix_data[7:0]
  -> camera_interface DVP FSM (cam_pclk domain; byte_valid)
  -> rgb565_frame_packer (cam_pclk; four bytes -> 32-bit word)
  -> async_fifo_32 capture FIFO (write cam_pclk, read usr_clk; default depth 2^11 = 2048 x 32-bit)
  -> usr_clk-domain burst writer (8 x 32-bit local burst buffer)
  -> HyperRAM_Memory_Interface_Top
```

Key evidence:
- `Camera_HyperRAM_OneFrame.vhd` lines 456–471: same nominal 8 MHz -> clk24 -> clk96 PLL arrangement.
- Same file lines 600–680: `camera_interface` instance connects external DVP signals to `cam_byte_data`, `cam_byte_valid`, `cam_frame_done`, `cam_frame_error`.
- Same file lines 700–725: the same `rgb565_frame_packer` entity receives camera bytes on cam_pclk.
- Same file lines 727–758: the same `async_fifo_32` entity; write clock cam_pclk, read clock usr_clk, same `G_FIFO_ADDR_BITS` generic (default 11).
- `camera_interface.vhd` lines 624–795: DVP FSM is clocked on rising cam_pclk. It waits for configuration pass, observes VSYNC inactive then rising edge to start frame, accepts bytes while VSYNC=1 and HREF/HSYNC=1, and limits each line to exactly G_FRAME_WIDTH*2 bytes. HREF falling validates the line byte count; VSYNC falling validates frame line count. Overrun/underrun of expected line geometry sets capture_error and terminates capture.
- The code labels VSYNC and HSYNC as active-high for the selected configuration. In this RTL, HSYNC is effectively the active-line qualifier (commonly called HREF in GC0308 DVP terminology); the top-level signal is named cam_hsync.

## 2. Shared storage-path findings

The two top-level files instantiate the same:
- `rgb565_frame_packer` entity, same generic geometry, same byte order and CRC implementation.
- `async_fifo_32` entity, same width and same default generic depth (G_FIFO_ADDR_BITS=11 => 2048 words, 8192 bytes).
- 8-word burst buffer organization and same named writer FSM states.
- HyperRAM user bus shape: 32-bit write data, 22-bit address, cmd/cmd_en, 4-bit data mask.
- `C_BURST_WORDS=8`, `C_ADDR_STEP=16`, default `G_CMD_INTERVAL_CYCLES=21`, `G_WRITE_READ_GAP_CYCLES=63`.

The writer FSM source appears structurally duplicated in the two top-level files. The input clock differs only at the FIFO write side (clk24 synthetic versus cam_pclk camera). Both writers operate on usr_clk. Confirm exact normalized textual equivalence by extracting/comparing the entire writer process on resume.

### Important full-FIFO behavior / data-loss risk

`async_fifo_32.vhd`:
- Lines 90–93: a write is committed only if wr_en_i=1 and full_reg=0. When full, the write is simply not accepted.
- Lines 123–128: read is accepted only if rd_en_i=1 and empty_int=0; rd_valid pulses for accepted read.
- No almost-full output exists.
- The source and packer have no ready/backpressure input.

Both top-levels monitor `cap_packed_valid && cap_fifo_full` and set sticky `cap_fifo_overflow_cam` (camera version clocked by cam_pclk; synthetic version clocked by clk24). This makes overflow visible but does not prevent it or retry the rejected word. Therefore loss is possible if the FIFO fills; the design reports an error rather than applying backpressure.

## 3. Synthetic pattern and first-order rate model

Default geometry: 640 x 480 RGB565.
- 2 bytes/pixel; 4 bytes/32-bit FIFO word; 2 pixels/word.
- Active bytes/line = 1280; synthetic line blank = 306 clk24 cycles.
- Synthetic frame blank = 31,720 clk24 cycles.
- Total frame cycles = 480*(1280+306) + 31,720 = 793,000 cycles.
- At 24 MHz, nominal frame period = 33.0417 ms, frame rate ~= 30.265 fps.
- Active byte production = 24 Mbyte/s during active-line windows.
- Active pixel production = 12 Mpixel/s during active-line windows.
- Average payload production over full frame incl. programmed blanking = 614,400 bytes * 24 MHz / 793,000 ~= 18.59 Mbyte/s = 4.647 M 32-bit words/s.
- The generator emits one 8-bit byte per active clk24 cycle; the packer emits one 32-bit word for every four valid byte pulses (one word every four active byte cycles).

For the camera path, the actual cam_pclk frequency and active/blanking cycle counts must not be guessed from the system clock. The DVP byte-valid rate is one byte per rising cam_pclk edge while the FSM accepts bytes. For 640x480 RGB565, the packer emits one word per four accepted bytes. Derive measured average camera word rate from actual cam_pclk and HREF duty cycle, or from a logic analyzer/ILA capture. Register-table blanking comments are not a substitute for measured PCLK timing.

## 4. Buffer and service-rate arithmetic (RTL schedule, not yet verified against silicon IP)

- Capture FIFO depth: 2048 x 32 bits = 65,536 bits = 8,192 bytes = 4,096 RGB565 pixels.
- At synthetic average input 4.647 Mword/s, a completely stopped consumer would fill it in about 440.5 us (2048/4.647e6).
- At synthetic active input 6 Mword/s, it would fill in about 341.3 us.
- Writer user clock is described as 48 MHz in top-level comments and is produced by the HyperRAM IP `clk_out`. Both tops map `clk_out => usr_clk`; actual generated IP configuration/clock must still be verified from available Gowin IP artifacts.
- With default command interval 21 and 8 words per burst, the controller's scheduled upper-bound payload rate is 48 MHz * 8/21 = 18.286 Mword/s = 73.14 MB/s, assuming each scheduled data beat is accepted by the IP as intended. This is **not yet a measured or IP-guaranteed sustained rate**.
- The source can therefore be serviced in average-rate terms under this schedule, but this does not prove no overflow during calibration/startup, pauses, read/write arbitration, or IP stalls. There is no write-side ready/acceptance handshake from the IP in this RTL.

## 5. HyperRAM write protocol and outstanding unknowns

Observed in both top-levels:
- 8 x 32-bit burst staging buffer.
- W_WRITE_CMD cycle drives cmd=1, cmd_en=1, address=write_addr, wr_data=burst_buffer(0).
- W_WRITE_DATA cycles drive cmd=0, cmd_en=0, and remaining burst words.
- Address advances by 16 after the final beat of each burst (except final frame burst).
- Data mask is all zero.
- Writer waits for init_calib before writing.
- The top-level maps clk=clk24, memory_clk=clk96, clk_out=usr_clk, wr_data 32-bit, addr 22-bit.
- There is no explicit write-ready/accepted signal in the declared IP interface.

Do not infer physical address units, exact HyperRAM latency, actual configured burst length, or guaranteed write throughput from comments alone. The generated `hyperram_memory_interface.vhd` is a large generated artifact; inspect its readable header/configuration or the Gowin project IP settings/example files to establish what can be established. If it is encrypted/opaque, state that limitation. The source comment itself says address unit and command/data timing require IP example/documentation confirmation.

## 6. Readout / integrity instrumentation observed

- `rgb565_frame_packer`: capture CRC-32 (poly 04C11DB7, MSB-first, init FFFFFFFF, no final XOR), byte count, word count; calculated on each accepted source byte before FIFO.
- Writer: write CRC over each 32-bit word loaded into burst buffer and scheduled for write; write word count.
- `hyperram_line_reader`: read-ingress CRC and word count on each valid HyperRAM read response; checks FIFO full and errors if full. The read response stream is not backpressured.
- `rgb565_line_serializer`: readback CRC/counts and UART counters; inspect this file on resume for exact CRC measurement point.
- `frame_integrity_checker`: checks equality of capture/write/read-ingress/readback CRCs and expected counts.
- FIFO: full/empty/levels; no almost-full.
- Overflow sticky flag exists at capture FIFO boundary; no counter for number of dropped words.
- Internal status signals are not all exported as top-level debug ports; UART DONE packet exports selected telemetry.

## 7. Preliminary conclusion (not final)

**Strongly supported:** after the source byte stream, both designs use the same packer, same 32-bit asynchronous capture FIFO module with same default depth, same usr_clk burst writer structure, and same HyperRAM IP interface shape. Thus the post-source storage path is intended to be shared in architecture and is nearly line-for-line duplicated in two independent top-levels.

**Not yet established:** exact writer-process source identity, actual HyperRAM generated IP burst configuration and accepted write timing, real camera PCLK/active duty/rate, and empirical no-loss behavior. The two source domains differ (clk24 synthetic vs cam_pclk camera), and neither source has backpressure from FIFO full.

## 8. Resume checklist / next work

1. Re-fetch all listed files from `feature/hyperram-storage-selftest`; compare blob SHAs with Section 0.
2. Extract and compare full writer FSM and HyperRAM mux/IP instantiation in both tops. Record exact matching/differing lines.
3. Inspect `camera_interface.vhd` init table for timing-related register writes and distinguish configured values from measured PCLK/HREF.
4. Inspect `rgb565_line_serializer.vhd`, `frame_integrity_checker.vhd`, `stable_bus_event_cdc.vhd`, and both top-level telemetry packing/status flag sections.
5. Inspect generated HyperRAM IP project/configuration artifacts, memory-device selection, burst length, memory_clk and usr_clk settings. Do not guess if opaque.
6. Compute worst-case FIFO fill time for camera using a measured PCLK and HREF duty cycle; compute write-engine effective scheduled rate and compare.
7. Build the final report with diagrams, module-by-module tables, equations, data-loss points, evidence citations/line ranges, and test plan.
8. Do not edit RTL. Only update this log and the research report documentation.

---
This is a working evidence log, not the final report. A statement marked “not established” must remain unresolved until additional source/configuration evidence or measurement is obtained.
