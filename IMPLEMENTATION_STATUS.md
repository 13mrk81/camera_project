# Implementation Status — MATLAB Line Stream

Last updated: 2026-11-16

## Repository safety
- Working branch: `feature/matlab-line-stream`
- Base branch: `main`
- All implementation commits must target this feature branch only.
- Do not merge or modify `main` without explicit user approval.

## Baseline inspected
The feature branch is currently the unmodified baseline for the camera readout integration. The following files were fetched from this branch and inspected:
- `gowin_cameradrive/src/Camera_HyperRAM_OneFrame.vhd`
- `gowin_cameradrive/src/hyperram_line_reader.vhd`
- `gowin_cameradrive/src/hyperram_line_readout.vhd`
- `gowin_cameradrive/src/rgb565_line_serializer.vhd`
- `gowin_cameradrive/HYPER_RAM_CONTROL.gprj`
- `projects/uart_based_protocol/src/uart_frame_protocol.vhd`
- `projects/uart_based_protocol/src/uart_rx.vhd`
- `projects/uart_based_protocol/src/uart_tx.vhd`
- `projects/uart_based_protocol/src/matlab_uart_frame_receiver.m`
- `projects/uart_based_protocol/src/UART_Protocol_Test_Top.vhd`

## Confirmed current behavior / defects
1. Top-level camera trigger is driven by `falling_edge_one_shot` on raw UART RX. It responds to the UART start bit, not a decoded START byte (0xC1).
2. UART TX is not connected to a physical UART transmitter; top-level UART TX is held idle high.
3. Existing `uart_frame_protocol` is reusable, but currently waits for `frame_available_i` before accepting START and has no capture-completion wait state.
4. Existing line reader advances when `line_consumed_i` is asserted by the serializer. This is not host ACK.
5. Existing serializer commits counters and line completion as soon as it finishes sending bytes; it has no NACK/timeout rollback.
6. Existing MATLAB receiver already defines READY/LINE/DONE packets, RGB888 support, CRC-16/CCITT-FALSE, ACK/NACK and DONE acknowledgement.
7. The top currently clocks the readout serializer with HyperRAM `usr_clk`, while UART protocol/RX/TX are designed for the 8 MHz clock. Integration must explicitly establish the UART clock domain and CDC.

## Work plan
- [x] Reconnect to GitHub and inspect the current branch baseline.
- [x] Record this checkpoint in the feature branch.
- [ ] Add UART RX/TX and protocol to the Gowin project, adapted for capture-start / capture-complete sequencing.
- [ ] Add robust clock-domain event crossings for camera trigger and line ACK/NACK.
- [ ] Make line reader advance only on decoded host ACK; retry same line on NACK/ACK timeout.
- [ ] Make serializer produce protocol payload bytes and roll back accounting on retransmission.
- [ ] Integrate top-level UART and READY/LINE/DONE flow.
- [ ] Add MATLAB script for the integrated 640x480 RGB888 camera stream.
- [ ] Static checks, VHDL compile/simulation where available, project file-list consistency, and protocol review.
- [ ] Update this file with exact test results and remaining limitations.

## Validation policy
Never mark a test as passed unless it was actually run. Gowin synthesis/timing and physical-board behavior must remain explicitly unverified unless performed on the target tools/hardware.
