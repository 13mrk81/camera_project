# Design Notes — One-way Camera to MATLAB Gray8 Stream

## Data path

GC0308 DVP -> camera configuration/capture logic -> RGB565 packer -> asynchronous capture FIFO #1 -> HyperRAM write -> HyperRAM line reader -> asynchronous output FIFO #2 -> RGB565-to-Gray8 serializer -> packet/CRC engine -> UART TX -> USB-UART adapter -> MATLAB.

Two RGB565 pixels are stored per 32-bit HyperRAM word. HyperRAM retains the original RGB565 frame. During readout, the serializer converts each pixel to BT.601 Gray8 luma and emits one byte per pixel. Rows are numbered from zero.

## Trigger and link direction

- Tang Nano 4K onboard KEY1/S1 is the trigger input, active-low on FPGA pin 14.
- The input is two-flop synchronized, debounced for 20 ms in clk8, and converted to one pulse on a stable press.
- The pulse crosses clk8 -> clk24 through pulse_toggle_cdc and starts the camera configuration sequence.
- UART is strictly one-way: FPGA TX (pin 32) -> USB-UART adapter RX. Adapter TX is not wired to the FPGA. MATLAB never writes a byte.
- UART uses 8N1, 8 MHz source clock and divider 69 (about 115942 baud). Complete packets have a 50 ms inter-packet quiet interval.

## Packet protocol

See UART_ONE_WAY_PROTOCOL.md for the normative field definitions, CRC coverage, payload order, stage and error codes, throughput estimate, and MATLAB recovery behavior.

Packet format: A5 5A TYPE SEQ_LO SEQ_HI LEN_LO LEN_HI PAYLOAD CRC_HI CRC_LO.

Types:
- 0x10 STAGE: trigger accepted, camera configured, frame stored.
- 0x11 READY: geometry, BPP=1 and format=3 (Gray8).
- 0x20 LINE: zero-based row sequence and one Gray8 byte per pixel.
- 0x30 DONE: frame/serializer counters and Gray8 readback CRC32.
- 0x7F ERROR: error code and detail.

CRC16 is CRC-16/CCITT-FALSE over TYPE, sequence, length, and payload. CRC is emitted high byte first. Each LINE has an independent CRC.

There is no host ACK, NACK, or retransmission. CRC and sequence numbers detect corruption or missing rows; they cannot repair them. A partial LINE is abandoned by MATLAB when it finds a subsequent complete packet with a valid CRC. The FPGA waits for UART idle and a 50 ms quiet interval before sending the corresponding ERROR packet.

## Sequencing

1. KEY1 press produces one debounced trigger.
2. FPGA emits STAGE TRIGGER_ACCEPTED and starts camera setup through clk8-to-clk24 event CDC.
3. After camera setup and RGB565 register verification, FPGA emits STAGE CAMERA_CONFIGURED.
4. Capture and HyperRAM write proceed. Error or timeout produces ERROR; successful write emits STAGE FRAME_STORED.
5. FPGA emits READY. After the 50 ms gap it starts the first LINE packet and enables the sticky HyperRAM readout-start level.
6. The line reader reads one complete row into FIFO #2. The serializer supplies original RGB565 bytes only when the packet engine asserts source-ready.
7. Packet engine sends payload and per-row CRC16. Completion is not declared until CRC low byte's UART stop bit is complete and TX returns to idle.
8. The protocol then generates a local one-cycle line acknowledgement. It crosses to usr_clk through a toggle CDC and advances the HyperRAM reader; it also advances the clk8 serializer. This is internal hardware flow control, never a host ACK.
9. The FPGA waits 50 ms and then sends the next row. After the final row it waits for serializer completion, observes the packet gap, and emits DONE.
10. A stable 176-bit statistics bundle crosses clk8 -> usr_clk after DONE for the existing frame-integrity checker.

## Data integrity and buffering

- Output FIFO #2 depth is 512 32-bit words by default; a 640-pixel row uses 320 words. The existing static assertion requires FIFO depth to be at least one complete row.
- The line reader fills the row before asserting line-ready and waits for the local line acknowledgement before advancing.
- UART ready/valid holds source bytes until accepted. No serializer byte is consumed while the UART byte channel is not ready.
- Source starvation is bounded by a 4 s timeout. Readout/serializer errors also terminate the row and produce an ERROR packet after a safe UART-idle interval.
- A 50 ms packet gap is much longer than UART byte time and is applied between all complete packets, including final LINE -> DONE. Error recovery after a partial LINE uses the same quiet interval.
- CRC is detection only. With no reverse channel, no line retransmission is possible.

## Clock domains and CDC

- clk8: KEY1 synchronizer/debounce, UART TX, protocol controller, RGB serializer/FIFO #2 read side.
- clk24: camera configuration/control.
- cam_pclk: DVP sampling, RGB565 packer, FIFO #1 write side.
- usr_clk: HyperRAM read/write engines, FIFO #1 read side, FIFO #2 write side, integrity checker.
- KEY1 crosses only through clk8 synchronizer flops; the resulting pulse crosses clk8 -> clk24 through pulse_toggle_cdc.
- camera configuration done/pass: clk24 -> clk8 two-flop synchronizers.
- reader error: usr_clk -> clk8 two-flop synchronizer; serializer error is already clk8.
- local line-complete pulse: clk8 -> usr_clk toggle synchronizer.
- async FIFOs use Gray-coded pointers and two-flop pointer synchronizers.
- final statistics use the existing stable-bus event CDC.

## Known engineering limits and sign-off items

- The generated Gowin HyperRAM IP command acceptance, address units, response cadence and read adapter behavior still require confirmation against the generated example and board measurement.
- Camera DVP geometry and PCLK sampling assumptions require hardware verification.
- The UART baud divider is 69 clocks/bit (about 115942 baud), not exactly 115200; verify adapter tolerance with a scope/logic analyzer.
- The host has no reverse backpressure. A cable disconnect or PC/driver overflow results in missing data detectable by CRC/sequence/DONE, but not retransmittable.
- Reset release remains unverified: top-level rst_n is held high internally, while ip_rst_n is PLL-derived in clk24 and used in other domains. Add domain-synchronous reset release or a board reset before sign-off.
- Check generated IP binding, clock constraints, Gowin VHDL elaboration, timing closure, UART waveform, trigger pin voltage, and full board capture.
