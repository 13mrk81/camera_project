# GC0308 Camera Interface Review Log

## Review metadata

- Date: 2026-11-20
- Target branch: `feature/gc0308-hyperram-camera-capture`
- Reference branch: `feature/matlab-line-stream`
- Scope: audit the camera-side logic up to the input boundary of `rgb565_frame_packer`.
- Explicit exclusion: do not modify `rgb565_frame_packer.vhd`, the FIFO, HyperRAM write/read logic, serializer, UART transport, MATLAB receiver, or any other logic after the packer.
- Status: **audit complete; pre-packer diagnostics and ACK checks implemented. Physical pin mapping and hardware validation remain pending.** The initial audit itself was read-only; all implementation commits and checks are recorded below.

## Reference comparison

The reference packer and current packer are byte-for-byte identical:

- File: `gowin_cameradrive/src/rgb565_frame_packer.vhd`
- SHA on both branches: `82ed26cc84a93fe3653ad2c7debf22ca55b160ef`

The packer contract is therefore treated as fixed:

- Inputs are synchronous to `cam_pclk`.
- `cam_byte_valid_i` qualifies one byte on each rising `cam_pclk`.
- Four consecutive bytes are packed in arrival order into `packed_word_o[31:0]`.
- `packed_valid_o` indicates one complete 32-bit word.
- Frame completion/error and byte/word counters are reported by the existing interface.
- No color conversion or byte reordering is performed in the packer.

The reference I2C master and the original target-branch I2C master were byte-for-byte identical at the time of the initial audit (SHA `926e3eab3df966c5670847450ddd12d94fcd528a`). The implementation pass below deliberately keeps its transaction state sequencing and open-drain drive behavior, while adding an SCL input observation port and divider assertions. The camera sequencer also now checks that every register transaction receives all three expected ACKs before advancing.

## Findings

### 1. Current failure packet does not identify the internal camera failure reason

The host protocol's `C_WAIT_CAMERA_CONFIG` state emits:

- `error_code_desc = x"01"` (constant meaning `CAMERA_CONFIG`)
- `error_detail_desc = x"01"` (also constant)

It does not transmit the internal `camera_interface.error_code_sig`, the configuration FSM state, the current register address, `nack_seen_sig`, or the I2C ACK count.

Consequently, the host output:

```text
[FPGA ERROR] camera configuration failed (code=0x01, detail=0x01, seq=0)
```

proves that the camera-configuration stage ended unsuccessfully. It does **not** prove that the first SCCB transaction received a NACK, nor does it identify which register/readback step failed. The previous hypothesis that the packet specifically proves an initial NACK was too strong; the current telemetry does not support that conclusion.

### 2. Camera pins are absent from the active SelfTest CST

The active project `HYPERRAM_STORAGE_SELFTEST.gprj` includes `src/hyperram_storage_selftest.cst`. In the current branch this CST constrains the board clock, UART TX, and KEY1 trigger, but it contains no `IO_LOC` entries for the camera ports:

- `cam_xclk_o`
- `cam_scl_io`
- `cam_sda_io`
- `cam_pclk_i`
- `cam_vsync_i`
- `cam_hsync_i`
- `cam_data_i[7:0]`

The older `feature/matlab-line-stream` reference CST (`hyper_ctrl.cst`) contains a candidate Tang Nano 4K camera map:

| Camera signal | Reference package pin |
|---|---:|
| `cam_clk` / XCLK | 33 |
| `cam_scl` | 44 |
| `cam_sda` | 46 |
| `cam_vsync` | 43 |
| `cam_hsync` | 42 |
| `cam_pclk` | 41 |
| `cam_pix_data[0]` | 22 |
| `cam_pix_data[1]` | 21 |
| `cam_pix_data[2]` | 17 |
| `cam_pix_data[3]` | 19 |
| `cam_pix_data[4]` | 20 |
| `cam_pix_data[5]` | 18 |
| `cam_pix_data[6]` | 16 |
| `cam_pix_data[7]` | 23 |

This is historical project evidence, not an independently verified board schematic/wiring record. It must be checked against the exact camera connector/module wiring and FPGA bank voltages before reuse. The old file also uses different top-level port names, so the signal-name mapping must be updated rather than copied blindly.

**Assessment:** if the failing bitstream was built from the current SelfTest project and this CST, the camera interface is not constrained to the known camera connector pins. This is a primary configuration item to resolve before attributing the failure to the I2C RTL.

