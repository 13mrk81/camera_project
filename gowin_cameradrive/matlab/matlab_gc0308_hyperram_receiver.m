%% Receive-only GC0308 / HyperRAM raw RGB565 stream
% The FPGA is triggered by the Tang Nano 4K onboard KEY1 pushbutton.
% This script DOES NOT write any bytes to the UART.
%
% UART: 115200 baud, 8N1. FPGA packet gap: 20 ms; inter-byte idle: 25 us.
% Packet: A5 5A TYPE SEQ_LO SEQ_HI LEN_LO LEN_HI PAYLOAD CRC_HI CRC_LO.
% CRC-16/CCITT-FALSE covers TYPE through PAYLOAD (SOF excluded).
%
% Types:
%   10 STAGE: [stage_code, detail]
%       01 trigger accepted, 02 camera configured, 03 frame stored
%   11 READY: [widthLo widthHi heightLo heightHi 02 02] (RGB565)
%   20 LINE:  seq = zero-based row, payload = RGB565 pixel words, MSB byte first
%   30 DONE:  height(2), lines(2), pixels(4), uart_bytes(4), raw565_crc32(4)
%   7F ERROR: [error_code, detail]
% Geometry/statistics fields are little-endian. RGB565 pixel words are sent
% high byte then low byte, left-to-right. CRC trailer is high byte first.

clc;
clear sp;

%% User settings
portName = "/dev/ttyUSB0";  % Change to the Tang Nano USB-UART device / COM port.
baudRate = 115200;
preTriggerTimeout_s = Inf;  % Wait indefinitely for the physical KEY1 press.
activeTimeout_s = 25;       % FPGA capture/config timeout is 15 s; allow margin.
maxPayloadBytes = 65535;

%% Open UART in receive-only mode
sp = serialport(portName, baudRate, ...
    "DataBits", 8, "Parity", "none", "StopBits", 1, ...
    "FlowControl", "none", "Timeout", 1);
flush(sp);

fprintf("UART opened: %s @ %d baud, 8N1 (receive-only).\n", ...
    char(portName), baudRate);
fprintf("serialport manages receive buffering automatically; MATLAB reads available data in chunks up to 8192 bytes.\n");
fprintf("No UART commands will be transmitted. Press the board's KEY1 button to start.\n");

rxBuffer = zeros(0, 1, "uint8");
receiverState = "WAIT_TRIGGER";
transferStarted = false;
frameReady = false;
frameComplete = false;
gotError = false;
img = [];
receivedRows = false(0, 1);
nextExpectedRow = 0;
acceptedLines = 0;
duplicateLines = 0;
outOfOrderLines = 0;
badCrcCandidates = 0;
discardedBytes = 0;
totalBytesRead = 0;
maxDriverQueueBytes = 0;
maxSoftwareBufferBytes = 0;
lastErrorCode = uint8(0);
lastErrorDetail = uint8(0);
doneStats = struct();

