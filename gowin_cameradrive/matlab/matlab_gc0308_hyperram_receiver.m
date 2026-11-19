%% Receive-only GC0308 / HyperRAM Gray8 stream
% FPGA is triggered by Tang Nano 4K KEY1. MATLAB never transmits UART data.
% UART 8N1, nominal 115200 baud. Packet: A5 5A TYPE SEQ_LE LEN_LE PAYLOAD CRC_HI CRC_LO.
% CRC16 is CRC-16/CCITT-FALSE over TYPE through PAYLOAD.
% READY payload: width_LE(2), height_LE(2), BPP=1, format=3 (Gray8).
% LINE payload: one Gray8 byte per pixel, sequence is zero-based row index.
% Gray8 is BT.601 luma computed in FPGA from the RGB565 frame in HyperRAM.
% DONE payload: height(2), lines(2), pixels(4), UART bytes(4), Gray8 CRC32(4).

clc;
clear sp;

portName = "/dev/ttyUSB0";
baudRate = 115200;
readChunkBytes = 8192;
maxPayloadBytes = 4096;
overallTimeout_s = 180;
inactivityTimeout_s = 10;

sp = serialport(portName, baudRate, ...
    "DataBits", 8, "Parity", "none", "StopBits", 1, ...
    "FlowControl", "none", "Timeout", 2);
flush(sp);

fprintf("UART opened: %s @ %d baud, 8N1, receive-only.\n", char(portName), baudRate);
fprintf("Press KEY1 on the FPGA. Each packet is CRC-checked as soon as it is complete.\n");

% Frame storage is allocated from the geometry advertised by the FPGA.
% For the default 640x480 mode this is exactly 307,200 image bytes.
gray8Frame = zeros(0, 0, "uint8");
receivedRows = false(0, 1);
frameReady = false;
frameComplete = false;
gotDone = false;
gotError = false;
doneStats = struct();
lastErrorCode = uint8(0);
lastErrorDetail = uint8(0);
acceptedLines = 0;
duplicateLines = 0;
outOfOrderLines = 0;
badCrcCandidates = 0;
discardedBytes = 0;
packetCount = 0;
receivedByteCount = 0;
maxDriverQueueBytes = 0;
maxParserBufferBytes = 0;
maxPacketParseTime_s = 0;
rxBuffer = zeros(0, 1, "uint8");
transferStarted = false;
lastDataTime = tic;
totalTime = tic;
nextExpectedRow = 0;