### 3. I2C master behavior and constraints

The unchanged `i2c_master_nack` uses open-drain behavior:

- It drives a line low when required.
- It releases the line to high impedance otherwise.
- It samples SDA during the high portion of the ACK clock.
- It clears `nack_seen` and ACK count at the beginning of each accepted transaction.
- It records slave NACKs but continues through the transaction to STOP/DONE; the sequencer checks the sticky NACK result after `done`.

At 24 MHz / 100 kHz, the RTL uses 60 system-clock cycles per quarter phase. The default GC0308 7-bit device address in `camera_interface` is `0x21`.

Hardware requirements and limitations to account for:

- SDA and SCL require suitable external pull-ups to the correct I/O voltage.
- The master does not implement clock-stretch detection, a bus-stuck timeout, or bus-clear recovery.
- `nack_seen` is an internal per-transaction result, not currently included in the host error packet.
- The current top-level GAO file does not provide a usable camera/SCCB diagnostic capture list.

These limitations do not by themselves prove the cause of the observed failure. They define what must be observed and tested.

### 4. Configuration sequence in `camera_interface`

After the KEY1-derived trigger, the sequencer:

1. Waits for its internal I2C power-on delay.
2. Writes `0x00` to register `0xFE` to select page 0.
3. Reads register `0x00` and expects chip ID `0x9B`.
4. Writes soft reset value `0xF0` to `0xFE`.
5. Waits the configured reset interval.
6. Writes the long initialization table, including page selection and RGB565 register setting `0x24 = 0xA6`.
7. Waits for settling.
8. Reads back selected registers.
9. Performs a final readback of register `0x24` and expects `0xA6`.
10. Asserts configuration done/pass only after the checks complete.

Internal error codes are assigned in the sequencer for the initial page-select transaction, chip-ID read, soft reset, initialization writes, verify reads/mismatches, and final RGB565 readback. Those details are not exported through the current top-level protocol.

### 5. DVP capture assumptions

The capture FSM in the current camera interface is clocked by the external `cam_pclk_i` and produces the byte/valid interface consumed by the packer. This clock-domain choice is correct for a DVP data bus whose data and sync signals are synchronous to PCLK.

The current capture implementation assumes:

- VSYNC active high.
- HSYNC active high.
- Data is valid on rising PCLK while HSYNC is high.
- Each active line contains exactly `G_FRAME_WIDTH * 2` bytes.
- Exactly `G_FRAME_HEIGHT` active lines occur per frame.
- Capture begins at the next VSYNC rising edge after configuration passes.

The register table writes `0x26 = 0x03`, and the RTL comments interpret this as active-high HSYNC/VSYNC. That interpretation and the selected edge/polarity must be verified against the exact GC0308 register documentation and actual sensor waveform. The FSM currently rejects any line with a byte count different from the configured line length.

### 6. Clock and reset topology

- `camera_interface` forwards `clk24` to the sensor clock output (`clkcam <= clk24`).
- SCCB control runs on `clk24`.
- DVP sampling and the camera byte stream run on external `cam_pclk_i`.
- The packer is also clocked by `cam_pclk_i`, keeping byte and valid in the same clock domain.
- The camera interface has an internal I2C power-on reset delay; the capture FSM uses a synchronized version of this reset in the PCLK domain.
- The current top-level `rst_n` is tied high. The I2C block therefore relies on its internal power-on counter/initialization, while the packer receives the constant-high top reset.

The reset behavior should be made explicit and consistently sequenced for the camera configuration and DVP capture path. This is a proposed pre-packer correction; the packer implementation and downstream logic remain out of scope.

### 7. Debug configuration is stale for the camera implementation

The active `hyperram_storage_selftest.gao` signal list still contains synthetic-source debug names (for example, `test_source_start_pulse` and `test_source_error`) and does not include the camera configuration FSM, I2C ACK/NACK signals, SCCB bus inputs, or the DVP capture FSM diagnostics. It should be rebuilt as a camera-focused diagnostic setup, while preserving the existing post-packer RTL.

## Applied fixes and remaining work

### Applied in this implementation run

