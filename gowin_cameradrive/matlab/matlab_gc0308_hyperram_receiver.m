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
portName = "/dev/ttyUSB0";
baudRate = 115200;

% The current FPGA design sends 640x480 RGB565:
% 480 LINE packets x (9 framing/CRC bytes + 1280 payload bytes)
% plus 3 STAGE, 1 READY and 1 DONE control packets.
expectedWidth = 640;
expectedHeight = 480;
linePayloadBytes = expectedWidth * 2;
linePacketBytes = 9 + linePayloadBytes;
expectedTransferBytes = expectedHeight * linePacketBytes + 3*11 + 15 + 25;

% The complete transfer takes substantially longer than 25 s:
% UART 8N1 lower bound ~= 53.7 s, plus FPGA inter-byte and packet gaps.
overallTimeout_s = 180;
inactivityTimeout_s = 10;
readChunkBytes = 8192;
maxPayloadBytes = 65535;

%% Open UART in receive-only mode
sp = serialport(portName, baudRate, ...
    "DataBits", 8, "Parity", "none", "StopBits", 1, ...
    "FlowControl", "none", "Timeout", 2);
flush(sp);

fprintf("UART opened: %s @ %d baud, 8N1 (receive-only).\n", char(portName), baudRate);
fprintf("Expected transfer: %d bytes (640x480 RGB565).\n", expectedTransferBytes);
fprintf("Press KEY1 on the FPGA board. Bytes will be collected first; CRC is processed only after reception.\n");

% Preallocate the complete transfer buffer. No packet CRC calculation,
% image conversion, plotting, or console output occurs in the receive loop.
rawStream = zeros(expectedTransferBytes, 1, "uint8");
receivedByteCount = 0;
maxDriverQueueBytes = 0;
lastDataTime = tic;
totalTime = tic;
lastProgress = 0;

while receivedByteCount < expectedTransferBytes
    available = double(sp.NumBytesAvailable);
    maxDriverQueueBytes = max(maxDriverQueueBytes, available);

    if available > 0
        n = min([available, readChunkBytes, expectedTransferBytes - receivedByteCount]);
        chunk = read(sp, n, "uint8");
        nRead = numel(chunk);
        if nRead > 0
            rawStream(receivedByteCount + (1:nRead)) = uint8(chunk(:));
            receivedByteCount = receivedByteCount + nRead;
            lastDataTime = tic;
        end
    else
        if toc(lastDataTime) >= inactivityTimeout_s
            fprintf(2, "\nUART inactivity timeout. Captured %d/%d bytes.\n", ...
                receivedByteCount, expectedTransferBytes);
            break;
        end
        if toc(totalTime) >= overallTimeout_s
            fprintf(2, "\nOverall receive timeout. Captured %d/%d bytes.\n", ...
                receivedByteCount, expectedTransferBytes);
            break;
        end
        pause(0.001);
    end

    progress = floor(100 * receivedByteCount / expectedTransferBytes);
    if progress >= lastProgress + 10
        lastProgress = progress;
        fprintf("Captured %d/%d bytes (%d%%).\n", ...
            receivedByteCount, expectedTransferBytes, progress);
    end
end

rawStream = rawStream(1:receivedByteCount);
fprintf("\nRaw UART capture finished: %d bytes in %.1f s.\n", ...
    receivedByteCount, toc(totalTime));
fprintf("Maximum observed serial driver queue: %d bytes.\n", maxDriverQueueBytes);

%% Offline packet extraction and CRC validation
% The UART receive loop above is deliberately independent of CRC workload.
% All CRC-16 checks and packet recovery happen now, after capture is complete.
rxBuffer = rawStream;
acceptedLines = 0;
duplicateLines = 0;
outOfOrderLines = 0;
badCrcCandidates = 0;
discardedBytes = 0;
receivedRows = false(expectedHeight, 1);
raw565Bytes = zeros(expectedHeight, linePayloadBytes, "uint8");
raw565Frame = zeros(expectedHeight, expectedWidth, "uint16");
frameReady = false;
frameComplete = false;
gotDone = false;
gotError = false;
doneStats = struct();
receiverState = "PARSING";
nextExpectedRow = 0;
packetCount = 0;
lastErrorCode = uint8(0);
lastErrorDetail = uint8(0);

