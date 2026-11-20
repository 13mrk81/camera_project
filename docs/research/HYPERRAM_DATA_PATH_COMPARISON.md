# HyperRAM Data-Path Comparison: Synthetic Generator vs GC0308

**Repository:** `13mrk81/camera_project`  
**Branch:** `feature/hyperram-storage-selftest`  
**Investigation date:** 2026-11-20  
**Scope:** Source-to-HyperRAM ingress, capture buffering, write scheduling, rate model, telemetry and data-loss risks.  
**RTL changes:** None. This report and its companion log are documentation-only.

> Evidence convention: statements below are classified as **RTL-proven**, **configuration/comment-derived**, or **not established**. The branch's generated HyperRAM IP HDL is protected/encrypted, so physical command timing and internal burst configuration are not inferred from controller comments.

## 1. Executive conclusion

**The two designs use the same post-source storage architecture and the same writer RTL algorithm, but they are not the same active build or the same clock-domain implementation.**

Evidence:

1. The synthetic and camera modes are separate Gowin projects:
   - `HYPERRAM_STORAGE_SELFTEST.gprj` selects `HyperRAM_Storage_SelfTest`.
   - `HYPER_RAM_CONTROL.gprj` selects `Camera_HyperRAM_OneFrame`.
2. The synthetic source and camera receiver both feed the same `rgb565_frame_packer` entity.
3. Both packers feed `async_fifo_32` with `G_ADDR_BITS=11`, width 32, and the same read/write interface.
4. Both feed the same 8-word burst buffer/writer state machine. Extracting the complete writer section from both top-levels and normalizing only the reset signal name yielded identical 5,919-character RTL sections.
5. Both drive the same declared HyperRAM IP interface shape (32-bit write data, 22-bit address, command and command-enable, 4-bit mask), with the same write mux and address progression.

**Differences before/at the first FIFO:**
- Synthetic source and packer run on `clk24`.
- Camera DVP capture and packer run on external `cam_pclk`.
- Camera path has I2C configuration, VSYNC/HSYNC qualification and per-line byte-count checks; synthetic path has a deterministic pattern generator and programmed blanking.
- Neither source has a ready/backpressure path from the FIFO. If the FIFO is full, the FIFO rejects the word and a sticky overflow error is raised; the source is not stalled and the lost word is not replayed.

**Therefore:** the intended storage datapath is common from the packer's 32-bit output onward. This is a source-level RTL conclusion, not proof that the physical HyperRAM IP accepts every beat correctly or that the camera never overflows under measured timing.

## 2. Project selection and source files

