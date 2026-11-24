# Test 5 — Camera PCLK → Async FIFO → 24 MHz UART

## Objective

Determine whether the real GC0308 pixel clock can write data into a dual-clock FIFO and whether the independent 24 MHz domain can read that data and deliver it to MATLAB through UART.

This test removes camera pixel payload, RGB565 packing, the capture/input FIFO, HyperRAM, memory control, and image reconstruction.

## Architecture

GC0308 PCLK / VSYNC / HREF
→ frame-start and first-HREF-rise detector (cam_pclk domain)
→ fixed 8 × 32-bit diagnostic message
→ existing async_fifo_32 (write clock = cam_pclk)
→ FIFO reader (read clock = 24 MHz)
→ packetizer using the existing A5 5A and CRC16 framing
→ UART TX (24 MHz, 115200 baud, 8-N-1)
→ MATLAB test5_receive_uart.m

## Trigger event

The existing camera_interface configures the GC0308 over I2C. In the configured profile VSYNC and HREF are active high.

After camera configuration passes:
1. Detect VSYNC rising edge (frame start).
2. Wait for the first HREF rising edge while VSYNC is active (first active line).
3. Write exactly eight 32-bit words into the FIFO using cam_pclk.

One message is written per frame. The camera pixel data bus is not used; its unused camera_interface input is tied to zero.

## Diagnostic payload

Exact 32-byte ASCII string:

CAM_PCLK_FIFO_TO_24M_UART_TEST5!

## Clock domains

- FIFO write: real cam_pclk.
- FIFO read: PLL-generated 24 MHz clk24.
- UART: 24 MHz clk24.
- UART format: 115200 baud, 8 data bits, no parity, 1 stop bit.

## Packet protocol

A5 5A TYPE SEQ_LO SEQ_HI LEN_LO LEN_HI PAYLOAD CRC_HI CRC_LO

- TYPE = 0x50 (Test 5)
- Sequence number: 16-bit little-endian
- Payload length: 32 bytes
- CRC-16/CCITT-FALSE: init 0xFFFF, polynomial 0x1021, no reflection, no final XOR
- CRC covers TYPE through the final payload byte; SOF excluded.
- CRC bytes are sent high byte first.

## Build and run

Open TEST5_CAMERA_PCLK_FIFO_UART.gprj in Gowin EDA.

1. Connect the GC0308 module and its PCLK/VSYNC/HREF/I2C signals.
2. Compile and program the Test 5 bitstream.
3. Connect FPGA UART TX to USB-UART adapter RX and connect grounds.
4. In MATLAB:

    cd('Three_Test_Camera_HyperRAM/test_5/host')
    report = test5_receive_uart("/dev/ttyUSB0");

5. The camera configuration starts automatically after reset. MATLAB waits for the first packet; the packet should arrive after the next frame start and first active HREF edge.

## Interpretation

- Correct message + CRC pass: camera PCLK domain wrote the diagnostic words, the async FIFO crossed into 24 MHz, and the UART path delivered them to MATLAB.
- No packet: investigate camera configuration, PCLK presence, VSYNC/HREF polarity and timing, event detection, FIFO write/read, and UART.
- CRC failure: investigate packetizer, UART, and MATLAB framing/byte integrity.
- CRC pass but payload mismatch: investigate FIFO word order, byte extraction, or producer data.

A pass does not validate camera pixel sampling, RGB565 packing, or HyperRAM. It isolates the camera-clock-to-24-MHz FIFO and UART path.

## Validation status

No Gowin compile, synthesis, place-and-route, timing closure, bitstream generation, or physical-board test has been run here. Compile in Gowin before programming. Measure the actual camera PCLK and add a numeric external-clock constraint only after confirming the configured sensor mode.