%% Packet receive and frame reconstruction
while true
    if transferStarted
        packetTimeout = activeTimeout_s;
    else
        packetTimeout = preTriggerTimeout_s;
    end

    [packet, rxBuffer, droppedNow, badNow, bytesNow, queueMaxNow, parserMaxNow] = receivePacket(sp, rxBuffer, packetTimeout, maxPayloadBytes);
    totalBytesRead = totalBytesRead + bytesNow;
    maxDriverQueueBytes = max(maxDriverQueueBytes, queueMaxNow);
    maxSoftwareBufferBytes = max(maxSoftwareBufferBytes, parserMaxNow);
    discardedBytes = discardedBytes + droppedNow;
    badCrcCandidates = badCrcCandidates + badNow;

    if droppedNow > 0 || badNow > 0
        fprintf(2, "Resynchronization: discarded %d byte(s), rejected %d CRC candidate(s).\n", ...
            droppedNow, badNow);
    end

    switch packet.type
        case hex2dec("10")  % STAGE
            if numel(packet.payload) ~= 2
                fprintf(2, "Malformed STAGE packet (length=%d).\n", numel(packet.payload));
                continue;
            end
            stageCode = packet.payload(1);
            detail = packet.payload(2);
            transferStarted = true;

            switch stageCode
                case 1
                    receiverState = "WAIT_CAMERA_CONFIG";
                    fprintf("[STAGE 1/3] FPGA accepted KEY1 trigger. Camera setup started.\n");
                case 2
                    receiverState = "WAIT_FRAME_STORED";
                    fprintf("[STAGE 2/3] Camera configured and RGB565 mode verified.\n");
                case 3
                    receiverState = "WAIT_READY";
                    fprintf("[STAGE 3/3] Frame captured and stored in HyperRAM.\n");
                otherwise
                    fprintf("[STAGE] Unknown stage 0x%02X, detail=0x%02X.\n", stageCode, detail);
            end

        case hex2dec("11")  % READY
            if numel(packet.payload) ~= 6
                error("Malformed READY packet: expected 6 payload bytes, got %d.", ...
                    numel(packet.payload));
            end
            width = double(readLE(packet.payload(1:2)));
            height = double(readLE(packet.payload(3:4)));
            bytesPerPixel = double(packet.payload(5));
            pixelFormat = double(packet.payload(6));

            if width < 1 || height < 1 || bytesPerPixel ~= 2 || pixelFormat ~= 2
                error("Unsupported READY geometry/format: %dx%d, BPP=%d, format=%d.", ...
                    width, height, bytesPerPixel, pixelFormat);
            end
            if width * bytesPerPixel > maxPayloadBytes
                error("RGB565 line length exceeds the protocol's 16-bit payload length.");
            end

            raw565Bytes = zeros(height, width * 2, "uint8");
            raw565Frame = zeros(height, width, "uint16");
            receivedRows = false(height, 1);
            nextExpectedRow = 0;
            frameReady = true;
            receiverState = "RECEIVING_LINES";
            fprintf("[READY] %d x %d RGB565; %d bytes/line; first line follows.\n", ...
                width, height, width * 2);

        case hex2dec("20")  % LINE
            if ~frameReady
                fprintf(2, "LINE arrived before READY; sequence=%d ignored.\n", packet.sequence);
                continue;
            end

            row = double(packet.sequence);
            expectedLineBytes = width * 2;
            if row >= height || numel(packet.payload) ~= expectedLineBytes
                fprintf(2, "Invalid LINE: row=%d, payload=%d, expected=%d.\n", ...
                    row, numel(packet.payload), expectedLineBytes);
                continue;
            end
            if receivedRows(row + 1)
                duplicateLines = duplicateLines + 1;
                fprintf(2, "Duplicate row %d ignored.\n", row);
                continue;
            end
            if row ~= nextExpectedRow
                outOfOrderLines = outOfOrderLines + 1;
                fprintf(2, "Row order discontinuity: expected %d, received %d.\n", ...
                    nextExpectedRow, row);
            end

            % Preserve raw bytes; each pixel is high byte then low byte.
            raw565Bytes(row + 1, :) = reshape(packet.payload(:), 1, width * 2);
            hi = uint16(packet.payload(1:2:end));
            lo = uint16(packet.payload(2:2:end));
            raw565Frame(row + 1, :) = bitor(bitshift(hi, 8), lo).';
            receivedRows(row + 1) = true;
            acceptedLines = acceptedLines + 1;
            nextExpectedRow = row + 1;

            if mod(acceptedLines, 20) == 0 || acceptedLines == height
                fprintf("Received %d/%d rows (latest row=%d, CRC valid).\n", ...
                    acceptedLines, height, row);
                drawnow limitrate;
            end

        case hex2dec("30")  % DONE
            if numel(packet.payload) ~= 16
                error("Malformed DONE packet: expected 16 payload bytes, got %d.", ...
                    numel(packet.payload));
            end
            doneStats.height = double(readLE(packet.payload(1:2)));
            doneStats.lines = double(readLE(packet.payload(3:4)));
            doneStats.pixels = double(readLE(packet.payload(5:8)));
            doneStats.uartBytes = double(readLE(packet.payload(9:12)));
            doneStats.rawRgb565Crc32 = readLE32(packet.payload(13:16));

            frameComplete = frameReady && ...
                doneStats.height == height && ...
                doneStats.lines == height && ...
                doneStats.pixels == width * height && ...
                doneStats.uartBytes == width * height * 2 && ...
                all(receivedRows);

            if frameComplete
                receiverState = "COMPLETE";
                fprintf("[DONE] Complete frame received: %d/%d rows, %d RGB565 bytes.\n", ...
                    acceptedLines, height, doneStats.uartBytes);
            else
                receiverState = "INCOMPLETE";
                fprintf(2, "[DONE] Integrity mismatch: rows %d/%d, FPGA lines=%d, pixels=%d, bytes=%d.\n", ...
                    acceptedLines, height, doneStats.lines, doneStats.pixels, doneStats.uartBytes);
            end
            fprintf("FPGA raw RGB565 readback CRC32: %08X\n", doneStats.rawRgb565Crc32);
            break;

        case hex2dec("7F")  % ERROR
            if numel(packet.payload) ~= 2
                fprintf(2, "Malformed ERROR packet (length=%d).\n", numel(packet.payload));
                continue;
            end
            lastErrorCode = packet.payload(1);
            lastErrorDetail = packet.payload(2);
            gotError = true;
            receiverState = "ERROR";
            fprintf(2, "[FPGA ERROR] %s (code=0x%02X, detail=0x%02X, seq=%d).\n", ...
                errorName(lastErrorCode), lastErrorCode, lastErrorDetail, packet.sequence);
            break;

        otherwise
            fprintf(2, "Unknown packet type 0x%02X (sequence=%d, len=%d), ignored.\n", ...
                packet.type, packet.sequence, numel(packet.payload));
    end