1. **Configuration observability:** exported the camera FSM state and internal error code, current SCCB device/register/data/RW fields, chip ID, last readback, verify address/expected value/fail flag, I2C state/sequence/phase, ACK/NACK flags/count, and physical SDA/SCL samples plus master drive intent.
2. **I2C timing validity:** added elaboration-time checks that `G_CLK_FREQ_HZ` divides into four equal I2C phases and that each quarter phase has at least two system-clock cycles. The default 24 MHz / 100 kHz setup is exact (60 cycles per quarter phase).
3. **ACK completeness:** the six configuration transaction wait states now require `ack_count = 3` and `nack_seen = 0`. Both writes (device address, register address, data) and register reads (write address, register address, read address) are expected to produce three slave ACKs.
4. **Top-level integration:** connected the diagnostic outputs in `HyperRAM_Storage_SelfTest`; updated the legacy `Camera_HyperRAM_OneFrame` component declaration and port map to match the expanded entity. The legacy declaration also now includes the already-existing `source_byte_count_o` output.
5. **GAO:** replaced stale synthetic-generator probes with 29 camera/SCCB diagnostic signals, sampled in the `clk24` domain.

### Deliberately not changed

- **Camera pin constraints:** the active `hyperram_storage_selftest.cst` still lacks camera `IO_LOC` assignments. The historical `hyper_ctrl.cst` map was not copied because the exact module-to-connector wiring and voltage domains have not been confirmed for this hardware setup. Applying unverified pin locations would not be a safe correction.
- **UART error packet format:** its fixed `CAMERA_CONFIG` detail remains unchanged because changing the packet controller would cross the explicitly protected downstream boundary. Internal root-cause details are now available to GAO instead.
- **Clock stretching and automatic bus recovery:** not implemented without evidence that this GC0308 SCCB connection requires them. The sampled SCL and SDA values plus the master's drive-intent signals are available to distinguish common electrical faults during the next capture.
- **Packer and later datapath:** no changes were made to the packer source, FIFO, HyperRAM engine/readout, serializer, integrity checker, UART TX, or UART protocol controller. The Packer and post-Packer portions of both top-level files were checked for exact textual identity against the pre-implementation commit.

### Remaining work before board-level validation

1. Confirm which Gowin project/bitstream is actually programmed (`HYPERRAM_STORAGE_SELFTEST.gprj` or `HYPER_RAM_CONTROL.gprj`).
2. Confirm the camera connector pinout, I/O bank voltage, SDA/SCL pull-up presence and pull-up rail. Only then add camera constraints to the active CST.
3. Build the updated project and inspect the new GAO probes during KEY1.
4. Use `cam_config_error_code`, `cam_config_state`, `cam_config_reg_addr`, `cam_i2c_ack_count`, `cam_i2c_nack`, `cam_i2c_sda_sample`, and `cam_i2c_scl_sample` to locate the exact failing transaction.
5. After Configuration passes, independently validate XCLK, PCLK, HSYNC/VSYNC polarity, line byte count, frame line count, and Packer input convergence.

## Required evidence before full board validation

- Confirm the exact project/bitstream used for the failing UART run.
- Confirm the camera module connector wiring and its I/O bank voltage.
- Confirm whether external SDA/SCL pull-ups exist and their rail voltage.
- Capture SCL/SDA around KEY1 using the new GAO signals.
- Read back the GC0308 chip ID and record the actual returned value.
- Run Gowin syntax analysis/synthesis and review warnings before programming the FPGA.

## Change record

- 2026-11-20: created this review log on `feature/gc0308-hyperram-camera-capture`.
- Implementation changes are recorded in the execution log below. No camera pin constraints were guessed or added.

## Implementation execution log

### Run started: 2026-11-20

Implementation is constrained to the camera-control path and the signals immediately upstream of `rgb565_frame_packer`. The packer source and all downstream RTL are protected from edits.

| Step | Status | Intended change |
|---|---|---|
| Re-read the integration log and interface audit | Complete | Reconfirm scope and known limitations |
| Add internal SCCB/configuration diagnostics to the camera interface boundary | Complete | Export config FSM/error state, current register transaction, ACK/NACK count, I2C FSM and physical SDA/SCL samples |
| Add I2C timing parameter checks and SCL input observation | Complete | No transaction waveform change intended |
| Require all three expected ACKs for each SCCB register transaction | Complete | Treat incomplete ACK sequences as configuration failures |
| Update both top-level wrappers that instantiate the camera interface | Complete | Keep the legacy project source-compatible; do not alter packer or later logic |
| Replace stale synthetic-source GAO probes with camera/SCCB diagnostics | Complete | Capture the cause of the next configuration failure |
| Verify protected files and record commit hashes | Complete | Prove no Packer/downstream source was modified |

### Decisions and non-changes