| Mode | Gowin project | Top-level entity | Source clock |
|---|---|---|---|
| Synthetic | [HYPERRAM_STORAGE_SELFTEST.gprj](https://github.com/13mrk81/camera_project/blob/feature/hyperram-storage-selftest/gowin_cameradrive/HYPERRAM_STORAGE_SELFTEST.gprj) | `HyperRAM_Storage_SelfTest` | `clk24` |
| GC0308 | [HYPER_RAM_CONTROL.gprj](https://github.com/13mrk81/camera_project/blob/feature/hyperram-storage-selftest/gowin_cameradrive/HYPER_RAM_CONTROL.gprj) | `Camera_HyperRAM_OneFrame` | `cam_pclk` |

Core source files:

| File / entity | Function | Evidence |
|---|---|---|
| `HyperRAM_Storage_SelfTest.vhd` / `HyperRAM_Storage_SelfTest` | Synthetic top, source/packer/FIFO/writer/readout/telemetry integration | [L605-L673](https://github.com/13mrk81/camera_project/blob/feature/hyperram-storage-selftest/gowin_cameradrive/src/HyperRAM_Storage_SelfTest.vhd#L605-L673) |
| `storage_test_pattern_generator.vhd` / `storage_test_pattern_generator` | Deterministic byte stream | [L17-L37, L61-L69, L106-L145](https://github.com/13mrk81/camera_project/blob/feature/hyperram-storage-selftest/gowin_cameradrive/src/storage_test_pattern_generator.vhd#L17-L69) |
| `Camera_HyperRAM_OneFrame.vhd` / `Camera_HyperRAM_OneFrame` | GC0308 top and storage integration | [L680-L780](https://github.com/13mrk81/camera_project/blob/feature/hyperram-storage-selftest/gowin_cameradrive/src/Camera_HyperRAM_OneFrame.vhd#L680-L780) |
| `camera_interface.vhd` / `camera_interface` | Sensor I2C configuration and DVP capture FSM | [entity ports L18-L55](https://github.com/13mrk81/camera_project/blob/feature/hyperram-storage-selftest/gowin_cameradrive/src/camera_interface.vhd#L18-L55), [DVP FSM L624-L795](https://github.com/13mrk81/camera_project/blob/feature/hyperram-storage-selftest/gowin_cameradrive/src/camera_interface.vhd#L624-L795) |
| `rgb565_frame_packer.vhd` / `rgb565_frame_packer` | Four input bytes to one 32-bit word; capture CRC/counters | [L11-L35, L75-L157](https://github.com/13mrk81/camera_project/blob/feature/hyperram-storage-selftest/gowin_cameradrive/src/rgb565_frame_packer.vhd#L11-L35) |
| `async_fifo_32.vhd` / `async_fifo_32` | Dual-clock 32-bit FIFO | [L8-L33, L74-L139](https://github.com/13mrk81/camera_project/blob/feature/hyperram-storage-selftest/gowin_cameradrive/src/async_fifo_32.vhd#L8-L33) |
| `hyperram_line_readout.vhd` / `hyperram_line_readout` | Read-side line FIFO + line reader + serializer integration | [L8-L83, L91-L210](https://github.com/13mrk81/camera_project/blob/feature/hyperram-storage-selftest/gowin_cameradrive/src/hyperram_line_readout.vhd#L8-L83) |
| `hyperram_line_reader.vhd` / `hyperram_line_reader` | HyperRAM read commands/responses, read-ingress CRC | [L13-L57, L135-L240](https://github.com/13mrk81/camera_project/blob/feature/hyperram-storage-selftest/gowin_cameradrive/src/hyperram_line_reader.vhd#L13-L57) |
| `gowin_hyperram_read_adapter.vhd` / `gowin_hyperram_read_adapter` | Adapts read valid/ready command to Gowin IP cmd_en | [L16-L38, L44-L76](https://github.com/13mrk81/camera_project/blob/feature/hyperram-storage-selftest/gowin_cameradrive/src/gowin_hyperram_read_adapter.vhd#L16-L38) |
| `rgb565_line_serializer.vhd` / `rgb565_line_serializer` | FIFO #2 to RGB888/UART and readback CRC | [L8-L45, L140-L172, L174-L243](https://github.com/13mrk81/camera_project/blob/feature/hyperram-storage-selftest/gowin_cameradrive/src/rgb565_line_serializer.vhd#L8-L45) |
| `frame_integrity_checker.vhd` / `frame_integrity_checker` | Final CRC/count/error consistency | [L8-L35, L45-L88](https://github.com/13mrk81/camera_project/blob/feature/hyperram-storage-selftest/gowin_cameradrive/src/frame_integrity_checker.vhd#L8-L35) |
| `stable_bus_event_cdc.vhd` / `stable_bus_event_cdc` | Bundled snapshot/event CDC | [L5-L27, L41-L78](https://github.com/13mrk81/camera_project/blob/feature/hyperram-storage-selftest/gowin_cameradrive/src/stable_bus_event_cdc.vhd#L5-L27) |
| `hyperram_memory_interface.vhd` / generated Gowin IP | HyperRAM PHY/controller boundary | Protected/encrypted HDL; see Section 7 |

## 3. Block diagrams

### 3.1 Synthetic data path

```text
8 MHz board oscillator
        |
        v
Gowin_PLLVR_1 -> clk24 -----------------------------+
        |                                             |
        v                                             v
storage_test_pattern_generator                 protocol start pulse
  - clk_i = clk24
  - RGB565 pattern (x,y)
  - 8-bit byte_data + byte_valid
        |
        v
rgb565_frame_packer (cam_pclk port tied to clk24)
  - accepts byte_valid
  - four bytes -> one 32-bit word
  - capture CRC / byte count / word count
        |
        v
async_fifo_32 (capture FIFO #1)
  - wr_clk = clk24
  - rd_clk = usr_clk
  - 2048 x 32-bit (default)
        |
        v
usr_clk writer
  - waits init_calib
  - fetches 8 words into burst_buffer
  - W_WRITE_CMD + W_WRITE_DATA
        |
        v
HyperRAM_Memory_Interface_Top
  - wr_data[31:0], addr[21:0], cmd, cmd_en
  - data_mask[3:0]
        |
        v
HyperRAM
```

### 3.2 GC0308 data path

```text
8 MHz board oscillator
        |
        v
Gowin_PLLVR_1 -> clk24 -> cam_clk output to GC0308
        |
        |       GC0308 DVP output
        |       cam_pclk, cam_vsync, cam_hsync, cam_pix_data[7:0]
        |                    |
        +--------------------+
                             v
                   camera_interface DVP FSM
                     - samples rising cam_pclk
                     - VSYNC frame qualification
                     - HSYNC active-line qualification
                     - exactly 1280 bytes/line
                             |
                             v
                   rgb565_frame_packer
                     - clock = cam_pclk
                     - four bytes -> one 32-bit word
                     - capture CRC / byte count / word count
                             |
                             v
                   async_fifo_32 (capture FIFO #1)
                     - wr_clk = cam_pclk
                     - rd_clk = usr_clk
                     - 2048 x 32-bit (default)
                             |
                             v
                   SAME usr_clk writer RTL
                     - 8-word burst_buffer
                     - W_WRITE_CMD + W_WRITE_DATA
                             |
                             v
                   SAME HyperRAM IP interface shape
                             |
                             v
                           HyperRAM
```

## 4. Source and packer details

### 4.1 Synthetic pattern

The generator computes a 16-bit value for pixel coordinate `(x,y)`:

```vhdl
value := (x * 251) + (y * 911) + (x * y * 13) + 16#A65C#;
return std_logic_vector(to_unsigned(value mod 65536, 16));
```

Source: [storage_test_pattern_generator.vhd L61-L69](https://github.com/13mrk81/camera_project/blob/feature/hyperram-storage-selftest/gowin_cameradrive/src/storage_test_pattern_generator.vhd#L61-L69).

For every pixel:
- byte index even: emit `pixel(15 downto 8)` (MSB);
- byte index odd: emit `pixel(7 downto 0)` (LSB).
- one 8-bit byte is valid on each active `clk24` cycle.
- `byte_valid_o` is deasserted by default each cycle and asserted throughout `ST_ACTIVE_LINE`; there is no `ready_i`, `full_i`, or pause input.
- The generator runs one frame after `start_i`, then remains in `ST_DONE`.

Relevant code: [L106-L145](https://github.com/13mrk81/camera_project/blob/feature/hyperram-storage-selftest/gowin_cameradrive/src/storage_test_pattern_generator.vhd#L106-L145).

### 4.2 GC0308 input qualification

DVP ports are 8-bit data plus PCLK, VSYNC and HSYNC: [camera_interface.vhd L28-L50](https://github.com/13mrk81/camera_project/blob/feature/hyperram-storage-selftest/gowin_cameradrive/src/camera_interface.vhd#L28-L50).

RTL behavior:
- DVP FSM is clocked on `rising_edge(cam_pclk)`.
- Waits for synchronized `config_done` and `config_pass`.
- Waits for VSYNC low, then detects VSYNC low-to-high to begin a frame.
- During `CAP_CAPTURE`, VSYNC must remain high.
- HSYNC high is the active-byte qualifier (the port is called `cam_hsync`; functionally this is the active-line gate often called HREF in DVP descriptions).
- Each rising PCLK with HSYNC high and `line_byte_count < 2*G_FRAME_WIDTH` asserts byte-valid and samples `cam_pix_data`.
- On HSYNC falling, exactly `2*G_FRAME_WIDTH` bytes are required.
- On VSYNC falling, exactly `G_FRAME_HEIGHT` lines are required.
- Extra bytes, short lines, early VSYNC, or wrong line count set capture error and move to `CAP_ERROR`.

Source: [camera_interface.vhd L624-L795](https://github.com/13mrk81/camera_project/blob/feature/hyperram-storage-selftest/gowin_cameradrive/src/camera_interface.vhd#L624-L795).

**Naming caution:** top-level uses `cam_hsync`; do not assume its polarity or function from its name. The FSM comment says VSYNC and HSYNC are active-high in the selected GC0308 configuration.

### 4.3 Shared packer

Both top-levels instantiate the same `rgb565_frame_packer` with the same frame geometry. Synthetic maps its clock to `clk24`; camera maps it to `cam_pclk`.

The packer:
- counts/CRCs each accepted input byte (`cam_byte_valid_i=1`);
- accumulates four bytes in order;
- asserts `packed_valid_o` for one cycle on the fourth byte;
- emits `byte0 & byte1 & byte2 & current_byte` as one 32-bit word;
- therefore one 32-bit word represents two RGB565 pixels;
- flags incomplete/extra data at frame completion.

Sources: [packer entity/ports L11-L35](https://github.com/13mrk81/camera_project/blob/feature/hyperram-storage-selftest/gowin_cameradrive/src/rgb565_frame_packer.vhd#L11-L35), [packing FSM L93-L145](https://github.com/13mrk81/camera_project/blob/feature/hyperram-storage-selftest/gowin_cameradrive/src/rgb565_frame_packer.vhd#L93-L145).

## 5. FIFO and flow-control comparison

### 5.1 Capture FIFO #1

| Property | Synthetic | GC0308 | Result |
|---|---|---|---|
| Entity | `async_fifo_32` | `async_fifo_32` | Same |
| Width | 32 bits | 32 bits | Same |
| `G_ADDR_BITS` | 11 | 11 | Same |
| Depth | 2^11 = 2048 words | 2^11 = 2048 words | Same |
| Write clock | `clk24` | `cam_pclk` | Different |
| Read clock | `usr_clk` | `usr_clk` | Same net/role |
| Write enable | `cap_packed_valid` | `cap_packed_valid` | Same |
| Write data | `cap_packed_word` | `cap_packed_word` | Same |
| Read enable | `write_fifo_rd_en` | `write_fifo_rd_en` | Same writer logic |
| Full/empty | full, empty | full, empty | Same |
| Level | write/read level | write/read level | Same |
| Almost-full | not implemented | not implemented | Same |
| Backpressure | none to source | none to source | Same |

Evidence:
- Synthetic mapping: [HyperRAM_Storage_SelfTest.vhd L634-L673](https://github.com/13mrk81/camera_project/blob/feature/hyperram-storage-selftest/gowin_cameradrive/src/HyperRAM_Storage_SelfTest.vhd#L634-L673).
- Camera mapping: [Camera_HyperRAM_OneFrame.vhd L704-L743](https://github.com/13mrk81/camera_project/blob/feature/hyperram-storage-selftest/gowin_cameradrive/src/Camera_HyperRAM_OneFrame.vhd#L704-L743).
- Both top-level generic defaults: `G_FIFO_ADDR_BITS=11` (top-level declarations).
- FIFO depth and full/empty logic: [async_fifo_32.vhd L8-L33, L74-L139](https://github.com/13mrk81/camera_project/blob/feature/hyperram-storage-selftest/gowin_cameradrive/src/async_fifo_32.vhd#L8-L33).

### 5.2 What happens when full?

FIFO write logic is:

```vhdl
if (wr_en_i = '1') and (full_reg = '0') then
    mem(...) <= wr_data_i;
    next_bin := wr_bin + 1;
end if;
```

[async_fifo_32.vhd L85-L105](https://github.com/13mrk81/camera_project/blob/feature/hyperram-storage-selftest/gowin_cameradrive/src/async_fifo_32.vhd#L85-L105).

When `wr_en_i=1` and `full_reg=1`, no memory write and no write-pointer advance occur. The FIFO does not stall the producer. Both tops separately latch overflow when `cap_packed_valid=1` and `cap_fifo_full=1`:
- Synthetic: [HyperRAM_Storage_SelfTest.vhd L675-L690](https://github.com/13mrk81/camera_project/blob/feature/hyperram-storage-selftest/gowin_cameradrive/src/HyperRAM_Storage_SelfTest.vhd#L675-L690).
- Camera: [Camera_HyperRAM_OneFrame.vhd L745-L758](https://github.com/13mrk81/camera_project/blob/feature/hyperram-storage-selftest/gowin_cameradrive/src/Camera_HyperRAM_OneFrame.vhd#L745-L758).

This is **loss detection, not loss prevention**. The rejected 32-bit word is not retried. The sticky error is synchronized to `usr_clk`; writer exits to `W_ERROR` when capture error is observed.

### 5.3 FIFO read behavior

The FIFO accepts a read only when `rd_en_i=1` and `empty_int=0`; it returns registered data with `rd_valid_o` asserted for the accepted read: [async_fifo_32.vhd L110-L139](https://github.com/13mrk81/camera_project/blob/feature/hyperram-storage-selftest/gowin_cameradrive/src/async_fifo_32.vhd#L110-L139).

Writer asserts read-enable only in `W_LOAD_FIRST` or `W_LOAD_NEXT`, while fewer than eight read requests have been issued and FIFO is not empty: [HyperRAM_Storage_SelfTest.vhd L739-L742](https://github.com/13mrk81/camera_project/blob/feature/hyperram-storage-selftest/gowin_cameradrive/src/HyperRAM_Storage_SelfTest.vhd#L739-L742). It stores eight returned words in `burst_buffer` before writing.

## 6. Writer and HyperRAM interface

### 6.1 Writer identity

The writer RTL section in both top-level files was extracted and compared. After normalizing only the reset signal name (`usr_rst_n` vs `ip_rst_n`), the two sections are byte-for-byte identical (5,919 characters).

Writer behavior:
1. `W_WAIT_INIT`: wait for `init_calib_i=1`.
2. `W_WAIT_BURST`: wait until at least 8 FIFO words are available.
3. `W_LOAD_FIRST`: read eight words into the burst buffer.
4. `W_WRITE_CMD`: present first word and write command.
5. `W_WRITE_DATA`: present the remaining seven words.
6. `W_LOAD_NEXT`: load next eight words while waiting out the programmed gap.
7. `W_WAIT_CAPTURE_END`: wait for source snapshot, expected byte/word counts, and empty FIFO.
8. `W_DONE` or `W_ERROR`.

Source: [synthetic writer L736-L865](https://github.com/13mrk81/camera_project/blob/feature/hyperram-storage-selftest/gowin_cameradrive/src/HyperRAM_Storage_SelfTest.vhd#L736-L865); camera writer begins at [Camera_HyperRAM_OneFrame.vhd L804](https://github.com/13mrk81/camera_project/blob/feature/hyperram-storage-selftest/gowin_cameradrive/src/Camera_HyperRAM_OneFrame.vhd#L804).

### 6.2 Command/data mux

```vhdl
if write_state = W_WRITE_CMD then
    mem_cmd_i     <= '1';
    mem_cmd_en_i  <= '1';
    mem_addr_i    <= std_logic_vector(write_addr);
    mem_wr_data_i <= burst_buffer(0);
elsif write_state = W_WRITE_DATA then
    mem_cmd_i     <= '0';
    mem_cmd_en_i  <= '0';
    mem_wr_data_i <= burst_buffer(write_beat_index);
end if;
```

[HyperRAM_Storage_SelfTest.vhd L967-L988](https://github.com/13mrk81/camera_project/blob/feature/hyperram-storage-selftest/gowin_cameradrive/src/HyperRAM_Storage_SelfTest.vhd#L967-L988).

The same mux is present in the camera top. The mux defaults to the read adapter signals, so write states take priority over read commands. Address advances by `C_ADDR_STEP=16` after the final word of each 8-word burst except the final burst: see the address process near the end of both top-level files.

### 6.3 IP interface

Both top-levels map:
- `clk => clk24`
- `memory_clk => clk96`
- `clk_out => usr_clk`
- `wr_data => mem_wr_data_i` (32 bits)
- `addr => mem_addr_i` (22 bits)
- `cmd`, `cmd_en`
- `data_mask => 4'b0000`
- `init_calib` back to writer.

Synthetic mapping: [HyperRAM_Storage_SelfTest.vhd L990-L1010](https://github.com/13mrk81/camera_project/blob/feature/hyperram-storage-selftest/gowin_cameradrive/src/HyperRAM_Storage_SelfTest.vhd#L990-L1010). Camera mapping: [Camera_HyperRAM_OneFrame.vhd L1056-L1076](https://github.com/13mrk81/camera_project/blob/feature/hyperram-storage-selftest/gowin_cameradrive/src/Camera_HyperRAM_OneFrame.vhd#L1056-L1076).

### 6.4 Important IP limitation

The generated `hyperram_memory_interface.vhd` contains Gowin protected/encrypted payload. The visible header identifies source files `HPRAM_TOP.v` and `hpram_code_1N2A.v`, but the implementation is not readable. The top-level comments explicitly warn that address units and command/data timing must be confirmed from the generated IP example/documentation.

Consequently:
- RTL proves that the custom writer emits groups of eight 32-bit words and uses address stride 16.
- RTL does **not** prove the physical address unit, the actual IP-configured burst length, exact command acceptance semantics, or that every write beat is accepted without a ready signal.
- No write-side `ready`/accepted response is wired into the writer. This is a major verification gap.

## 7. Clock domains and rate/capacity calculations

### 7.1 Clock tree evidence

- Both tops use an 8 MHz board reference and instantiate PLLs for `clk24` and `clk96`.
- `Gowin_PLLVR_1` generated wrapper has `FCLKIN="8"`, `FBDIV_SEL=2`, `ODIV_SEL=32`.
- `Gowin_PLLVR` wrapper has `FCLKIN="24"`, `FBDIV_SEL=3`, `ODIV_SEL=8`.
- Both tops connect the IP `clk_out` to `usr_clk`; comments call it 48 MHz (= 96 MHz memory clock / 2).
- The SDC constrains only external `clk8` at 125 ns; it does not constrain/declare generated clocks in this file: [hyper_ctrl.sdc](https://github.com/13mrk81/camera_project/blob/feature/hyperram-storage-selftest/gowin_cameradrive/src/hyper_ctrl.sdc).

The 48 MHz user clock is therefore **the top-level's stated/expected IP output**, not independently verified from readable IP implementation or a timing report in this source review.

### 7.2 Frame sizes

For default 640x480 RGB565:
- Pixels/frame = 640*480 = 307,200.
- Bytes/pixel = 2.
- Raw bytes/frame = 614,400.
- 32-bit words/frame = 153,600.
- Words/line = 640/2 = 320.
- 8-word bursts/line = 40.
- 8-word bursts/frame = 19,200.

### 7.3 Synthetic source rates

Default synthetic timing:
- Active bytes/line = 640*2 = 1,280.
- Line blank = 306 `clk24` cycles.
- Frame blank = 31,720 `clk24` cycles.
- Total frame cycles = 480*(1,280+306)+31,720 = 793,000.
- At 24 MHz: frame rate = 24,000,000/793,000 = **30.2648 fps**.
- Average source bytes/s = 614,400*30.2648 = **18.5947 MB/s**.
- Average FIFO words/s = 153,600*30.2648 = **4.64868 Mword/s**.
- During active line bytes, one byte/cycle at 24 MHz = **24 MB/s**; packer emits one word per four valid bytes = **6 Mword/s** during active windows.

The synthetic generator's programmed timing is explicit in [storage_test_pattern_generator.vhd L17-L23](https://github.com/13mrk81/camera_project/blob/feature/hyperram-storage-selftest/gowin_cameradrive/src/storage_test_pattern_generator.vhd#L17-L23) and its top-level generic map at [HyperRAM_Storage_SelfTest.vhd L605-L623](https://github.com/13mrk81/camera_project/blob/feature/hyperram-storage-selftest/gowin_cameradrive/src/HyperRAM_Storage_SelfTest.vhd#L605-L623).

### 7.4 Camera source rate

The camera source clock is external `cam_pclk`. The top-level drives the sensor's `cam_clk` from `clk24`, but does not use `clk24` as the packer clock; the packer is clocked by `cam_pclk`.

The camera RTL does not count PCLK frequency or measure HREF duty cycle. Thus an unconditional numeric camera rate cannot be proven from RTL. Let:
- `f_pclk` = measured camera PCLK frequency,
- `D_href` = fraction of PCLK cycles for which the DVP FSM accepts bytes (VSYNC high, HSYNC high, within line count).

Then approximate average input:
- byte rate = `f_pclk * D_href`
- FIFO word rate = `f_pclk * D_href / 4`

If PCLK were 24 MHz and camera active/blanking duty exactly matched the synthetic generator, average word rate would also be about 4.648 Mword/s. This is a conditional comparison, not a measured fact.

### 7.5 FIFO capacity and service pause

Capture FIFO:
- 2,048 words * 4 bytes = **8,192 bytes**.
- Equivalent RGB565 pixels = 4,096.
- Full-frame data = 153,600 words, so FIFO stores only 1.333% of a frame.

Maximum complete service interruption from empty FIFO:
- At synthetic average rate: 2,048 / 4.64868e6 = **440.6 us**.
- At synthetic active rate: 2,048 / 6e6 = **341.3 us**.
- For camera: `T_pause = (2048 - current_occupancy_words) / (f_pclk * D_href / 4)`.

These are ideal occupancy bounds, not guarantees. If the writer has already accumulated Q words, only 2048-Q entries remain. FIFO pointer synchronization also means the observed level/full flags have CDC latency.

### 7.6 Writer scheduled rate

Defaults:
- `C_BURST_WORDS=8`
- `G_CMD_INTERVAL_CYCLES=21`
- `C_MIN_GAP_CYCLES=21-8=13`
- `usr_clk` is stated as 48 MHz in top comments.

The steady-state writer schedule is 8 words per 21 user-clock cycles (8 write cycles plus a 13-cycle load/gap interval). If usr_clk is 48 MHz:
- scheduled words/s = 48e6*8/21 = **18.286 Mword/s**.
- scheduled byte payload = **73.14 MB/s**.

This is the controller's scheduled bus rate, **not proven HyperRAM sustained throughput**, because the IP is encrypted and the write interface has no ready/acceptance handshake. Startup and final-burst overhead are not included in the steady-state estimate.

The scheduled rate exceeds the synthetic average input rate by about 3.93x and active-line input rate by about 3.05x, assuming all beats are accepted. That indicates nominal bandwidth headroom, not proof against arbitrary stalls.

## 8. CRC, counters, flags and diagnostic coverage

### 8.1 Measurement points

| Metric | RTL point | What it actually measures |
|---|---|---|
| Synthetic source byte count | `storage_test_pattern_generator.byte_count` | Bytes emitted with generator byte-valid |
| Capture CRC / byte count / word count | `rgb565_frame_packer` | Bytes accepted by packer; CRC over original byte order; packed words |
| FIFO overflow flag | top-level capture FIFO monitor | At least one packed word was offered while FIFO full; dropped-word count is not accumulated |
| Write CRC / word count | writer FSM | Words staged in burst buffer and scheduled through write sequence; not an IP acceptance acknowledgment |
| Read-ingress CRC / word count | `hyperram_line_reader` | Valid 32-bit read responses delivered from adapter/IP to readout |
| Readback CRC / bytes / words / pixels / UART bytes | `rgb565_line_serializer` | Data read from output FIFO and serialized; UART count increments on ready acceptance |
| Final integrity status | `frame_integrity_checker` | CRC chain equality, expected counts, completion and error conditions |

### 8.2 CRC convention

The capture packer uses CRC-32 polynomial `0x04C11DB7`, MSB-first, initial value `0xFFFFFFFF`, no final XOR. Writer/read-ingress/serializer CRCs process each 32-bit word in byte order `[31:24], [23:16], [15:8], [7:0]`.

### 8.3 Status flags

Synthetic top's status vector:
- bit 0 capture/source/FIFO1 error
- bit 1 writer error
- bit 2 HyperRAM reader/FIFO2 error
- bit 3 serializer error
- bit 4 UART protocol error
- bit 5 capture-vs-write CRC mismatch
- bit 6 write-vs-read-ingress CRC mismatch
- bit 7 capture byte count != expected
- bit 8 write word count != expected
- bit 9 read-ingress word count != expected
- bit 10 generator source byte count != packer capture byte count
- bit 13 storage checkpoints/counts passed

Camera top uses the same basic status meanings but bit 10 is hardwired to zero; its telemetry source/capture byte fields both carry the packer's capture byte count. Therefore the synthetic build has an independent generator byte counter that can detect a source-to-packer discrepancy, while the camera build does not expose an equivalent independent total-byte counter from the DVP interface.

### 8.4 Existing ILA setup

The self-test `hyperram_storage_selftest.gao` includes source byte count, source valid, packer valid, FIFO overflow/level, init_calib, write done/error/CRC/count, capture CRC, read-ingress CRC/count, reader/serializer errors, storage flags, telemetry valid, integrity done/error and system_ok. This is useful for source-to-storage tracing. It is an ILA/GAO configuration, not proof those signals were captured on hardware in this investigation.

## 9. Differences and data-loss points

1. **Source clock mismatch:** synthetic uses clk24; camera uses external cam_pclk. Their relative rate and phase to usr_clk differ.
2. **No upstream backpressure:** both sources and packer continue independently of FIFO full.
3. **FIFO full drops words:** FIFO suppresses write and advances no pointer; sticky overflow detects but cannot recover the word.
4. **No write acceptance handshake:** writer increments write CRC/count based on its state sequence, not an IP write-accepted response. If the IP misses a beat, software-visible write CRC may still reflect intended words; readback CRC is the independent check.
5. **Burst/IP assumptions:** controller uses 8-word groups and address stride 16, but physical burst semantics/address units are not verified against the encrypted IP.
6. **Camera DVP timing unknown:** PCLK frequency and actual HREF active duty must be measured. Sensor XCLK is driven by clk24 but this does not establish cam_pclk frequency.
7. **Startup/calibration:** writer waits for init_calib; source start is not explicitly gated by init_calib in the source instantiation. If a frame begins before calibration and writer cannot drain, FIFO may fill. Manual trigger after board initialization may avoid it in practice, but no explicit RTL interlock is shown.
8. **Readout-side overflow:** line reader does not backpressure HyperRAM read response stream; if output FIFO is full when a response arrives, it enters error. Current design reads one line (320 words) into a 512-word FIFO and waits for line completion/ack before next line, so nominal line fits.
9. **Camera content errors:** line/frame geometry checks detect short/long lines, but there is no independent expected-image CRC for real camera pixels. The CRC chain proves consistency from packer onward, not that sensor pixels are semantically correct.

## 10. What telemetry is still missing

For a decisive source-to-HyperRAM comparison, the following measurements are not currently exposed as counters/handshakes:

- camera PCLK edge count/frequency and active HREF cycle count per line/frame;
- separate DVP accepted-byte counter before packer, independent from packer counter;
- per-frame count of FIFO write attempts while full (currently sticky flag only);
- maximum capture FIFO occupancy and a latched high-water mark;
- number of FIFO read requests versus accepted read responses (writer has request/response counters locally, but no exported final telemetry);
- explicit HyperRAM write-accepted/beat counter or status if supported by IP;
- write command count, completed burst count, and per-burst timeout/error;
- maximum interval between accepted HyperRAM write beats;
- a timestamp/cycle counter for time spent with FIFO non-empty while writer is not servicing it;
- a measured camera frame period and PCLK/HREF timing snapshot.

No RTL changes are made by this report; these are proposed instrumentation points only.

## 11. Experiments to prove equivalence

1. **Static RTL comparison:** already performed for writer process; retain script/output or repeat in local checkout. Compare the packer, FIFO and writer sections by SHA/diff.
2. **Synthetic baseline capture:** trigger self-test; capture GAO signals from generator start through frame completion. Confirm 614,400 source bytes, 614,400 packer bytes, 153,600 words, no FIFO overflow, expected CRC equality and 19,200 8-word groups.
3. **Camera source characterization:** probe cam_pclk, cam_vsync, cam_hsync, cam_pix_data. Measure PCLK, HREF high cycles, line period, frame period, active bytes per line. Confirm exactly 1,280 accepted bytes per line and 480 lines.
4. **Camera FIFO stress:** capture FIFO write level/full/overflow and writer read request/response counts under the camera's actual frame timing. Confirm max occupancy remains below 2,048 and overflow stays low.
5. **Common-path equivalence:** run synthetic then camera with identical geometry and compare:
   - packer word count and byte order;
   - FIFO occupancy profiles normalized to source time;
   - writer burst count and address progression;
   - write CRC vs read-ingress CRC vs readback CRC;
   - all status bits and error signals.
6. **Write-stall test:** if IP or testbench can legally pause service, inject a controlled service interruption and verify observed FIFO occupancy against the calculated fill slope and time-to-full.
7. **Readback validation:** read the complete frame back and compare CRC/counts; do not rely on writer CRC alone because it counts intended/scheduled data, not confirmed physical acceptance.

## 12. Final answer to the research question

**Yes, from the packer output through the capture FIFO, burst writer and HyperRAM IP boundary, both designs implement the same storage datapath algorithm.** The evidence is the same packer entity, same FIFO entity/generic width/depth, identical FIFO write/read control pattern, byte-for-byte identical writer process after reset-name normalization, and same IP command/data mux and port mapping.

**No, the complete end-to-end source paths are not identical.** The synthetic generator runs in clk24 and emits a deterministic byte stream without a ready signal; the GC0308 path runs in cam_pclk and qualifies bytes using VSYNC/HSYNC plus line/frame geometry checks. Their ingress rates and CDC conditions are therefore different.

**No-loss behavior is not proven.** Both capture paths can lose a packed word when FIFO full; the RTL detects this as a sticky error but does not backpressure or replay. The writer's actual physical beat acceptance and HyperRAM burst semantics also remain unproven until the encrypted IP contract or hardware readback is validated.

## Appendix A — Continuation log

For investigation chronology, file SHAs, exact writer-comparison result, and resumable next steps, see [HYPERRAM_DATA_PATH_INVESTIGATION_LOG.md](HYPERRAM_DATA_PATH_INVESTIGATION_LOG.md).
