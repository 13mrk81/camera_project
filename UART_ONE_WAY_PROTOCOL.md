# One-way UART Protocol — GC0308 RGB888 Stream

## 1. Link contract

The link is FPGA TX -> USB-UART adapter RX -> MATLAB only. The adapter TX wire is not connected to the FPGA. MATLAB must never send START, ACK, NACK, or any other byte.

A user presses the Tang Nano 4K onboard KEY1 button. The FPGA synchronizes and debounces the active-low input for 20 ms, then starts the one-shot capture. MATLAB opens the serial port first and passively waits for the trigger log.

UART configuration is 8 data bits, no parity, one stop bit (8N1), with the transmitter configured for 115200 baud from an 8 MHz clock. The UART divider is 69 clocks/bit, giving an actual nominal baud of approximately 115942 baud (+0.64% relative to 115200). Confirm the USB-UART adapter tolerates this clock-derived rate on the board.

The FPGA waits 20 ms between complete packets. Bytes within a packet are transmitted contiguously at the UART rate.

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
| 0x04 | Camera configuration is running | 0x00 |
| 0x05 | Frame capture and HyperRAM write are running | 0x00 |
| 0x03 | Frame capture and HyperRAM write completed | 0x00 |

### 0x11 — READY

Payload is exactly six bytes:

width_lo, width_hi, height_lo, height_hi, bytes_per_pixel, pixel_format

For this project, bytes_per_pixel = 3 and pixel_format = 1 (RGB888). The default geometry is 640 x 480.

### 0x20 — LINE

- SEQUENCE is the zero-based row index.
- PAYLOAD_LENGTH must equal width * 3.
- Pixels are serialized from left to right.
- Every pixel is exactly three consecutive bytes: R, then G, then B.
- Thus a 640-pixel row is R(0),G(0),B(0), R(1),G(1),B(1), ... R(639),G(639),B(639).
- CRC16 is computed independently for every line.

MATLAB stores a row only after its packet CRC and row length pass validation. Row sequence is used as the matrix row index, not the order in which bytes happen to arrive.

### 0x30 — DONE

Sequence equals the frame height. Payload is exactly 16 bytes:

| Payload bytes | Field | Encoding |
|---:|---|---|
| 0..1 | Height | uint16 little-endian |
| 2..3 | Lines emitted by serializer | uint16 little-endian |
| 4..7 | Pixels emitted | uint32 little-endian |
| 8..11 | RGB UART payload bytes emitted | uint32 little-endian |
| 12..15 | Raw RGB565 HyperRAM readback CRC32 | uint32 little-endian |

DONE is sent only after the final LINE packet is physically complete, its local readout acknowledgement has been processed by the serializer, and the serializer reports completion. The 20 ms packet gap is observed between the final LINE and DONE.

### 0x7F — ERROR

Payload is exactly 16 bytes: [error_code, detail, cfg_state, cfg_error, reg_addr, reg_data, device_addr, chip_id, ack_count, nack, init_index, verify_index, i2c_sequence, i2c_state, last_readback, rw].

| Error code | Meaning |
|---:|---|
| 0x01 | Camera configuration failed |
| 0x02 | Camera capture or HyperRAM write failed |
| 0x03 | Camera configuration/capture stage timeout |
| 0x04 | HyperRAM readout or RGB serializer error |
| 0x05 | RGB line source starvation timeout |

For a truncated LINE packet, the FPGA waits for the UART transmitter to return to idle, then waits a full 20 ms before sending ERROR. MATLAB scans for a later complete CRC-valid SOF packet, so it can abandon the partial row and still decode the ERROR packet.

## 4. Timing, throughput, and buffering

At 8 MHz, the UART divider is 69 clocks per bit. With 8N1, one byte occupies 10 bit periods, or about 86.25 microseconds.

For 640 x 480 RGB888:
- RGB payload: 1,920 bytes per row and 921,600 bytes per frame.
- LINE packet: 9 + 1,920 = 1,929 bytes per row.
- All LINE packets: 925,920 bytes.
- STAGE, READY, and DONE packets add another 73 bytes.
- UART wire time is approximately 79.87 s at the divider-derived baud.
- 20 ms quiet gaps between the 484 packet boundaries add 9.68 s.
- Estimated total transfer time is approximately 89.55 s, excluding camera capture and HyperRAM write time.

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

The MATLAB script:
1. Opens the serial port and sends no bytes.
2. Waits indefinitely for STAGE TRIGGER_ACCEPTED.
3. Tracks camera configuration, frame storage, READY, line reception, DONE, and ERROR states.
4. Validates the shared packet CRC before accepting a packet.
5. Maps each LINE packet to img(sequence+1,:,:) and deinterleaves RGB triplets.
6. Uses a sliding SOF search and candidate CRC validation to resynchronize after a partial/corrupt packet.
7. Checks DONE counters and that every expected row arrived before marking the frame complete.
8. Saves the received image, row-validity map, and link statistics.

No ACK/NACK or other host-to-FPGA command is part of this protocol.


## GC0308 UART diagnostics extension
The one-way UART stream reports STAGE code `0x04` when camera configuration starts and STAGE code `0x02` when configuration and its register readback pass. STAGE `0x03` continues to mean frame stored in HyperRAM. ERROR packets now carry a 16-byte payload: the original generic error code/detail plus camera FSM state/error, register/data, SCCB address, chip ID, ACK/NACK count, init/verify indices, I2C sequence/state, last readback and R/W direction. MATLAB decodes and prints these fields. Packet envelope and CRC framing are unchanged; the host remains receive-only.