- The historical camera pin map is **not** copied into the active SelfTest CST because the exact camera connector wiring and I/O voltage have not been independently confirmed.
- The public UART error packet format is not changed; doing so would require editing the host protocol controller, outside the requested protected boundary. Internal details will instead be exposed to GAO.
- Clock-stretch support and automatic bus recovery are not added without evidence that the GC0308 SCCB interface requires them. The physical SCL input will be observable to distinguish a driven-low line from a released-but-not-high line.
- No claim of synthesis, place-and-route, or hardware validation will be made unless those checks are actually run.

- 2026-11-20 — Updated `gowin_cameradrive/src/i2c_master_nack.vhd` (commit `df299944fecbc5377f219b97745a4092582363a1`): exposed the physical SCL input as `dbg_scl_in` and added elaboration-time assertions that the four-phase divider is integral and has at least two system-clock cycles per quarter phase. The I2C state machine, open-drain drive behavior, phase sequencing, and nominal 100 kHz waveform were not changed.

- 2026-11-20 — Updated `gowin_cameradrive/src/camera_interface.vhd` (commit `488ac46a78f869fae1a756b9b9ce715d4dbb3cfc`): added diagnostic outputs for the configuration FSM/error code, current register transaction, chip ID/readback, I2C FSM/ACK/NACK/ACK count, SDA/SCL samples, explicit bus-idle status, and drive intent, plus DVP capture state/line counters. Added a configurable `G_I2C_FREQ_HZ` generic (default remains 100 kHz). Each of the six SCCB register transactions now requires all three expected ACKs (`ack_count = 3`) as well as no NACK before the sequencer advances. Register programming order, existing error-code assignments, DVP byte stream, and packer interface are unchanged.

- 2026-11-20 — Updated `gowin_cameradrive/src/HyperRAM_Storage_SelfTest.vhd` (commit `c0fb2fac0c4d7df9db976e3859b7a689a7bad569`): wired the new camera/SCCB diagnostic outputs to kept top-level signals for GAO. Also connected the camera line counters instead of leaving those diagnostic outputs open. The `rgb565_frame_packer` instance and its ports are unchanged.

- 2026-11-20 — Updated `gowin_cameradrive/src/Camera_HyperRAM_OneFrame.vhd` (commit `c5707348f0a86652643590850509a6ca3153b910`): updated the legacy component declaration and mapping for the expanded camera-interface ports, including the previously omitted `source_byte_count_o`. This keeps the alternate `HYPER_RAM_CONTROL.gprj` top-level compatible with the current camera-interface entity. The legacy packer instance and all following RTL were not changed.

- 2026-11-20 — Updated `gowin_cameradrive/src/hyperram_storage_selftest.gao` (commit `200d16e005ffce1ea0006cc25f7a8da53428a154`): removed stale synthetic-generator probes that no longer exist and replaced the capture list with 31 clk24-domain camera/SCCB diagnostic signals. The trigger and match-unit configuration remain unchanged. This GAO is for locating configuration failures; it does not modify the UART packet format or any downstream RTL.
- 2026-11-20 — Follow-up compatibility correction in `gowin_cameradrive/src/Camera_HyperRAM_OneFrame.vhd` (commit `6c8e4562abfbeb8637c89f73820287d01d8405f0`): aligned the component declaration port order with the `camera_interface` entity, including placing `source_byte_count_o` immediately after the frame byte-stream ports. This avoids relying on nonmatching component/entity interface order during binding.


### Static verification performed

- Camera entity port count: 49. The SelfTest top-level named association covers all 49 ports.
- Legacy component port count: 49. Its component port order now matches the camera entity, and its named port map covers every port.
- I2C master port count: 25. The camera interface maps every port, including the new physical SCL sample.
- All 31 GAO capture names resolve to declared signals in the SelfTest top.
- All six camera configuration transaction wait states contain the `ack_count = "11"` check, in addition to the NACK check.
- Compared with the implementation-start commit `631e6b14d12e1e78bb74e86ad9788799625974b0`, the `rgb565_frame_packer` SHA is still `82ed26cc84a93fe3653ad2c7debf22ca55b160ef`. The following independent modules also have unchanged blob SHAs: `async_fifo_32`, `gowin_hyperram_read_adapter`, `hyperram_line_reader`, `hyperram_line_readout`, `rgb565_line_serializer`, `camera_uart_frame_protocol`, `frame_integrity_checker`, `pulse_toggle_cdc`, `stable_bus_event_cdc`, and the generated HyperRAM interface RTL.
- The complete source region beginning at the `u_rgb565_packer` instance and extending to end-of-file is byte-for-byte unchanged in both top-level RTL files.
- The branch diff for this implementation contains changes only to the review log, the two top-level wrapper files, `camera_interface.vhd`, `i2c_master_nack.vhd`, and the SelfTest GAO file.

