# Camera_HyperRAM_OneFrame — integrated line-readout RTL

This source set integrates the unchanged GC0308 `camera_interface` and the
unchanged generated `HyperRAM_Memory_Interface_Top` user interface with the
raw RGB565 capture/write path, line-by-line readout, output FIFO, RGB888
serializer, UART byte handshake, and frame-integrity checker.

## Files

| File | Purpose |
|---|---|
| `Camera_HyperRAM_OneFrame.vhd` | New top module. Instantiates and controls the capture and readout subsystems. |
| `camera_interface.vhd` | Exact copy of the supplied camera-interface source; not modified. |
| `i2c_master_nack.vhd` | Exact copy of the supplied I2C master source; not modified. |
| `rgb565_frame_packer.vhd` | Packs four original camera RGB565 bytes into one 32-bit word and computes capture CRC. |
| `async_fifo_32.vhd` | Dual-clock 32-bit FIFO. Includes both write-domain and read-domain occupancy outputs. |
| `falling_edge_one_shot.vhd` | Synchronizes the external start input and emits one pulse on its first falling edge. |
| `stable_bus_event_cdc.vhd` | Transfers the final capture CRC/counter snapshot across clock domains. |
| `hyperram_line_reader.vhd` | Requests and receives one image line at a time. |
| `rgb565_line_serializer.vhd` | Converts each raw RGB565 pixel to RGB888 and sends R, G, B with ready/valid. |
| `hyperram_line_readout.vhd` | Integrates line reader, output FIFO #2, and RGB serializer. |
| `gowin_hyperram_read_adapter.vhd` | Adapts the line-reader command handshake to the existing HyperRAM command pins. |
| `frame_integrity_checker.vhd` | Checks CRCs, counts, line total, completion and UART idle before asserting `system_ok`. |
| `rtl_sources.f` | Suggested source compile order. |

## Memory layout and default 640 x 480 geometry

The camera still produces RGB565 bytes through the unchanged `camera_interface`.
The top no longer expands RGB565 during capture. It stores the original bytes:

```text
32-bit HyperRAM user word:
[31:24] pixel 0 byte 0
[23:16] pixel 0 byte 1
[15: 8] pixel 1 byte 0
[ 7: 0] pixel 1 byte 1
```

| Quantity | Default value |
|---|---:|
| Pixels per frame | 307,200 |
| Original RGB565 bytes | 614,400 |
| 32-bit words per frame | 153,600 |
| Words per line | 320 |
| HyperRAM beats per burst | 8 |
| Bursts per line | 40 |
| Total frame bursts | 19,200 |
| Output FIFO #2 depth | 512 words (holds one 320-word line) |
| UART RGB888 bytes | 921,600 |

The frame width must be divisible by 16: two pixels are packed per word and
there are eight words per burst. This ensures each line contains an integer
number of bursts.

## HyperRAM interface preservation and assumptions

The top retains the supplied HyperRAM component interface and configuration:

- `clk => clk24`
- `memory_clk => clk96`
- `pll_lock => pll_stable`
- `clk_out => usr_clk`
- 32-bit `wr_data` and `rd_data`
- 22-bit `addr`
- read command `cmd='0'`, write command `cmd='1'`
- eight 32-bit user beats per burst
- address increment of 16 between burst commands
- the existing command interval generic (default 21 user-clock cycles)

The address unit and exact command/response timing are not defined by the
component declaration alone. The stride of 16, the 8-beat response expectation,
and the one-cycle read-data adapter pipeline reproduce the assumptions visible
in the supplied reference RTL; they are not a substitute for checking the
actual generated Gowin IP example or simulation model.

The write engine sends the first word with the write command and the remaining
seven words on successive `usr_clk` cycles, matching the supplied top's write
style. Read requests are issued by `gowin_hyperram_read_adapter`; that adapter
holds a minimum command spacing of `G_CMD_INTERVAL_CYCLES`.

## Clock domains

- Camera byte capture, RGB565 packing, capture FIFO #1 write side and capture
  CRC: `cam_pclk`.
- Capture FIFO #1 read side, HyperRAM write engine, HyperRAM read adapter and
  line-reader/FIFO #2 write side: `usr_clk`.
- In this top-level integration the output FIFO #2 read side, serializer,
  UART valid/ready interface and final integrity checker also use `usr_clk`.
  Therefore the user's UART transmitter must use `readback_clk_o` as its clock.
  The FIFO remains dual-clock-capable if a separate UART clock is introduced
  in a later revision, but then the integrity snapshot/idle CDC must also be
  updated.

## Top-level start input

