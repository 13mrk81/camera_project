# Test 5 — Camera PCLK-clocked FIFO write → 24 MHz UART

## Objective

Verify that the real GC0308 pixel clock (`cam_pclk`) can clock the write port of a dual-clock FIFO, and that the independent 24 MHz domain can read the stored words and deliver them to MATLAB through UART.

This is a clock-domain/write-path experiment. It does **not** use HyperRAM and does **not** sample the camera pixel-data bus. The test payload is synthetic and is written into the FIFO by the `cam_pclk` clock.

## Trigger and operating sequence

- KEY2 (active-low) resets the FPGA.
- KEY1 (active-low, FPGA pin 14) is the external start trigger.
- After reset, the FPGA waits in the camera-configuration trigger state. No camera I2C configuration is started automatically.
- Press KEY1. The input is synchronized and debounced for 20 ms in the 8 MHz domain.
- The debounced request is held high and starts the existing `camera_interface` configuration sequence.
- The writer waits until both `config_done` and `config_pass` are asserted and synchronized into the `cam_pclk` domain.
- It then waits for active-high VSYNC frame start followed by the first active-high HREF rising edge.
- At that event, exactly eight 32-bit diagnostic words are written into the asynchronous FIFO. The FIFO write clock is the real `cam_pclk`.
- The writer is one-shot: it stops after the eight words. Reset is required before another capture.

Start MATLAB listening **before** pressing KEY1, otherwise the one-shot packet may be transmitted before MATLAB opens the serial port.

## Data path

GC0308 VSYNC/HREF event (detected on `cam_pclk`)
→ diagnostic word generator
→ `async_fifo_32` write port (`wr_clk = cam_pclk`)
→ `async_fifo_32` read port (`rd_clk = clk24`)
→ packetizer and CRC16
→ UART TX (`clk24`, 115200 baud, 8-N-1)
→ MATLAB.

The FIFO is the only storage element under test. Its write-side memory operation is clocked by `cam_pclk`; its read-side operation is clocked by 24 MHz. This experiment does not claim that the HyperRAM controller itself is clocked by `cam_pclk`.

## Diagnostic payload

Exact 32-byte ASCII string:

`CAM_PCLK_FIFO_TO_24M_UART_TEST5!`

The string is divided into eight 32-bit words and written one word per accepted `cam_pclk` edge while the FIFO is not full.

## Packet protocol

`A5 5A TYPE SEQ_LO SEQ_HI LEN_LO LEN_HI PAYLOAD CRC_HI CRC_LO`

- TYPE = `0x50`
- Sequence number: 16-bit little-endian (starts at zero after reset)
- Payload length: 32 bytes
- CRC-16/CCITT-FALSE: init `0xFFFF`, polynomial `0x1021`, no reflection, no final XOR
- CRC covers TYPE through the final payload byte; SOF excluded
- CRC bytes are sent high byte first

## Build and run

Open `TEST5_CAMERA_PCLK_FIFO_UART.gprj` in Gowin EDA.

1. Connect the GC0308 module: camera clock, I2C, PCLK, VSYNC and HREF.
2. Compile and program the Test 5 bitstream.
3. Connect FPGA UART TX to USB-UART adapter RX and connect grounds.
4. In MATLAB, start the receiver:
   
   ```matlab
   report = test5_receive_uart("/dev/ttyUSB0");
   ```

5. While MATLAB is listening, press the board's KEY1 button once.
6. Wait for camera configuration and the next frame/first active-line event. MATLAB should receive one packet.

## Interpretation

- Correct message + CRC pass: the diagnostic words were written using `cam_pclk`, crossed through the asynchronous FIFO, read in the 24 MHz domain, and transmitted through UART.
- No packet: check KEY1 trigger, camera I2C configuration, `config_done/config_pass`, PCLK presence, VSYNC/HREF polarity and timing, FIFO write/read, and UART pin connection.
- CRC failure: investigate packetizer, UART, and MATLAB framing/byte integrity.
- CRC pass but payload mismatch: investigate FIFO word order and byte extraction.

A pass validates the **camera-PCLK-clocked FIFO write port and the CDC/read/UART path**. It does not validate camera pixel sampling, RGB565 packing, HyperRAM writes, or image reconstruction.

## Validation status

No Gowin compile, synthesis, place-and-route, timing closure, bitstream generation, or physical-board test has been run as part of this update. Compile in Gowin before programming. The exact external `cam_pclk` period must be measured/confirmed for the configured GC0308 mode before adding a numeric clock constraint.