end

%% Report and save the result
fprintf("\nReceiver state: %s\n", receiverState);
fprintf("Valid LINE packets: %d | duplicates: %d | out-of-order: %d\n", ...
    acceptedLines, duplicateLines, outOfOrderLines);
fprintf("Rejected CRC candidates: %d | discarded bytes during resync: %d\n", ...
    badCrcCandidates, discardedBytes);
fprintf("UART bytes read: %d | max driver queue: %d | max parser buffer: %d bytes\n", ...
    totalBytesRead, maxDriverQueueBytes, maxSoftwareBufferBytes);

if ~isempty(img)
    if frameComplete
        figure("Name", "GC0308 raw RGB565 preview");
        imshow(decodeRgb565(raw565Frame));
        title(sprintf("GC0308 raw RGB565: %d x %d", width, height));
    else
        figure("Name", "Partial GC0308 RGB565 frame");
        imshow(decodeRgb565(raw565Frame));
        axis image off;
        title(sprintf("Partial frame: %d/%d rows received", acceptedLines, height));
        figure("Name", "Received row map");
        imagesc(receivedRows);
        colormap gray;
        axis tight;
        title("Rows with valid CRC");
    end

    save("uart_received_frame.mat", "raw565Frame", "raw565Bytes", "width", "height", ...
        "receivedRows", "frameComplete", "acceptedLines", ...
        "duplicateLines", "outOfOrderLines", "badCrcCandidates", ...
        "discardedBytes", "doneStats", "gotError", "totalBytesRead", ...
        "maxDriverQueueBytes", "maxSoftwareBufferBytes", ...
        "lastErrorCode", "lastErrorDetail");
    fprintf("Saved image and receive statistics to uart_received_frame.mat\n");
else
    fprintf(2, "No READY/image data received; no frame file written.\n");
end

%% Local functions
function [packet, buffer, droppedBytes, badCrcCount, bytesRead, maxQueueBytes, maxBufferBytes] = receivePacket(sp, buffer, timeoutSeconds, maxPayloadBytes)
% Read in available chunks and extract the earliest CRC-valid packet.
% Scanning for a later valid SOF allows recovery if a LINE payload was aborted:
% a nested A5 5A candidate is accepted only after its own complete CRC passes.
    tStart = tic;
    droppedBytes = 0;
    badCrcCount = 0;
    bytesRead = 0;
    maxQueueBytes = 0;
    maxBufferBytes = numel(buffer);

    while true
        % Sample the driver queue both before and after parser/CRC work so
        % bytes accumulated while MATLAB was busy are included in the metric.
        maxQueueBytes = max(maxQueueBytes, double(sp.NumBytesAvailable));
        maxBufferBytes = max(maxBufferBytes, numel(buffer));
        [packet, found, buffer, droppedNow, badNow] = extractValidPacket(buffer, maxPayloadBytes);
        maxQueueBytes = max(maxQueueBytes, double(sp.NumBytesAvailable));
        droppedBytes = droppedBytes + droppedNow;
        badCrcCount = badCrcCount + badNow;
        if found
            return;
        end

        available = sp.NumBytesAvailable;
        maxQueueBytes = max(maxQueueBytes, double(available));
        if available > 0
            n = min(double(available), 8192);
            chunk = read(sp, n, "uint8");
            bytesRead = bytesRead + numel(chunk);
            buffer = [buffer; uint8(chunk(:))]; %#ok<AGROW>
            maxBufferBytes = max(maxBufferBytes, numel(buffer));
        else
            if ~isinf(timeoutSeconds) && toc(tStart) >= timeoutSeconds
                error("UART inactivity timeout after %.1f s while waiting for a valid packet (buffer=%d byte(s)).", ...
                    timeoutSeconds, numel(buffer));
            end
            pause(0.001);
        end
    end
end