`rst_trigger` is now the external active-high-then-falling start request. The
first synchronized high-to-low transition after reset produces a one-clock
pulse for the existing `camera_interface.rst_trigger` input. This preserves the
camera module's own rising-edge trigger behavior. The one-shot does not re-arm
until global reset. The input must first be observed high and then fall.

## UART interface

Connect a UART transmitter with a synchronous ready/valid byte interface:

- Clock: `readback_clk_o` (`usr_clk`).
- `uart_tx_data_o`: current byte.
- `uart_tx_valid_o`: byte is offered; remains asserted until accepted.
- `uart_tx_ready_i`: transmitter can accept a byte on this edge.
- Transfer occurs when `uart_tx_valid_o = '1'` and `uart_tx_ready_i = '1'`.
- `uart_tx_idle_i`: assert only when the UART transmitter has completely
  finished shifting the final byte and has no queued byte pending.
- `uart_r_valid_o`, `uart_g_valid_o`, `uart_b_valid_o`: channel-specific
  qualifiers. Exactly one is asserted for each presented RGB component.
- `rgb_r_o`, `rgb_g_o`, `rgb_b_o`: expanded channel registers.

The UART itself is intentionally not instantiated because its RTL/interface
was not included in the three supplied main sources. These ports are the
connection boundary to that module.

## Line handshake

- `line_read_req_o` (Flag A): one-clock pulse when the line reader starts a line.
- `line_ready_o` (Flag B): held high after all 320 words of that line are in
  output FIFO #2; remains high until the serializer consumes the line.
- `line_consumed_o`: held until the reader deasserts `line_ready_o`.
- `line_complete_o`: one-clock pulse after the reader has observed consumption.
- `line_index_o`: zero-based line index.
- `line_word_count_o`: words buffered for the current line.

The reader waits until FIFO #2 is empty (including synchronized read-pointer
visibility) before loading the next line.

## Integrity and status

The packer calculates CRC-32 over every original camera byte. The write engine
calculates the same CRC over the ordered bytes in each 32-bit word presented to
HyperRAM. The serializer calculates readback CRC over the ordered raw RGB565
bytes recovered from FIFO #2, before RGB888 conversion. The final checker
requires:

- capture, write and readback CRC equality;
- 614,400 captured/readback raw bytes;
- 153,600 written/readback words;
- 307,200 serialized pixels;
- 921,600 UART bytes;
- 480 consumed lines;
- capture/write/readout completion and UART idle;
- no capture, writer, reader or serializer error.

`system_ok_o` is sticky high only after all final checks pass. `done_o` is an
alias of `system_ok_o`. `error_o` includes writer, capture, readout and final
integrity errors.

## Suggested compile order

Use `rtl_sources.f`, then add the generated Gowin IP files for the two PLLs and
`HyperRAM_Memory_Interface_Top` to the Gowin project. The `camera_interface`
and `i2c_master_nack` files in this package are unchanged copies of the sources
provided for this task.

## Important integration note about the supplied I2C sources

The uploaded `camera_interface.vhd` declares an `i2c_master_nack` component with
a smaller debug-port list than the uploaded `i2c_master_nack.vhd` entity. Both
files have been copied without modification, as requested. Check Gowin's
component-binding/elaboration diagnostics for this interface difference. If
the tool requires exact interface conformance, reconcile only the unused debug
ports (or use the matching I2C master revision) without changing the camera
register configuration.

## Verification before hardware programming

1. Compile all VHDL and confirm component binding to `camera_interface`, both
   PLLs and `HyperRAM_Memory_Interface_Top`.
2. Simulate packer order with four known bytes, then verify the resulting
   32-bit FIFO word and capture CRC.
3. Verify capture FIFO read-side level reaches eight before a write burst.
4. Verify each write command is followed by exactly eight words and the next
   command respects the configured spacing.
5. Confirm the generated HyperRAM IP returns eight `rd_data_valid` beats per
   read command, with the actual latency expected by the adapter.
6. Verify 320 read words are written into FIFO #2 before `line_ready_o` rises.
7. Stall `uart_tx_ready_i` deliberately and check that data and channel valid
   remain stable until each byte handshake.
8. Check R/G/B ordering, two pixels per word, 320 words per line and 480 lines.
9. Verify CRC equality, counters and `system_ok_o` only after `uart_tx_idle_i`.
10. Use GAO/ILA on the start detector, camera byte-valid, capture FIFO levels,
    writer state/address/beat, HyperRAM `cmd_en`/`cmd`/`rd_data_valid`, line
    handshake, output FIFO level, UART byte/valid/ready, CRCs and final status.

No claim of Gowin synthesis or board-level timing validation is made here. The
Gowin-generated PLL and HyperRAM IP files and their actual timing contract are
required for final compile/elaboration and hardware verification.
