%% MATLAB receiver for UART stop-and-wait frame protocol
% GC0308 + HyperRAM camera project receiver.
% Expected camera mode: 640 x 480 RGB888, 115200 baud, 8N1.
% READY packet determines the actual dimensions and pixel format.
%
% Protocol bytes (multi-byte integers are little-endian):
%   PC -> FPGA: C1 = START, 06 = ACK, 15 = NACK
%   FPGA -> PC READY: A5 01 widthLo widthHi heightLo heightHi BPP format
%   FPGA -> PC LINE:  A5 02 rowLo rowHi lengthLo lengthHi payload CRC_hi CRC_lo
%   FPGA -> PC DONE:  A5 03 heightLo heightHi
% CRC: CRC-16/CCITT-FALSE, polynomial 1021, init FFFF, no reflection/xorout.

clearvars;
clc;

%% User settings
portName       = "/dev/ttyUSB0"; % Set to the Tang Nano USB-UART device (or COM port on Windows)
baudRate       = 115200;
readTimeout_s  = 30;
ackByte        = uint8(hex2dec('06'));
nackByte       = uint8(hex2dec('15'));
startByte      = uint8(hex2dec('C1'));
sofByte        = uint8(hex2dec('A5'));

%% Open UART
sp = serialport(portName, baudRate, ...
    "DataBits", 8, "Parity", "none", "StopBits", 1, ...
    "FlowControl", "none", "Timeout", readTimeout_s);
flush(sp);
pause(0.10);   % allow the USB-UART bridge to settle

fprintf("UART opened: %s @ %d baud, 8N1\n", char(portName), baudRate);
fprintf("Sending START command...\n");
write(sp, startByte, "uint8");

%% Receive READY packet
% Fixed 8-byte packet: A5 01 widthLo widthHi heightLo heightHi BPP format
ready = readExact(sp, 8, readTimeout_s);
if ready(1) ~= sofByte || ready(2) ~= uint8(1)
    error("Invalid READY packet. Received: %s", char(bytesToHex(ready)));
end

width          = double(ready(3)) + 256 * double(ready(4));
height         = double(ready(5)) + 256 * double(ready(6));
bytesPerPixel  = double(ready(7));
pixelFormat    = double(ready(8));
expectedLength = width * bytesPerPixel;

if width < 1 || height < 1 || expectedLength > 65535
    error("Invalid frame dimensions in READY packet.");
end
if ~(bytesPerPixel == 1 && pixelFormat == 0) && ...
   ~(bytesPerPixel == 3 && pixelFormat == 1)
    error("Unsupported pixel format: BPP=%d, format=%d", ...
        bytesPerPixel, pixelFormat);
end

fprintf("READY: %d x %d, %d byte(s)/pixel, format=%d\n", ...
    width, height, bytesPerPixel, pixelFormat);
write(sp, ackByte, "uint8");

%% Allocate destination matrix
if bytesPerPixel == 1
    img = zeros(height, width, 'uint8');
else
    img = zeros(height, width, 3, 'uint8'); % RGB888
end
receivedRows = false(height, 1);
linePacketsAccepted = 0;
linePacketsRejected = 0;

