# Design Notes — Camera to MATLAB UART Line Stream

## Intended data path
GC0308 -> camera interface -> RGB565 packer -> capture FIFO #1 -> HyperRAM write
-> HyperRAM line read -> async FIFO #2 -> RGB565 to RGB888 serializer
-> stop-and-wait UART protocol -> MATLAB receiver.

Two RGB565 pixels are packed into each 32-bit HyperRAM word. The UART payload is RGB888, three bytes per pixel, in R-G-B order.

## Host protocol (reused from projects/uart_based_protocol)
- Host commands: START=0xC1, ACK=0x06, NACK=0x15.
- FPGA READY: A5 01 widthLo widthHi heightLo heightHi BPP format.
- FPGA LINE: A5 02 rowLo rowHi lengthLo lengthHi payload CRC_hi CRC_lo.
- FPGA DONE: A5 03 heightLo heightHi.
- CRC: CRC-16/CCITT-FALSE, init FFFF, polynomial 1021, no reflection/xorout; covers TYPE through payload, excluding SOF and CRC bytes.
- RGB888 uses BPP=3 and pixel format=1.
- MATLAB acknowledges READY, each valid LINE, and DONE.

## Required sequencing
1. Decode a complete 0xC1 UART byte before triggering capture.
2. Wait until the complete frame has been written to HyperRAM and validated before sending READY.
3. Do not read/stream a line before the host has accepted READY.
4. For each line, read the full row into FIFO #2, transmit LINE header + RGB888 payload + CRC, then wait for host ACK/NACK.
5. Advance HyperRAM reader and line index only after ACK.
6. On NACK or ACK timeout, discard any remaining FIFO content, reread the same row from its base address, and retransmit the same row index.
7. Count CRC/bytes/pixels/lines only once per acknowledged line. DONE is sent only after the final row ACK and is itself acknowledged.

## Clock domains to preserve
- clk8: UART RX, UART TX, protocol FSM.
- clk24/cam_pclk: camera configuration and pixel capture.
- usr_clk: HyperRAM writer/reader and FIFO #2 write side.
- clk8: FIFO #2 read side / RGB serializer if possible, so byte stream and protocol are synchronous.
- Use pulse/toggle CDC for single events. Use bundled-data/event CDC for multi-bit snapshots. Never independently synchronize a multi-bit counter bus.

## Critical implementation cautions
- Check UART transmitter handshake: its `data_ready_o` means idle; a byte is accepted only on valid AND ready. The protocol must hold valid/data stable until accepted.
- The current UART protocol source has a READY-ACK gate and retries READY; its frame-available condition must be adapted to wait for capture completion.
- Serializer must not assert a line-consumed signal that advances the reader before host ACK.
- On retry, restore per-line accounting checkpoint and reset the serializer's per-line word/pixel state.
- MATLAB receiver has a likely variable typo to fix: `nackByte` is assigned twice; `ackByte` remains defined as 0x06, but ensure the second assignment is intended to nackByte.
- Existing MATLAB receiver has fixed payload read length based on READY dimensions; malformed length fields are therefore not independently framing-safe. Keep current FPGA packet fixed-size unless protocol is redesigned consistently on both ends.
