# One-way UART Protocol — GC0308 Gray8 Stream

## 1. Link contract

The link is FPGA TX -> USB-UART adapter RX -> MATLAB only. The adapter TX wire is not connected to the FPGA. MATLAB must never send START, ACK, NACK, or any other byte.

A user presses the Tang Nano 4K onboard KEY1 button. The FPGA synchronizes and debounces the active-low input for 20 ms, then starts the one-shot capture. MATLAB opens the serial port first and passively waits for the trigger log.

UART configuration is 8 data bits, no parity, one stop bit (8N1), with the transmitter configured for 115200 baud from an 8 MHz clock. The UART divider is 69 clocks/bit, giving an actual nominal baud of approximately 115942 baud (+0.64% relative to 115200). Confirm the USB-UART adapter tolerates this clock-derived rate on the board.

The FPGA waits 50 ms between complete packets. The UART TX also inserts a 25 us idle-high interval after every byte (including packet-final bytes) before accepting the next byte. This is configurable and is currently 200 clk8 cycles at 8 MHz.

## 2. Packet framing

All multi-byte sequence, length, image geometry, and statistics fields are little-endian.

| Offset | Size | Field |
|---:|---:|---|
| 0 | 1 | SOF0 = 0xA5 |
| 1 | 1 | SOF1 = 0x5A |
| 2 | 1 | TYPE |
| 3 | 2 | SEQUENCE, little-endian |
| 5 | 2 | PAYLOAD_LENGTH, little-endian |
| 7 | N | PAYLOAD |
| 7+N | 2 | CRC16, high byte first |

The CRC is CRC-16/CCITT-FALSE: polynomial 0x1021, initial value 0xFFFF, input/output not reflected, XOR-out 0x0000. It covers TYPE + SEQUENCE + PAYLOAD_LENGTH + PAYLOAD; both SOF bytes and the two transmitted CRC bytes are excluded. The standard check value for ASCII 123456789 is 0x29B1.

The minimum complete packet length is 9 bytes; total packet length is 9 + PAYLOAD_LENGTH.

## 3. Packet types

### 0x10 — STAGE

Payload is exactly two bytes: [stage_code, detail]. Sequence is zero.

| Stage code | Meaning | Detail on success |
|---:|---|---:|
| 0x01 | KEY1 trigger accepted; camera initialization started | 0x00 |
| 0x02 | Camera configuration finished and RGB565 mode verified | 0x00 |
| 0x03 | Frame capture and HyperRAM write completed | 0x00 |

### 0x11 — READY

Payload is exactly six bytes:

width_lo, width_hi, height_lo, height_hi, bytes_per_pixel, pixel_format

For this project, bytes_per_pixel = 1 and pixel_format = 3 (Gray8 BT.601 luma derived from RGB565). The default geometry is 640 x 480.

### 0x20 — LINE

- SEQUENCE is the zero-based row index.
- PAYLOAD_LENGTH must equal width.
- Gray8 samples are serialized left to right. Each sample is BT.601 luma computed from the corresponding RGB565 pixel read from HyperRAM.
- Each pixel contributes exactly one Gray8 byte.
- The HyperRAM contents remain RGB565; grayscale conversion occurs only in the UART readout serializer.
- CRC16 is computed independently for every line.

MATLAB stores a row only after its packet CRC and row length pass validation. Row sequence is used as the matrix row index, not the order in which bytes happen to arrive.

### 0x30 — DONE

Sequence equals the frame height. Payload is exactly 16 bytes:

| Payload bytes | Field | Encoding |
|---:|---|---|
| 0..1 | Height | uint16 little-endian |
| 2..3 | Lines emitted by serializer | uint16 little-endian |
| 4..7 | Pixels emitted | uint32 little-endian |
| 8..11 | Gray8 UART payload bytes emitted | uint32 little-endian |
| 12..15 | Gray8 readback CRC32 | uint32 little-endian |

DONE is sent only after the final LINE packet is physically complete, its local readout acknowledgement has been processed by the serializer, and the serializer reports completion. The 50 ms packet gap is observed between the final LINE and DONE.

### 0x7F — ERROR

Payload is exactly [error_code, detail].