%% Receive lines until DONE
while true
    [packetType] = readPacketType(sp, sofByte, readTimeout_s);

    switch packetType
        case 2  % LINE packet
            lineHeader = readExact(sp, 4, readTimeout_s);
            rowIndex = double(lineHeader(1)) + 256 * double(lineHeader(2));
            payloadLength = double(lineHeader(3)) + 256 * double(lineHeader(4));

            % READY defines the expected row size. Read that fixed amount even
            % if the received length field is corrupted; the CRC/length check
            % below will NACK the packet without losing packet alignment.
            payloadAndCrc = readExact(sp, expectedLength + 2, readTimeout_s);
            payload = payloadAndCrc(1:expectedLength);
            crcReceived = bitor(bitshift(uint16(payloadAndCrc(end-1)), 8), ...
                                uint16(payloadAndCrc(end)));

            % CRC input is TYPE + row index + payload length + payload.
            crcInput = [uint8(packetType); lineHeader(:); payload(:)];
            crcCalculated = crc16CcittFalse(crcInput);

            validLine = (payloadLength == expectedLength) && ...
                        (rowIndex < height) && ...
                        (crcCalculated == crcReceived);

            if validLine
                if bytesPerPixel == 1
                    img(rowIndex + 1, :) = reshape(payload, 1, width);
                else
                    rowBytes = payload(:);
                    img(rowIndex + 1, :, 1) = reshape(rowBytes(1:3:end), 1, width);
                    img(rowIndex + 1, :, 2) = reshape(rowBytes(2:3:end), 1, width);
                    img(rowIndex + 1, :, 3) = reshape(rowBytes(3:3:end), 1, width);
                end

                receivedRows(rowIndex + 1) = true;
                linePacketsAccepted = linePacketsAccepted + 1;
                write(sp, ackByte, "uint8");
                fprintf("Accepted row %d/%d (CRC=%04X)\n", ...
                    rowIndex + 1, height, crcCalculated);
            else
                linePacketsRejected = linePacketsRejected + 1;
                write(sp, nackByte, "uint8");
                fprintf(2, "Rejected row %d: length=%d (expected %d), CRC rx=%04X calc=%04X\n", ...
                    rowIndex, payloadLength, expectedLength, crcReceived, crcCalculated);
                % FPGA retransmits this same row after receiving NACK.
            end

        case 3  % DONE packet
            doneHeightBytes = readExact(sp, 2, readTimeout_s);
            doneHeight = double(doneHeightBytes(1)) + 256 * double(doneHeightBytes(2));
            if doneHeight ~= height || ~all(receivedRows)
                write(sp, nackByte, "uint8");
                error("DONE received before all expected rows were stored.");
            end
            write(sp, ackByte, "uint8");
            fprintf("DONE acknowledged. All %d rows received.\n", height);
            break;

        case 127  % ERROR packet: A5 7F errorCode
            errorInfo = readExact(sp, 1, readTimeout_s);
            error("FPGA reported protocol error code 0x%02X.", errorInfo(1));

        otherwise
            error("Unknown FPGA packet type: 0x%02X", packetType);
    end
end

%% Report and display result
fprintf("Transfer complete: %d accepted line packets, %d rejected attempts.\n", ...
    linePacketsAccepted, linePacketsRejected);

if bytesPerPixel == 1
    figure("Name", "UART received grayscale frame");
    imagesc(img);
    colormap gray;
    axis image off;
else
    figure("Name", "UART received RGB888 frame");
    image(img);
    axis image off;
end

title(sprintf("UART frame: %d x %d", width, height));
save("uart_received_frame.mat", "img", "width", "height", ...
    "bytesPerPixel", "pixelFormat");
fprintf("Saved image data to uart_received_frame.mat\n");

% Keep the serial object available in the workspace. Close it with clear sp.

%% Local functions
function bytes = readExact(sp, count, timeoutSeconds)
% Read exactly COUNT bytes without discarding bytes already in the UART buffer.
    bytes = zeros(count, 1, "uint8");
    received = 0;
    tStart = tic;
    while received < count
        available = sp.NumBytesAvailable;
        if available > 0
            nToRead = min(count - received, available);
            chunk = read(sp, nToRead, "uint8");
            chunk = chunk(:);
            bytes(received + 1:received + numel(chunk)) = chunk;
            received = received + numel(chunk);
        elseif toc(tStart) > timeoutSeconds
            error("UART timeout: wanted %d byte(s), received %d.", count, received);
        else
            pause(0.001);
        end
    end
end

function packetType = readPacketType(sp, sofByte, timeoutSeconds)
% Discard bytes until SOF is seen, then return the following packet type.
    tStart = tic;
    while toc(tStart) <= timeoutSeconds
        b = readExact(sp, 1, max(0.1, timeoutSeconds - toc(tStart)));
        if b(1) == sofByte
            typeByte = readExact(sp, 1, max(0.1, timeoutSeconds - toc(tStart)));
            packetType = double(typeByte(1));
            return;
        end
    end
    error("Timeout while searching for packet start byte 0xA5.");
end

function crc = crc16CcittFalse(data)
% CRC-16/CCITT-FALSE: poly 0x1021, init 0xFFFF, no reflection, xorout 0.
    crc = uint16(hex2dec("FFFF"));
    polynomial = uint16(hex2dec("1021"));
    data = uint8(data(:));
    for k = 1:numel(data)
        crc = bitxor(crc, bitshift(uint16(data(k)), 8));
        for bitNumber = 1:8
            if bitand(crc, uint16(hex2dec("8000"))) ~= 0
                crc = bitxor(bitshift(crc, 1), polynomial);
            else
                crc = bitshift(crc, 1);
            end
        end
    end
end

function s = bytesToHex(bytes)
    s = char(strjoin(compose("%02X", bytes(:)), " "));
end