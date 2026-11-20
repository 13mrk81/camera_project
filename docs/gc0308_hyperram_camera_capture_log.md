# GC0308 camera capture integration log

## Branch and baseline
- Branch: `feature/gc0308-hyperram-camera-capture`
- Base branch: `study/synthetic-hyperram-uart-baseline`
- Goal: replace only the synthetic source and the necessary capture-domain boundary wiring. Keep the RGB565 packer contract and all later storage/readback/UART logic unchanged.

## Data path after this change
```text
GC0308 DVP (PCLK, VSYNC, HSYNC, D[7:0])
  -> camera_interface (SCCB configuration + one-frame DVP capture)
  -> byte_data / byte_valid / frame_done / frame_error
  -> rgb565_frame_packer
  -> async_fifo_32
  -> HyperRAM write engine
  -> HyperRAM readback / serializer / UART
```

## Change log
1. Added top-level GC0308 signals: `cam_pclk_i`, `cam_vsync_i`, `cam_hsync_i`, `cam_data_i[7:0]`, `cam_sda_io`, `cam_scl_io`, `cam_xclk_o`.
2. Removed `storage_test_pattern_generator` and its synthetic-ready/error tie-offs.
3. Instantiated `camera_interface`. The debounced trigger starts SCCB configuration; the UART protocol state machine receives the same trigger and remains gated by `cam_config_done/pass`.
4. Kept the `rgb565_frame_packer` entity and its byte/valid/frame-done/frame-error contract unchanged. Only its clock source changes to the actual sensor `cam_pclk_i`.
5. Moved capture FIFO #1 write clock, FIFO overflow detection, and capture-snapshot CDC source clock to `cam_pclk_i`. FIFO read side and HyperRAM writer remain on `usr_clk`.
6. Added a source-byte counter to `camera_interface`, measured as bytes emitted by the camera capture FSM. The existing packer byte/word counters remain separate measurements. At frame completion, a sticky mismatch detector compares camera-emitted bytes against packer-accepted bytes; mismatch is folded into the capture error path.
7. Added `i2c_master_nack.vhd` and `camera_interface.vhd` to the Gowin project; removed the synthetic generator from its active file list.
8. Changed the I2C controller to direct entity instantiation and mapped the full port list of the current `i2c_master_nack` entity, including its additional ACK/debug outputs.

## Clock domains and boundaries
- SCCB configuration: `clk24`.
- GC0308 XCLK: `clk24` forwarded by `camera_interface` to `cam_xclk_o`.
- DVP sampling and camera byte stream: external `cam_pclk_i`.
- RGB565 packer: `cam_pclk_i`.
- FIFO #1 write: `cam_pclk_i`; FIFO #1 read: `usr_clk`.
- Capture snapshot CDC: source event/data in `cam_pclk_i`, destination in `usr_clk`.
- HyperRAM write/read and UART protocol logic retain their existing clock domains.

The packer and FIFO write clock change is intentional: the sensor byte-valid signal is synchronous to PCLK, not to the unrelated 24 MHz system clock. The data format and packer outputs are unchanged.

## Debug and log points

### Configuration domain (`clk24`)
- `trigger_pulse`, `cam_config_done`, `cam_config_pass`
- SCCB: `i2c_start_sig`, `busy_sig`, `done_sig`, `ack_out_sig`, `nack_seen_sig`, `i2c_reg_sig`, `i2c_wdata_sig`, `i2c_rdata_sig`, `cfg_state_dbg`, `init_index_dbg`, `verify_index_dbg`

### Camera PCLK domain
- `cam_pclk_i`, `cam_vsync_i`, `cam_hsync_i`, `cam_data_i`
- `capture_state_dbg`, `pixel_byte_valid_sig`, `pix_data_reg`, `source_byte_count_sig`
- `cam_byte_data`, `cam_byte_valid`, `cam_frame_done`, `cam_frame_error`
- `cap_packed_word`, `cap_packed_valid`, `cap_byte_count`, `cap_word_count`
- `cap_fifo_full`, `cap_fifo_wr_level`, `cap_fifo_overflow_cam`, `source_packer_mismatch_cam`

### HyperRAM user domain (`usr_clk`)
- `cap_fifo_rd_level`, `cap_fifo_rd_empty`, `write_state`
- `load_req_count`, `load_rsp_count`, `load_complete`
- `mem_cmd_en_i`, `mem_cmd_i`, `mem_addr_i`, `mem_wr_data_i`
- `write_word_count`, `write_crc_reg`, `write_done_reg`, `write_error_reg`

## Not yet board-ready / validation limitations
- No physical camera pin locations were added to the CST file. Confirm the actual Tang Nano 4K camera wiring before assigning `IO_LOC`; do not guess pin numbers.
- The camera capture FSM expects active-high HSYNC and VSYNC and exactly `G_FRAME_WIDTH*2` bytes in each of `G_FRAME_HEIGHT` active lines. Verify polarity and geometry against the actual sensor output.
- XCLK is currently `clk24` forwarded directly. Confirm that this matches the sensor clock requirement and electrical board wiring.
- The actual PCLK frequency is not assumed to be 24 or 48 MHz. The capture path uses the external PCLK pin as its clock.
- FIFO #1 has no backpressure to the camera. A write while full is rejected and sets the sticky overflow flag; the camera may not be throttled.
- No Gowin synthesis, P&R, timing analysis, ILA capture, or hardware test has been run by this GitHub edit.

## Validation checklist
- [x] Created a parallel branch from the synthetic baseline.
- [x] Replaced synthetic source instance with the GC0308 camera interface.
- [x] Preserved the RGB565 packer entity interface.
- [x] Added a frame-end source-byte versus packer-byte convergence check.
- [x] Moved packer and FIFO write domain to actual camera PCLK.
- [x] Added camera and I2C RTL to the Gowin project file list.
- [ ] Confirm physical camera pin mapping and add CST constraints.
- [ ] Run Gowin syntax check and synthesis.
- [ ] Verify SCCB ACK/readback and config pass on hardware.
- [ ] Verify DVP polarities, line byte count, frame byte count, and measured PCLK.
- [ ] Verify no FIFO overflow and compare camera source byte count with packer byte count.
- [ ] Verify HyperRAM write/readback CRC and UART image reconstruction.