| Error code | Meaning |
|---:|---|
| 0x01 | Camera configuration failed |
| 0x02 | Camera capture or HyperRAM write failed |
| 0x03 | Camera configuration/capture stage timeout |
| 0x04 | HyperRAM readout or RGB serializer error |
| 0x05 | RGB line source starvation timeout |

For a truncated LINE packet, the FPGA waits for the UART transmitter to return to idle, then waits a full 50 ms before sending ERROR. MATLAB scans for a later complete CRC-valid SOF packet, so it can abandon the partial row and still decode the ERROR packet.

## 4. Timing, throughput, and buffering

At 8 MHz, the UART divider is 69 clocks per bit. With 8N1, one byte occupies 10 bit periods, or about 86.25 microseconds. The configured 25 us inter-byte idle interval makes the byte slot approximately 111.25 us; the UART bit rate itself remains approximately 115942 baud.

For 640 x 480 Gray8:
- Gray8 payload: 640 bytes per row and 307,200 bytes per frame.
- LINE packet: 9 + 640 = 649 bytes per row.
- All LINE packets: 311,520 bytes.
- STAGE, READY, and DONE packets add another 73 bytes.
- UART wire time without inter-byte gaps is approximately 26.88 s at the divider-derived baud.
- The 25 us inter-byte gaps add approximately 7.79 s for 311,593 transmitted bytes.
- 50 ms quiet gaps between the 484 packet boundaries add 24.2 s.
- Estimated total transfer time is approximately 59 s, excluding camera capture and HyperRAM write time.

The second asynchronous FIFO has 512 32-bit entries by default. One 640-pixel row requires 320 32-bit RGB565 words, so the FIFO can hold one full row with 192 entries of margin. The reader fills one complete row before setting line-ready. The serializer then drains that row through the UART ready/valid interface. The next row is not read until the current row's LINE packet has fully left the UART and the local acknowledgement crosses to the HyperRAM clock domain.

This provides bounded, line-level flow control without depending on MATLAB scheduling. It does not create end-to-end backpressure: a disconnected cable or host-side driver overflow cannot be repaired because there is no reverse channel. Per-line CRC and row sequence detect corruption or missing rows; they do not retransmit them.

## 5. Clock-domain crossings

- KEY1 passes through two clk8 synchronizer flops before debounce and edge detection.
- The one-cycle trigger event crosses clk8 -> clk24 through pulse_toggle_cdc.
- Camera configuration done/pass levels cross clk24 -> clk8 through two-flop synchronizers.
- Reader error crosses usr_clk -> clk8 through two-flop synchronizers. Serializer error is already in clk8.
- Per-line local completion crosses clk8 -> usr_clk through pulse_toggle_cdc.
- FIFO #1 and FIFO #2 use Gray-coded asynchronous read/write pointers with two-flop synchronizers.
- Final serializer statistics cross clk8 -> usr_clk as a stable bundled-data event after DONE.

Reset release remains a separate sign-off item: the top currently holds rst_n high internally, and PLL-derived ip_rst_n is consumed in more than one clock domain. Domain-safe reset release/power-up behavior must be reviewed in Gowin and on hardware.

## 6. MATLAB receiver behavior

The MATLAB receiver uses the modern `serialport` API and lets MATLAB manage the driver receive queue. It accumulates incoming chunks in a bounded packet parser, validates each packet CRC16 as soon as the complete packet arrives, and only then copies a LINE payload into the preallocated Gray8 frame matrix. The FPGA inserts a 50 ms quiet interval after each complete packet to provide host-side processing margin.

The MATLAB script:
1. Opens the serial port and sends no bytes.
2. Waits indefinitely for STAGE TRIGGER_ACCEPTED.
3. Tracks camera configuration, frame storage, READY, line reception, DONE, and ERROR states.
4. Validates the shared packet CRC before accepting a packet.
5. Stores each LINE payload as raw bytes and reconstructs uint16 RGB565 words using the documented MSB-first wire order.
6. Uses a sliding SOF search and candidate CRC validation to resynchronize after a partial/corrupt packet.
7. Checks DONE counters and that every expected row arrived before marking the frame complete.
8. Saves the Gray8 frame, row-validity map, CRC results, and link statistics.

No ACK/NACK or other host-to-FPGA command is part of this protocol.
