# Design Notes — Camera to MATLAB UART Line Stream

## Data path
GC0308 -> camera interface -> RGB565 packer -> capture FIFO #1 -> HyperRAM write
-> HyperRAM line read -> async FIFO #2 -> RGB565-to-RGB888 serializer
-> UART stop-and-wait protocol -> MATLAB receiver.

Two RGB565 pixels are packed into each 32-bit HyperRAM word. UART payload is RGB888, three bytes per pixel, R-G-B order.

## Host protocol
- Host: START=0xC1, ACK=0x06, NACK=0x15.
- READY: A5 01 widthLo widthHi heightLo heightHi BPP format.
- LINE: A5 02 rowLo rowHi lengthLo lengthHi payload CRC_hi CRC_lo.
- DONE: A5 03 heightLo heightHi.
- CRC: CRC-16/CCITT-FALSE, init FFFF, polynomial 1021, no reflection/xorout. LINE CRC covers TYPE through payload; excludes SOF and CRC bytes.
- Camera mode: BPP=3, pixel format=1.
- MATLAB acknowledges READY, each valid LINE, and DONE.

## Sequencing implemented
1. UART RX decodes the complete START byte before the camera trigger.
2. START pulse crosses clk8 -> clk24 through a toggle synchronizer.
3. Protocol waits for complete capture and HyperRAM write completion before sending READY. Capture/write error and frame timeout produce ERROR.
4. Readout is enabled only after READY ACK and the first LINE header.
5. For each row, HyperRAM fills FIFO #2; serializer emits RGB888 bytes through protocol ready/valid.
6. Protocol waits for host ACK/NACK after the complete LINE packet. ACK advances the line reader; NACK or ACK timeout requests a reread of the same row.
7. Serializer checkpoints CRC and byte/word/pixel counters at row start. ACK commits the row count; NACK/timeout restores the checkpoint.
8. DONE is sent after the final row ACK and protocol DONE state is entered only after host ACK of DONE.
9. Final serializer statistics cross clk8 -> usr_clk as one bundled snapshot after protocol DONE, for the integrity checker.

## Clock domains
- clk8: UART RX, UART TX, protocol FSM, RGB serializer/FIFO #2 read side.
- clk24: camera configuration/control.
- cam_pclk: camera byte capture, RGB565 packer, FIFO #1 write side.
- usr_clk: HyperRAM write/read engines, FIFO #1 read side, FIFO #2 write side, integrity checker.
- Single events use `pulse_toggle_cdc`; readout enable and sticky status levels use two-flop synchronization; final multi-bit stats use `stable_bus_event_cdc`.

## Retry/address behavior
- A line contains `G_FRAME_WIDTH/2` 32-bit words and `C_BURSTS_PER_LINE` bursts.
- Reader address advances by the configured burst stride after each completed burst.
- On retry, reader restores:
  `G_BASE_ADDR + line_index * C_BURSTS_PER_LINE * G_BURST_ADDR_STRIDE`.
- Reader deasserts line_ready, waits for FIFO #2 to become empty, then reads the same line again.
- FIFO-drain wait is bounded by the configured read timeout; a stuck FIFO/CDC now raises reader error instead of hanging indefinitely.
- Reader increments line_index only on host ACK.

## Timeout configuration in top
- UART ACK timeout: 16,000,000 clk8 cycles = 2 s.
- Source timeout: 8,000,000 clk8 cycles = 1 s.
- Capture + HyperRAM frame timeout: 120,000,000 clk8 cycles = 15 s.
- Maximum line retries: 3.
These are initial design values and should be validated on the board.

## Important remaining engineering checks
- Verify generated Gowin HyperRAM IP command acceptance, address units, response cadence and read adapter behavior against the exact generated IP example.
- Verify actual camera output geometry/format and that camera PCLK timing matches the packer assumptions.
- Verify Gowin supports the selected project file paths and VHDL constructs.
- Check clock constraints for clk8, clk24, clk96, usr_clk and cam_pclk.
- Check UART physical pin constraints and USB-UART voltage/logic compatibility.