while numel(rxBuffer) >= 2
    [packet, found, rxBuffer, droppedNow, badNow] = ...
        extractValidPacket(rxBuffer, maxPayloadBytes);
    discardedBytes = discardedBytes + droppedNow;
    badCrcCandidates = badCrcCandidates + badNow;

    if ~found
        break;
    end
    packetCount = packetCount + 1;

    switch double(packet.type)
        case hex2dec("10")  % STAGE
            if numel(packet.payload) == 2
                fprintf("[STAGE] code=%d detail=0x%02X\n", ...
                    packet.payload(1), packet.payload(2));
            end

        case hex2dec("11")  % READY
            if numel(packet.payload) ~= 6
                fprintf(2, "Malformed READY packet (length=%d).\n", numel(packet.payload));
                continue;
            end
            width = double(readLE(packet.payload(1:2)));
            height = double(readLE(packet.payload(3:4)));
            bytesPerPixel = double(packet.payload(5));
            pixelFormat = double(packet.payload(6));
            if width ~= expectedWidth || height ~= expectedHeight || ...
                    bytesPerPixel ~= 2 || pixelFormat ~= 2
                error("Unexpected READY format/geometry: %dx%d, BPP=%d, format=%d.", ...
                    width, height, bytesPerPixel, pixelFormat);
            end
            frameReady = true;
            fprintf("[READY] %d x %d RGB565.\n", width, height);

        case hex2dec("20")  % LINE
            if ~frameReady
                fprintf(2, "LINE before READY; sequence=%d ignored.\n", packet.sequence);
                continue;
            end
            row = double(packet.sequence);
            if row >= height || numel(packet.payload) ~= linePayloadBytes
                fprintf(2, "Invalid LINE: row=%d, payload=%d bytes.\n", ...
                    row, numel(packet.payload));
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

            raw565Bytes(row + 1, :) = reshape(packet.payload(:), 1, linePayloadBytes);
            hi = uint16(packet.payload(1:2:end));
            lo = uint16(packet.payload(2:2:end));
            raw565Frame(row + 1, :) = bitor(bitshift(hi, 8), lo).';
            receivedRows(row + 1) = true;
            acceptedLines = acceptedLines + 1;
            nextExpectedRow = row + 1;

        case hex2dec("30")  % DONE
            if numel(packet.payload) ~= 16
                fprintf(2, "Malformed DONE packet (length=%d).\n", numel(packet.payload));
                continue;
            end
            doneStats.height = double(readLE(packet.payload(1:2)));
            doneStats.lines = double(readLE(packet.payload(3:4)));
            doneStats.pixels = double(readLE(packet.payload(5:8)));
            doneStats.uartBytes = double(readLE(packet.payload(9:12)));
            doneStats.rawRgb565Crc32 = readLE32(packet.payload(13:16));
            gotDone = true;

        case hex2dec("7F")  % ERROR
            if numel(packet.payload) == 2
                lastErrorCode = packet.payload(1);
                lastErrorDetail = packet.payload(2);
                gotError = true;
                fprintf(2, "[FPGA ERROR] code=0x%02X detail=0x%02X\n", ...
                    lastErrorCode, lastErrorDetail);
            end
        otherwise
            fprintf(2, "Unknown packet type 0x%02X, sequence=%d.\n", ...
                packet.type, packet.sequence);
    end
end