while ~gotDone && ~gotError
    available = double(sp.NumBytesAvailable);
    maxDriverQueueBytes = max(maxDriverQueueBytes, available);

    if available > 0
        n = min(available, readChunkBytes);
        chunk = read(sp, n, "uint8");
        chunk = uint8(chunk(:));
        if ~isempty(chunk)
            rxBuffer = [rxBuffer; chunk]; %#ok<AGROW>
            receivedByteCount = receivedByteCount + numel(chunk);
            maxParserBufferBytes = max(maxParserBufferBytes, numel(rxBuffer));
            if ~transferStarted
                totalTime = tic;
            end
            transferStarted = true;
            lastDataTime = tic;
        end
    else
        if transferStarted && toc(lastDataTime) >= inactivityTimeout_s
            fprintf(2, "UART inactivity timeout after %d bytes.\n", receivedByteCount);
            break;
        end
        if transferStarted && toc(totalTime) >= overallTimeout_s
            fprintf(2, "Overall timeout after %d bytes.\n", receivedByteCount);
            break;
        end
        pause(0.001);
    end

    % Parse every complete packet already buffered. CRC is checked here,
    % before the next FPGA packet is expected (50 ms inter-packet gap).
    while numel(rxBuffer) >= 2
        parseTimer = tic;
        [packet, found, rxBuffer, droppedNow, badNow] = ...
            extractValidPacket(rxBuffer, maxPayloadBytes);
        maxPacketParseTime_s = max(maxPacketParseTime_s, toc(parseTimer));
        discardedBytes = discardedBytes + droppedNow;
        badCrcCandidates = badCrcCandidates + badNow;
        if ~found
            break;
        end
        packetCount = packetCount + 1;

        switch double(packet.type)
            case hex2dec("10") % STAGE
                if numel(packet.payload) == 2
                    fprintf("[STAGE] code=%d detail=0x%02X\n", ...
                        packet.payload(1), packet.payload(2));
                end

            case hex2dec("11") % READY
                if numel(packet.payload) ~= 6
                    fprintf(2, "Malformed READY packet (length=%d).\n", numel(packet.payload));
                    continue;
                end
                width = double(readLE(packet.payload(1:2)));
                height = double(readLE(packet.payload(3:4)));
                bytesPerPixel = double(packet.payload(5));
                pixelFormat = double(packet.payload(6));
                if width < 1 || width > maxPayloadBytes || height < 1 || bytesPerPixel ~= 1 || pixelFormat ~= 3
                    error("Unsupported READY format/geometry: %dx%d, BPP=%d, format=%d.", ...
                        width, height, bytesPerPixel, pixelFormat);
                end
                gray8Frame = zeros(height, width, "uint8");
                receivedRows = false(height, 1);
                frameReady = true;
                fprintf("[READY] %d x %d Gray8; frame buffer = %d bytes.\n", ...
                    width, height, numel(gray8Frame));

            case hex2dec("20") % LINE
                if ~frameReady
                    fprintf(2, "LINE before READY; row=%d ignored.\n", double(packet.sequence));
                    continue;
                end
                row = double(packet.sequence);
                if row >= height || numel(packet.payload) ~= width
                    fprintf(2, "Invalid LINE row=%d, payload=%d (expected %d).\n", ...
                        row, numel(packet.payload), width);
                    continue;
                end
                if receivedRows(row + 1)
                    duplicateLines = duplicateLines + 1;
                    continue;
                end
                if row ~= nextExpectedRow
                    outOfOrderLines = outOfOrderLines + 1;
                    fprintf(2, "Row order discontinuity: expected %d, received %d.\n", ...
                        nextExpectedRow, row);
                end
                % Commit only after packet framing, length, and CRC16 passed.
                gray8Frame(row + 1, :) = reshape(packet.payload, 1, width);
                receivedRows(row + 1) = true;
                acceptedLines = acceptedLines + 1;
                nextExpectedRow = row + 1;

            case hex2dec("30") % DONE
                if numel(packet.payload) ~= 16
                    fprintf(2, "Malformed DONE packet (length=%d).\n", numel(packet.payload));
                    continue;
                end
                doneStats.height = double(readLE(packet.payload(1:2)));
                doneStats.lines = double(readLE(packet.payload(3:4)));
                doneStats.pixels = double(readLE(packet.payload(5:8)));
                doneStats.uartBytes = double(readLE(packet.payload(9:12)));
                doneStats.gray8Crc32 = readLE32(packet.payload(13:16));
                gotDone = true;

            case hex2dec("7F") % ERROR
                if numel(packet.payload) == 2
                    lastErrorCode = packet.payload(1);
                    lastErrorDetail = packet.payload(2);
                    gotError = true;
                    fprintf(2, "[FPGA ERROR] code=0x%02X detail=0x%02X\n", ...
                        lastErrorCode, lastErrorDetail);
                end
            otherwise
                fprintf(2, "Unknown packet type 0x%02X.\n", packet.type);
        end
    end
end

