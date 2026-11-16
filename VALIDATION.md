# Validation Log — Camera MATLAB UART Integration

## 2026-11-16 — Baseline and implementation checks
- GitHub connector access recovered after transient internal errors.
- Inspected original top, line reader, readout wrapper, RGB565 serializer, Gowin project, UART RX/TX, existing protocol, and MATLAB receiver.
- Confirmed 640x480 default geometry in the top and existing MATLAB RGB888 support.
- Confirmed UART RX/TX default to 8 MHz / 115200 baud / 8N1.
- Added adapted camera protocol, CDC pulse synchronizer, line ACK/NACK control, serializer rollback, top-level UART integration, project file entries and MATLAB receiver copy.
- Static named-port consistency checks passed for the new top-level instances:
  - camera_uart_frame_protocol (20/20 ports)
  - pulse_toggle_cdc instances (6/6 each)
  - hyperram_line_readout (39/39)
  - uart_rx (6/6)
  - uart_tx (6/6)
  - stable_bus_event_cdc (8/8)
- Static named-port consistency checks passed inside hyperram_line_readout:
  - hyperram_line_reader (22/22)
  - rgb565_line_serializer (27/27)
  - async_fifo_32 (12/12)
- Confirmed the Gowin project file list contains the new camera protocol, pulse CDC, UART RX and UART TX sources.
- Re-ran static checks after integration: no duplicate signal declarations or duplicate attribute specifications in modified VHDL files; top-level and readout-wrapper named port associations match their entity declarations.
- Confirmed retry pulse is emitted only when the retry budget permits an actual retransmission.
- Updated MATLAB startup parsing to recognize an FPGA ERROR packet before READY.
- Confirmed feature branch comparison: 29 commits ahead of main, 0 behind. No main-branch merge was performed.

## 2026-11-16 — Final source review
- Re-reviewed the current feature-branch versions of the top-level integration, protocol FSM, UART RX/TX, HyperRAM reader/adapter, output FIFO wrapper, RGB565 serializer/packer, CDC blocks, MATLAB receiver and Gowin project file.
- Confirmed protocol CRC coverage matches MATLAB: TYPE + row index + payload length + payload; SOF and transmitted CRC bytes are excluded.
- Confirmed RGB565 word order is pixel 0 in bits 31:16 and pixel 1 in bits 15:0; serializer emits R, G, B for each pixel.
- Confirmed ACK advances both protocol and memory reader by one line; NACK/ACK timeout requests the same line again and serializer rolls back its per-line counters/CRC.
- Added a bounded timeout while waiting for output FIFO #2 to become empty before reusing it.
- Corrected stale top-level comments that described the old falling-edge-only UART trigger and unused UART TX.
- Current GitHub comparison remains 31 commits ahead of main and 0 behind. No main-branch changes or merge.

## Not run — do not treat as passed
- No VHDL compile or elaboration: no GHDL/NVC/Gowin compiler executable available in this environment.
- No VHDL simulation.
- No Gowin synthesis, timing analysis, or bitstream generation.
- No MATLAB execution or serial-port test.
- No Tang Nano 4K / GC0308 / HyperRAM board test.

## Next validation sequence
1. Open `gowin_cameradrive/HYPER_RAM_CONTROL.gprj` in Gowin EDA and resolve analysis/elaboration errors.
2. Simulate UART START and verify exactly one camera trigger pulse.
3. Simulate delayed frame write completion; ensure READY is not emitted early.
4. Simulate one valid row and ACK; verify reader advances exactly one row.
5. Simulate NACK and ACK timeout; verify the same row is reread and counters/CRC are restored.
6. Simulate final row ACK and DONE ACK; verify integrity checker sees exactly width*height pixels and width*height*3 payload bytes.
7. Compare received MATLAB RGB888 image with a known pattern and test on the board.