function [packet, found, buffer, droppedBytes, badCrcCount] = extractValidPacket(buffer, maxPayloadBytes)
% Find a complete valid packet. Incomplete earlier frames do not block a later
% valid packet; this is important when FPGA readout fails in the middle of a row.
    sof0 = uint8(hex2dec("A5"));
    sof1 = uint8(hex2dec("5A"));
    packet = struct("type", uint8(0), "sequence", uint16(0), ...
        "payload", zeros(0, 1, "uint8"), "crc", uint16(0));
    found = false;
    droppedBytes = 0;
    badCrcCount = 0;

    if numel(buffer) < 2
        return;
    end

    syncPositions = find(buffer(1:end-1) == sof0 & buffer(2:end) == sof1);
    earliestIncomplete = [];

    for k = 1:numel(syncPositions)
        p = syncPositions(k);
        remaining = numel(buffer) - p + 1;

        % Sync(2) + type(1) + seq(2) + length(2) = 7 bytes.
        if remaining < 7
            if isempty(earliestIncomplete)
                earliestIncomplete = p;
            end
            continue;
        end

        payloadLength = double(buffer(p + 5)) + 256 * double(buffer(p + 6));
        if payloadLength > maxPayloadBytes
            badCrcCount = badCrcCount + 1;
            continue;
        end
        totalLength = 9 + payloadLength;
        if remaining < totalLength
            if isempty(earliestIncomplete)
                earliestIncomplete = p;
            end
            continue;
        end

        crcStart = p + 7 + payloadLength;
        crcReceived = bitor(bitshift(uint16(buffer(crcStart)), 8), ...
                            uint16(buffer(crcStart + 1)));
        crcInput = buffer(p + 2:crcStart - 1);
        crcCalculated = crc16CcittFalse(crcInput);

        if crcCalculated == crcReceived
            packet.type = buffer(p + 2);
            packet.sequence = readLE(buffer(p + 3:p + 4));
            packet.payload = buffer(p + 7:crcStart - 1);
            packet.crc = crcReceived;
            found = true;
            droppedBytes = p - 1;
            buffer = buffer(p + totalLength:end);
            return;
        else
            badCrcCount = badCrcCount + 1;
        end
    end

    if ~isempty(earliestIncomplete)
        droppedBytes = earliestIncomplete - 1;
        buffer = buffer(earliestIncomplete:end);
    elseif buffer(end) == sof0
        droppedBytes = numel(buffer) - 1;
        buffer = buffer(end);
    else
        droppedBytes = numel(buffer);
        buffer = zeros(0, 1, "uint8");
    end
end

function crc = crc16CcittFalse(data)
% CRC-16/CCITT-FALSE: poly=0x1021, init=0xFFFF, refin=false, xorout=0.
    crc = uint16(hex2dec("FFFF"));
    polynomial = uint16(hex2dec("1021"));
    data = uint8(data(:));
    for n = 1:numel(data)
        crc = bitxor(crc, bitshift(uint16(data(n)), 8));
        for bitNumber = 1:8
            if bitand(crc, uint16(hex2dec("8000"))) ~= 0
                crc = bitxor(bitshift(crc, 1), polynomial);
            else
                crc = bitshift(crc, 1);
            end
        end
    end
end

function value = readLE(bytes)
% Decode one or more little-endian bytes to uint16/uint32.
    bytes = uint8(bytes(:));
    value = uint64(0);
    for k = 1:numel(bytes)
        value = bitor(value, bitshift(uint64(bytes(k)), 8 * (k - 1)));
    end
    if numel(bytes) <= 2
        value = uint16(value);
    else
        value = uint32(value);
    end
end

function value = readLE32(bytes)
    bytes = uint8(bytes(:));
    value = uint32(0);
    for k = 1:min(4, numel(bytes))
        value = bitor(value, bitshift(uint32(bytes(k)), 8 * (k - 1)));
    end
end

function rgb = decodeRgb565(frame)
    p = uint16(frame);
    r5 = bitshift(bitand(p, uint16(63488)), -11);
    g6 = bitshift(bitand(p, uint16(2016)), -5);
    b5 = bitand(p, uint16(31));
    r8 = uint8(bitor(bitshift(r5, 3), bitshift(r5, -2)));
    g8 = uint8(bitor(bitshift(g6, 2), bitshift(g6, -4)));
    b8 = uint8(bitor(bitshift(b5, 3), bitshift(b5, -2)));
    rgb = cat(3, r8, g8, b8);
end

function name = errorName(code)
    switch double(code)
        case 1
            name = "camera configuration failed";
        case 2
            name = "camera capture or HyperRAM write failed";
        case 3
            name = "configuration/capture stage timeout";
        case 4
            name = "HyperRAM readout or RGB serializer failed";
        case 5
            name = "RGB line source starved";
        otherwise
            name = "unspecified FPGA protocol error";
    end
end
