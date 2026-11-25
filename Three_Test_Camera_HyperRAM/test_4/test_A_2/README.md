# Test A_2 — GC0308 Configuration + First-HSYNC Synthetic HyperRAM Test

## Purpose

Test A_2 preserves the Test A_1 synthetic RGB565 pattern, HyperRAM write/read
path, one-way UART packet protocol, and MATLAB validation, while adding real
GC0308 SCCB configuration and register readback verification.

## Clocking

- The board's 8 MHz oscillator is used only as the input reference to the PLL
  that generates 24 MHz.
- SCCB, HSYNC synchronization/detection, synthetic generation, packing,
  UART TX and UART protocol use 24 MHz.
- The second PLL generates 96 MHz for the HyperRAM memory clock.
- The HyperRAM IP user clock remains the clock returned by the generated IP.
- Sensor PCLK is not used. The unused DVP capture side inside the reused camera
  controller is parked on 24 MHz with VSYNC inactive and pixel data tied low.

## Camera configuration

After PLL stabilization, FPGA starts the GC0308 configuration sequence.
The SCCB controller checks the GC0308 chip ID, write ACK/NACK, and reads back
the stable mode registers, including Page 0 registers 0x25, 0x26 and 0x28.
It then explicitly reads Page 0 register 0x24 and requires 0xA6 (RGB565).
Configuration pass is asserted only after these checks succeed.

The UART protocol reports the CRC16-protected STAGE packet code 0x02/detail
0x01 as CAMERA_CONFIG_OK. A failed configuration produces an ERROR packet and
does not enable the synthetic generator.

## First-HSYNC one-shot

After successful configuration, the physical HSYNC input is synchronized
through two flip-flops into 24 MHz. Its first active-high rising edge emits
one single-cycle start pulse. A latch prevents later HSYNC edges from
restarting the generator. The configured polarity is verified by register
0x26 = 0x03.

## Data path

Synthetic RGB565 pattern -> RGB565 packer -> asynchronous FIFO -> HyperRAM
write -> HyperRAM readback -> RGB888 line serializer -> UART packets -> MATLAB.

The synthetic source does not consume camera DVP data, sensor PCLK or VSYNC.

## Host validation

Run `host/testA2_receive_uart.m` in MATLAB. It retains the A_1 packet CRC16,
sequence/line validation, RGB888-to-RGB565 reconstruction, expected pattern
comparison, CRC32 chain, DONE telemetry and report/image generation. It also
requires the CAMERA_CONFIG_OK stage packet.

## Project independence

RTL dependencies and generated PLL/HyperRAM interface files are copied under
this test directory. The Gowin project uses relative source paths and does not
depend on workstation-specific absolute paths or .gprj.user settings.