matlabGray8Crc32 = uint32(0);
if frameReady && all(receivedRows)
    % FPGA CRC is over transmitted Gray8 bytes in row-major order.
    matlabGray8Crc32 = crc32Mpeg2(reshape(gray8Frame.', [], 1));
end

frameComplete = frameReady && gotDone && ~gotError && ...
    doneStats.height == height && doneStats.lines == height && ...
    doneStats.pixels == width * height && ...
    doneStats.uartBytes == width * height && ...
    all(receivedRows) && matlabGray8Crc32 == doneStats.gray8Crc32;

if frameComplete
    receiverState = "COMPLETE";
else
    receiverState = "INCOMPLETE";
end
fprintf("\nReceiver state: %s\n", receiverState);
fprintf("Packets=%d, valid rows=%d/%d, duplicates=%d, out-of-order=%d\n", ...
    packetCount, acceptedLines, heightOrZero(frameReady, receivedRows), ...
    duplicateLines, outOfOrderLines);
fprintf("CRC-invalid candidates=%d, discarded bytes=%d, UART bytes=%d\n", ...
    badCrcCandidates, discardedBytes, receivedByteCount);
fprintf("Maximum driver queue=%d bytes, parser buffer=%d bytes, packet parse=%.3f ms\n", ...
    maxDriverQueueBytes, maxParserBufferBytes, 1000 * maxPacketParseTime_s);
if gotDone && frameReady && all(receivedRows)
    fprintf("FPGA Gray8 CRC32=%08X | MATLAB=%08X | match=%s\n", ...
        doneStats.gray8Crc32, matlabGray8Crc32, ...
        string(matlabGray8Crc32 == doneStats.gray8Crc32));
end

if frameReady
    figure("Name", "GC0308 HyperRAM Gray8 capture", "Color", "w");
    imshow(gray8Frame);
    title(sprintf("Gray8 capture — valid rows %d/%d — complete=%s", ...
        acceptedLines, height, string(frameComplete)));
    save("uart_received_gray8_frame.mat", "gray8Frame", "width", "height", ...
        "receivedRows", "frameComplete", "matlabGray8Crc32", "doneStats", ...
        "acceptedLines", "duplicateLines", "outOfOrderLines", ...
        "badCrcCandidates", "discardedBytes", "receivedByteCount", ...
        "maxDriverQueueBytes", "maxParserBufferBytes", "maxPacketParseTime_s", ...
        "lastErrorCode", "lastErrorDetail");
    fprintf("Saved Gray8 frame and receiver statistics to uart_received_gray8_frame.mat\n");
else
    save("uart_received_gray8_frame.mat", "receivedByteCount", ...
        "badCrcCandidates", "discardedBytes", "maxDriverQueueBytes", ...
        "maxParserBufferBytes", "maxPacketParseTime_s", ...
        "lastErrorCode", "lastErrorDetail");
    fprintf(2, "No valid READY packet recovered; diagnostics saved.\n");
end

function n = heightOrZero(frameReady, rows)
    if frameReady, n = numel(rows); else, n = 0; end
end

function [packet, found, buffer, droppedBytes, badCrcCount] = extractValidPacket(buffer, maxPayloadBytes)
% Scan for the earliest complete CRC-valid packet. A later valid SOF can
% recover the stream if an earlier candidate was truncated or corrupted.
    sof0 = uint8(hex2dec("A5"));
    sof1 = uint8(hex2dec("5A"));
    packet = struct("type", uint8(0), "sequence", uint16(0), ...
        "payload", zeros(0, 1, "uint8"), "crc", uint16(0));
    found = false;
    droppedBytes = 0;
    badCrcCount = 0;
    if numel(buffer) < 2, return; end

    syncPositions = find(buffer(1:end-1) == sof0 & buffer(2:end) == sof1);
    earliestIncomplete = [];
    for k = 1:numel(syncPositions)
        p = syncPositions(k);
        remaining = numel(buffer) - p + 1;
        if remaining < 7
            if isempty(earliestIncomplete), earliestIncomplete = p; end
            continue;
        end
        payloadLength = double(buffer(p+5)) + 256 * double(buffer(p+6));
        if payloadLength > maxPayloadBytes
            badCrcCount = badCrcCount + 1;
            continue;
        end
        totalLength = 9 + payloadLength;
        if remaining < totalLength
            if isempty(earliestIncomplete), earliestIncomplete = p; end
            continue;
        end
        crcStart = p + 7 + payloadLength;
        crcReceived = bitor(bitshift(uint16(buffer(crcStart)), 8), uint16(buffer(crcStart+1)));
        crcCalculated = crc16CcittFalse(buffer(p+2:crcStart-1));
        if crcCalculated == crcReceived
            packet.type = buffer(p+2);
            packet.sequence = readLE(buffer(p+3:p+4));
            packet.payload = buffer(p+7:crcStart-1);
            packet.crc = crcReceived;
            found = true;
            droppedBytes = p - 1;
            buffer = buffer(p+totalLength:end);
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
    crc = uint16(hex2dec("FFFF"));
    polynomial = uint16(hex2dec("1021"));
    data = uint8(data(:));
    for n = 1:numel(data)
        crc = bitxor(crc, bitshift(uint16(data(n)), 8));
        for b = 1:8
            if bitand(crc, uint16(hex2dec("8000"))) ~= 0
                crc = bitxor(bitshift(crc, 1), polynomial);
            else
                crc = bitshift(crc, 1);
            end
        end
    end
end

function value = readLE(bytes)
    bytes = uint8(bytes(:));
    value = uint64(0);
    for k = 1:numel(bytes)
        value = bitor(value, bitshift(uint64(bytes(k)), 8*(k-1)));
    end
    if numel(bytes) <= 2, value = uint16(value); else, value = uint32(value); end
end

function value = readLE32(bytes)
    bytes = uint8(bytes(:));
    value = uint32(0);
    for k = 1:min(4, numel(bytes))
        value = bitor(value, bitshift(uint32(bytes(k)), 8*(k-1)));
    end
end

function crc = crc32Mpeg2(data)
% CRC-32/MPEG-2: poly=04C11DB7, init=FFFFFFFF, MSB-first, xorout=0.
    crc = uint32(hex2dec("FFFFFFFF"));
    polynomial = uint32(hex2dec("04C11DB7"));
    data = uint8(data(:));
    for n = 1:numel(data)
        for b = 7:-1:0
            inputBit = bitand(bitshift(data(n), -b), uint8(1));
            feedback = bitxor(bitget(crc, 32), uint32(inputBit));
            crc = bitshift(crc, 1);
            if feedback ~= 0, crc = bitxor(crc, polynomial); end
        end
    end
end
