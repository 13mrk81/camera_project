# GC0308 Camera Interface Review Log

## Review metadata

- Date: 2026-11-20
- Target branch: `feature/gc0308-hyperram-camera-capture`
- Reference branch: `feature/matlab-line-stream`
- Scope: audit the camera-side logic up to the input boundary of `rgb565_frame_packer`.
- Explicit exclusion: do not modify `rgb565_frame_packer.vhd`, the FIFO, HyperRAM write/read logic, serializer, UART transport, MATLAB receiver, or any other logic after the packer.
- Status: **review only; no RTL, CST, GAO, or project source has been modified by this review**.

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

The reference I2C master and current I2C master are also byte-for-byte identical:

- File: `gowin_cameradrive/src/i2c_master_nack.vhd`
- SHA on both branches: `926e3eab3df966c5670847450ddd12d94fcd528a`

The camera sequencer is almost identical at the functional level. The current branch adds the source-byte counter and changes the I2C instantiation from component binding to direct entity instantiation, explicitly mapping the 24 MHz / 100 kHz generics and the additional ACK/debug outputs. The current branch does **not** contain a new I2C transaction algorithm compared with the reference branch.

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

## Proposed correction plan (not applied)

The following is the recommended order. No item below has been applied yet.

1. **Physical mapping first:** verify camera connector pinout and I/O bank voltage; then constrain the current top-level camera ports in the active SelfTest CST. Use the historical reference map only after confirmation.
2. **Expose configuration diagnostics:** preserve the existing external UART protocol format if required, but add a separate debug/telemetry path for internal camera error code, configuration state, current register address/data, I2C busy/done, ACK count, NACK flag, and sampled SDA.
3. **Harden I2C control:** add bounded timeout/error handling and explicit bus-idle/stuck-line diagnostics. Keep the same 7-bit addressing and open-drain electrical behavior. Clock-stretch support should be added only if required by the sensor/interface specification.
4. **Validate SCCB sequence:** observe the first page-select transaction, then chip-ID readback (`0x9B`), soft reset, initialization writes, and the final `0x24 = 0xA6` readback. Do not assume the first transaction is the failure until the internal reason is visible.
5. **Make sensor startup sequencing explicit:** verify XCLK presence/frequency, module reset/power-down state, and the minimum startup/reset delays from the sensor/module requirements.
6. **Validate DVP capture independently:** measure PCLK, VSYNC/HSYNC polarity, active window, bytes per line, and active lines. Compare camera-emitted byte count with the packer's existing byte count at frame completion.
7. **Stop at the packer boundary:** once the incoming byte stream is valid, leave the packer implementation and every block after it unchanged.

## Required evidence before applying code changes

- Confirm the exact project/bitstream used for the failing UART run.
- Confirm the camera module connector wiring and its I/O bank voltage.
- Confirm whether external SDA/SCL pull-ups exist and their rail voltage.
- Capture SCL/SDA around KEY1, or collect the internal I2C diagnostic signals with GAO/ILA.
- Read back the GC0308 chip ID and record the actual returned value.

## Change record

- 2026-11-20: created this review log on `feature/gc0308-hyperram-camera-capture`.
- No RTL/CST/GAO/project changes have been made as part of this review.

## Implementation execution log

### Run started: 2026-11-20

Implementation is constrained to the camera-control path and the signals immediately upstream of `rgb565_frame_packer`. The packer source and all downstream RTL are protected from edits.

| Step | Status | Intended change |
|---|---|---|
| Re-read the integration log and interface audit | Complete | Reconfirm scope and known limitations |
| Add internal SCCB/configuration diagnostics to the camera interface boundary | In progress | Export config FSM/error state, current register transaction, ACK/NACK count, I2C FSM and physical SDA/SCL samples |
| Add I2C timing parameter checks and SCL input observation | Pending | No transaction waveform change intended |
| Require all three expected ACKs for each SCCB register transaction | Pending | Treat incomplete ACK sequences as configuration failures |
| Update both top-level wrappers that instantiate the camera interface | Pending | Keep the legacy project source-compatible; do not alter packer or later logic |
| Replace stale synthetic-source GAO probes with camera/SCCB diagnostics | Pending | Capture the cause of the next configuration failure |
| Verify protected files and record commit hashes | Pending | Prove no Packer/downstream source was modified |

### Decisions and non-changes

- The historical camera pin map is **not** copied into the active SelfTest CST because the exact camera connector wiring and I/O voltage have not been independently confirmed.
- The public UART error packet format is not changed; doing so would require editing the host protocol controller, outside the requested protected boundary. Internal details will instead be exposed to GAO.
- Clock-stretch support and automatic bus recovery are not added without evidence that the GC0308 SCCB interface requires them. The physical SCL input will be observable to distinguish a driven-low line from a released-but-not-high line.
- No claim of synthesis, place-and-route, or hardware validation will be made unless those checks are actually run.

- 2026-11-20 — Updated `gowin_cameradrive/src/i2c_master_nack.vhd` (commit `df299944fecbc5377f219b97745a4092582363a1`): exposed the physical SCL input as `dbg_scl_in` and added elaboration-time assertions that the four-phase divider is integral and has at least two system-clock cycles per quarter phase. The I2C state machine, open-drain drive behavior, phase sequencing, and nominal 100 kHz waveform were not changed.

- 2026-11-20 — Updated `gowin_cameradrive/src/camera_interface.vhd` (commit `488ac46a78f869fae1a756b9b9ce715d4dbb3cfc`): added diagnostic outputs for the configuration FSM/error code, current register transaction, chip ID/readback, I2C FSM/ACK/NACK/ACK count, SDA/SCL samples and drive intent, plus DVP capture state/line counters. Added a configurable `G_I2C_FREQ_HZ` generic (default remains 100 kHz). Each of the six SCCB register transactions now requires all three expected ACKs (`ack_count = 3`) as well as no NACK before the sequencer advances. Register programming order, existing error-code assignments, DVP byte stream, and packer interface are unchanged.

- 2026-11-20 — Updated `gowin_cameradrive/src/HyperRAM_Storage_SelfTest.vhd` (commit `c0fb2fac0c4d7df9db976e3859b7a689a7bad569`): wired the new camera/SCCB diagnostic outputs to kept top-level signals for GAO. Also connected the camera line counters instead of leaving those diagnostic outputs open. The `rgb565_frame_packer` instance and its ports are unchanged.

- 2026-11-20 — Updated `gowin_cameradrive/src/Camera_HyperRAM_OneFrame.vhd` (commit `c5707348f0a86652643590850509a6ca3153b910`): updated the legacy component declaration and mapping for the expanded camera-interface ports, including the previously omitted `source_byte_count_o`. This keeps the alternate `HYPER_RAM_CONTROL.gprj` top-level compatible with the current camera-interface entity. The legacy packer instance and all following RTL were not changed.

- 2026-11-20 — Updated `gowin_cameradrive/src/hyperram_storage_selftest.gao` (commit `200d16e005ffce1ea0006cc25f7a8da53428a154`): removed stale synthetic-generator probes that no longer exist and replaced the capture list with 29 clk24-domain camera/SCCB diagnostic signals. The trigger and match-unit configuration remain unchanged. This GAO is for locating configuration failures; it does not modify the UART packet format or any downstream RTL.
