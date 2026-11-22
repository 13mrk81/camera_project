# Test 3 — Independent 24 MHz Synthetic Data to HyperRAM

## Purpose

This experiment removes the camera pixel-clock domain from the capture path.
The synthetic byte stream, RGB565 packing, and capture-FIFO write side are
clocked by the board-derived **24 MHz PLL output**. No camera PCLK, VSYNC,
HREF, DVP data, SCCB, or camera initialization is required.

The existing HyperRAM generated IP, HyperRAM user-clock writer, read adapter,
output FIFO, line serializer, UART protocol, and host reconstruction remain
the same as Test 2.

## Clock architecture

```text
8 MHz board oscillator
  |-- Gowin_PLLVR_1 --> 24 MHz clk24
  |                     |--> synthetic byte generator
  |                     |--> RGB565 frame packer
  |                     +--> capture FIFO write port
  |
  +-- Gowin_PLLVR --> 96 MHz memory clock
                         |
                   HyperRAM IP user clock (usr_clk)
                         |--> capture FIFO read / burst writer
                         +--> HyperRAM reader / output FIFO / serializer
                                      |
                                    8 MHz UART
```

The capture FIFO is a true dual-clock asynchronous FIFO:
- Write clock: `clk24` (24 MHz).
- Read clock: HyperRAM IP `usr_clk`.
- Write reset: synchronized `clk24_rst_n`.
- Read reset: synchronized `usr_rst_n`.

The only start event crossing into clk24 is synchronized from the 8 MHz
protocol controller using the existing pulse-toggle CDC. Capture statistics
cross from clk24 to usr_clk using the existing stable-bus event CDC.
The generator never samples or uses cam_pclk.

## Synthetic payload and expected counts

After KEY1 is pressed and the protocol starts capture, the source emits one
byte on every 24 MHz cycle until exactly 614,400 bytes have been produced.

For 640x480 RGB565:
- Total bytes: 614,400
- Byte rate during active generation: 24 MB/s
- Ideal generation time: 25.6 ms
- Packed 32-bit words: 153,600
- Pixels: 307,200
- Words per line: 320
- HyperRAM bursts (8 words/burst): 19,200
- Bursts per line: 40

Pattern:
`byte[index] = index[7:0] XOR index[15:8] XOR index[23:16] XOR index[31:24] XOR 0xA5`

Expected capture CRC32: `0x81BD9BFE` (MSB-first CRC-32/04C11DB7,
initial `0xFFFFFFFF`, no final XOR).

The source pulses frame_done one full clk24 cycle after the final valid byte,
allowing the packer to consume that last byte before checking completion.

## What changed compared with Test 2

| Item | Test 2 | Test 3 |
|---|---|---|
| Payload generator clock | Camera PCLK | 24 MHz PLL output |
| Byte-valid source | Real camera qualification | One byte every clk24 cycle |
| Camera dependency | Required | None |
| Packer clock | Camera PCLK | 24 MHz |
| Capture FIFO write clock | Camera PCLK | 24 MHz |
| Capture FIFO read clock | HyperRAM usr_clk | HyperRAM usr_clk |
| HyperRAM writer | usr_clk | usr_clk |

HyperRAM IP, writer FSM, burst buffering, addressing, read adapter, line
reader, serializer, UART protocol and telemetry are intentionally unchanged.

The legacy camera connector pins remain in the top-level interface and CST
only for pinout compatibility. They are unused; cam_clk is held low.

## Build and run

1. Clone/pull the complete repository; the Gowin project references shared
   dependencies under `../gowin_cameradrive/src/`.
2. Open `TEST3_CLK24_INDEPENDENT_HYPERRAM.gprj` in Gowin EDA.
3. Confirm the target device is Tang Nano 4K / GW1NSR-LV4CQN48PC6/I5.
4. Run synthesis, place-and-route, and timing analysis.
5. Program the board.
6. Connect FPGA UART TX to USB-UART RX and common ground.
7. In MATLAB run `report = test3_receive_uart("/dev/ttyUSB0");`.
8. Press KEY1 once.

Camera PCLK may be disconnected or held static; it must not affect the test.

## Pass criteria

- 614,400 source bytes and 153,600 packed words.
- Capture CRC, writer CRC, read-ingress CRC, and host reconstructed CRC agree.
- All 480 line packets pass packet CRC and sequence checks.
- DONE telemetry reports SYSTEM_OK (bit 13 set) and bits 0–12 clear.

## Interpretation

If Test 3 passes while Test 2 fails, camera PCLK/capture-domain timing or
its CDC interaction becomes a strong suspect; this does not prove the sensor
is defective.

If capture CRC and writer CRC agree but read-ingress CRC differs, investigate
the writer/IP command-data timing, addressing, HyperRAM transactions, read
scheduling, and read response handling.

If capture CRC differs from the expected pattern, investigate the clk24
source, packer, and capture-side counters first.

UART packet CRC failures or missing line packets are a separate host/serial/
protocol issue and do not by themselves identify a HyperRAM fault.

## Validation status

This is a source-level implementation. It has NOT been compiled in Gowin,
simulated, synthesized, placed/routed, timing-closed, programmed, or tested
on physical hardware in this session. The inherited 24 MHz PLL configuration
and all clock relationships must be confirmed in Gowin reports before
drawing hardware conclusions.
