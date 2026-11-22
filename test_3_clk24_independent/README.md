# Test 3 — Independent 24 MHz Synthetic Source and HyperRAM Write/Read

## Objective

Test 3 removes the camera pixel clock and all camera timing signals from the
capture/write data path. It checks whether a deterministic frame generated
inside the FPGA from the existing PLL-derived 24 MHz clock can be packed,
buffered, written to HyperRAM, read back, and sent to the PC.

This is a separate project alongside `test_2`. It does not replace Test 2.

## Clock and data architecture

```text
Tang Nano 4K 8 MHz oscillator
          |
          v
      Gowin PLLVR_1
          |
          +---- clk24 (24 MHz)
                    |
                    +--> synthetic byte generator
                    |       exactly 614,400 bytes
                    |
                    +--> RGB565 frame packer
                    |
                    +--> async FIFO write port (wr_clk = clk24)
                                  |
                                  | asynchronous clock-domain crossing
                                  v
                       FIFO read port (rd_clk = usr_clk)
                                  |
                                  v
                       HyperRAM write FSM (usr_clk)
                                  |
                                  v
                       HyperRAM IP / physical memory
                                  |
                                  v
                       unchanged readback + UART path
```

**Important clock-domain distinction:** data generation, packing, and the
capture FIFO write side run at 24 MHz. The HyperRAM command/write FSM remains
clocked by the generated HyperRAM IP's `usr_clk` (`clk_out`), because that
is the user-interface clock provided by this IP. It is not safe to clock the
IP command interface from an unrelated clock. The asynchronous FIFO is the
intentional CDC boundary between the 24 MHz producer and the HyperRAM user
interface.

## Operation

1. KEY2 resets the design.
2. Wait for HyperRAM PLL lock and `init_calib`.
3. Press KEY1 once.
4. The protocol controller sends the trigger stage and generates a start pulse
   synchronized into `clk24`.
5. The synthetic source emits one byte per 24 MHz cycle until exactly
   614,400 bytes have been produced. It then pulses frame-done.
6. The existing RGB565 packer produces 153,600 32-bit words.
7. The asynchronous FIFO crosses from `clk24` to `usr_clk`.
8. The existing HyperRAM writer, reader, line serializer, UART packet engine,
   and host protocol remain based on the Test 2 implementation.

No camera PCLK, VSYNC, HREF, SCCB, or pixel-data signal controls generation,
packing, FIFO writes, or capture completion. Legacy camera connector pins
are retained in the top-level port list for pinout compatibility only;
`cam_clk` is held low and the other camera inputs are unused.

## Synthetic pattern and expected values

The byte sequence is identical to Test 2:

`byte[index] = index[7:0] XOR index[15:8] XOR index[23:16] XOR index[31:24] XOR 0xA5`

- Frame: 640 × 480 RGB565
- Source bytes: 614,400
- Packed words: 153,600
- Pixels: 307,200
- HyperRAM bursts: 19,200 (8 words per burst)
- Expected capture CRC32: `0x81BD9BFE`
- CRC convention: MSB-first, polynomial `0x04C11DB7`, initial
  `0xFFFFFFFF`, no final XOR.

Because the source emits one byte every 24 MHz cycle, ideal generation time
is 614,400 / 24,000,000 = 25.6 ms, excluding start and completion pipeline
latency.

## Build

Open `TEST3_CLK24_INDEPENDENT_HYPERRAM.gprj` in Gowin EDA. The project
references the existing shared HyperRAM IP, PLL, FIFO, readout, UART, and
integrity-checker files under `../gowin_cameradrive/src/`. Clone/download the
whole repository; downloading only this directory will break those relative
source paths.

The same Tang Nano 4K top-level pin constraints are retained. The camera
signals remain present only as unused legacy ports. Do not interpret the
unused `cam_pclk` pin as a timing reference for this experiment.

## MATLAB receiver

Run:

```matlab
report = test3_receive_uart("/dev/ttyUSB0"); % Linux
% report = test3_receive_uart("COM5");       % Windows
```

Without an argument, the script lists available serial ports and prompts for
the numeric selection. It validates UART packet CRC-16, line sequence/count,
DONE telemetry, and the reconstructed RGB565 CRC. It saves
`test3_capture.png` and `test3_report.mat`.

## Interpretation

- Capture CRC differs from the expected pattern: inspect the 24 MHz source,
  start pulse, packer, or source-side FIFO write.
- Capture CRC equals expected, Writer CRC differs: inspect FIFO read/word
  loading and writer-side burst sequencing.
- Writer CRC equals capture CRC, read-ingress CRC differs: inspect HyperRAM
  command/data timing, address progression, read scheduling, and the IP
  interface.
- FPGA readback CRC is correct but MATLAB reports packet CRC failures or
  missing lines: investigate UART timing, packet framing, USB-UART reception,
  and host parser independently of HyperRAM.
- All FPGA CRCs/counts agree but host image CRC differs: inspect RGB888
  serialization and host RGB565 reconstruction.

## Validation status

This project is source-generated from Test 2. It has **not** yet been
compiled, synthesized, placed/routed, timing-analysed, programmed, or tested
on physical hardware. No claim is made that the RTL builds or that the
HyperRAM transfer passes until those steps are run in Gowin and on the board.