% Include any trailing bytes that could not form a valid packet.
discardedBytes = discardedBytes + numel(rxBuffer);
matlabRawCrc32 = uint32(0);
if frameReady && all(receivedRows)
    wireByteStream = reshape(raw565Bytes.', [], 1);
    matlabRawCrc32 = crc32Mpeg2(wireByteStream);
end

frameComplete = frameReady && gotDone && ~gotError && ...
    doneStats.height == height && doneStats.lines == height && ...
    doneStats.pixels == width * height && ...
    doneStats.uartBytes == width * height * 2 && ...
    all(receivedRows) && ...
    matlabRawCrc32 == doneStats.rawRgb565Crc32;

if frameComplete
    receiverState = "COMPLETE";
else
    receiverState = "INCOMPLETE";
end

fprintf("\nReceiver state: %s\n", receiverState);
fprintf("Packets parsed: %d\n", packetCount);
fprintf("Valid LINE packets: %d/%d | duplicates: %d | out-of-order: %d\n", ...
    acceptedLines, expectedHeight, duplicateLines, outOfOrderLines);
fprintf("Rejected CRC candidates: %d | discarded bytes: %d\n", ...
    badCrcCandidates, discardedBytes);
fprintf("UART bytes captured: %d / expected %d\n", ...
    receivedByteCount, expectedTransferBytes);

if gotDone
    fprintf("FPGA: lines=%d, pixels=%d, bytes=%d, RGB565 CRC32=%08X\n", ...
        doneStats.lines, doneStats.pixels, doneStats.uartBytes, doneStats.rawRgb565Crc32);
    if all(receivedRows)
        fprintf("MATLAB RGB565 CRC32: %08X | match=%s\n", ...
            matlabRawCrc32, string(matlabRawCrc32 == doneStats.rawRgb565Crc32));
    end
end

%% Reconstruct and display RGB565 with zero-padding
% RGB565 -> 8-bit display channels by zero-padding at the LSB side:
% R5 << 3, G6 << 2, B5 << 3. No bit replication/scaling is applied.
if frameReady
    rgbZeroPadded = decodeRgb565ZeroPad(raw565Frame);

    % Show all six channel permutations for mapping/order diagnosis.
    channelOrders = ["RGB", "RBG", "GRB", "GBR", "BRG", "BGR"];
    channelIndex = [1 2 3; 1 3 2; 2 1 3; 2 3 1; 3 1 2; 3 2 1];

    figure("Name", "GC0308 RGB565 - zero padded channel mappings", ...
        "Color", "w");
    tiledlayout(2, 3, "Padding", "compact", "TileSpacing", "compact");
    for k = 1:6
        nexttile;
        mappedImage = rgbZeroPadded(:, :, channelIndex(k, :));
        imshow(mappedImage);
        title(channelOrders(k) + " (zero padded)");
    end

    figure("Name", "GC0308 received row validity", "Color", "w");
    imagesc(receivedRows);
    colormap gray;
    axis tight;
    title(sprintf("CRC-valid rows: %d/%d", acceptedLines, expectedHeight));
    xlabel("Frame row index");
    ylabel("Received");

    save("uart_received_frame.mat", "rawStream", "raw565Frame", "raw565Bytes", ...
        "rgbZeroPadded", "width", "height", "receivedRows", "frameComplete", ...
        "matlabRawCrc32", "acceptedLines", "duplicateLines", "outOfOrderLines", ...
        "badCrcCandidates", "discardedBytes", "doneStats", "gotDone", "gotError", ...
        "receivedByteCount", "expectedTransferBytes", "maxDriverQueueBytes", ...
        "lastErrorCode", "lastErrorDetail", "channelOrders");
    fprintf("Saved raw capture, reconstructed frame, and statistics to uart_received_frame.mat\n");
else
    save("uart_received_frame.mat", "rawStream", "receivedByteCount", ...
        "expectedTransferBytes", "maxDriverQueueBytes", "badCrcCandidates", ...
        "discardedBytes", "gotError", "lastErrorCode", "lastErrorDetail");
    fprintf(2, "READY was not recovered; raw UART capture and statistics were saved.\n");
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

function rgb = decodeRgb565ZeroPad(frame)
    p = uint16(frame);
    r5 = bitshift(bitand(p, uint16(63488)), -11);
    g6 = bitshift(bitand(p, uint16(2016)), -5);
    b5 = bitand(p, uint16(31));
    % Zero-pad the missing least-significant bits; do not replicate MSBs.
    r8 = uint8(bitshift(r5, 3));
    g8 = uint8(bitshift(g6, 2));
    b8 = uint8(bitshift(b5, 3));
    rgb = cat(3, r8, g8, b8);
end

function crc = crc32Mpeg2(data)
% CRC-32/MPEG-2 convention used by the FPGA:
% poly=0x04C11DB7, init=0xFFFFFFFF, MSB-first, xorout=0.
% This checks the original RGB565 byte stream, before display decoding.
    crc = uint32(hex2dec("FFFFFFFF"));
    polynomial = uint32(hex2dec("04C11DB7"));
    data = uint8(data(:));
    for n = 1:numel(data)
        for bitNumber = 7:-1:0
            inputBit = bitand(bitshift(data(n), -bitNumber), uint8(1));
            feedback = bitxor(bitget(crc, 32), uint32(inputBit));
            crc = bitshift(crc, 1);
            if feedback ~= 0
                crc = bitxor(crc, polynomial);
            end
        end
    end
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