**Not performed:** Gowin syntax check, synthesis, place-and-route, timing analysis, bitstream generation, ILA/GAO hardware capture, or sensor electrical validation. This is an RTL/static integration result, not a claim that the camera has been proven operational on the board.
- 2026-11-20 — Added `dbg_bus_idle` to `gowin_cameradrive/src/i2c_master_nack.vhd` (commit `385186f64fc2ad0a1274ada8f21adf95c256d985`): it asserts only when the sampled physical SCL and SDA inputs are both logic-high. This is observational only and does not alter the transaction state machine. No separate transaction timeout was added: the existing master does not wait on SCL/SDA to advance its fixed-phase FSM, so a continuously clocked transaction is already finite; the new bus-idle/SCL/SDA probes expose a held-low bus without introducing a new wait-state path.
- 2026-11-20 — Propagated `i2c_bus_idle_o` through `camera_interface.vhd` (commit `79f18d54ca04f4b170556d7bc02ad348db4dbc27`) so the top-level GAO can distinguish a released high bus from a held-low bus.
- 2026-11-20 — Connected and kept the new `cam_i2c_bus_idle` diagnostic at the SelfTest top level (commit `5dd189aefae45b5c904ec70aa32571afe723e7e3`).
- 2026-11-20 — Added the same `i2c_bus_idle_o` connection to the legacy `Camera_HyperRAM_OneFrame` wrapper (commit `c1fc244455d83d47573853ac017c96b353b1d693`) so both project tops expose the same SCCB line diagnostics.
- 2026-11-20 — Added `cam_i2c_bus_idle` to the active GAO capture list (commit `666cc51e22ffbaf43b65d65a1f2d1ec11839e353`), completing the explicit SDA/SCL/bus-idle view for the SelfTest project.


## Post-implementation retest record

### Host UART result received

The following result was reported after the implementation changes:

```text
UART opened: /dev/ttyUSB0 @ 115200 baud, 8N1 (receive-only)
No UART commands will be transmitted. Press the board's KEY1 button to start.
[STAGE 1/3] FPGA accepted KEY1 trigger. Camera setup started.
[FPGA ERROR] camera configuration failed (code=0x01, detail=0x01, seq=0).

Receiver state: ERROR
Valid LINE packets: 0 | duplicates: 0 | out-of-order: 0
Rejected CRC candidates: 0 | discarded bytes during resync: 0
No READY/image data received; no frame file written.
```

### Interpretation

- The KEY1 trigger and generic camera-configuration failure were reported.
- The UART protocol controller intentionally retains its old fixed `CAMERA_CONFIG` error code/detail. Therefore this identical host message is expected even when the new internal diagnostics are present.
- This log alone cannot establish whether the FPGA was programmed with the newly synthesized bitstream, and it cannot identify the internal SCCB transaction/error.
- No new RTL change is justified from this UART line alone.

### Required next observation

Confirm that the local clone contains the latest branch and that the bitstream was rebuilt/programmed from `HYPERRAM_STORAGE_SELFTEST.gprj`. Then use `hyperram_storage_selftest.gao` to trigger on `cam_config_fail` (or capture the relevant `cam_i2c_done` event) and read:

`cam_config_error_code`, `cam_config_state`, `cam_config_reg_addr`, `cam_config_reg_data`, `cam_config_device_addr`, `cam_config_chip_id`, `cam_i2c_ack_count`, `cam_i2c_nack`, `cam_i2c_state`, `cam_i2c_sequence`, `cam_i2c_sda_sample`, `cam_i2c_scl_sample`, `cam_i2c_bus_idle`.

No changes to the packer or downstream datapath were made in response to this retest record.
- 2026-11-20 — Updated `hyperram_storage_selftest.gao` (commit `65ed759cc8797d9c50b7d614f3133fe9c6eba925`) to trigger on sticky `cam_config_fail` rather than the initial KEY1 pulse. This makes the short GAO capture window preserve the terminal configuration error, current register context, and ACK/NACK diagnostics. Sample clock remains `clk24`; the UART packet and datapath are untouched.
