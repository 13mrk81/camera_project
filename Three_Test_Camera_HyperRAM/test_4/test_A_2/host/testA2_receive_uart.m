
function report = test3_receive_uart(port)
%TEST3_RECEIVE_UART
% Receive and validate Test 3 synthetic HyperRAM readback.
%
% Synthetic pattern:
%   word[n] = 0xA5000000 XOR n
%
% Each 32-bit word is serialized MSB first into four consecutive bytes.
%
% UART:
%   115200 baud, 8-N-1, FPGA -> PC
%
% Packet:
%   A5 5A TYPE SEQ_LO SEQ_HI LEN_LO LEN_HI PAYLOAD CRC_HI CRC_LO
%
% CRC16:
%   CRC-16/CCITT-FALSE, init FFFF, poly 1021.
%
% The receiver:
%   1. Validates packet CRC16.
%   2. Reconstructs RGB565 bytes from received RGB888.
%   3. Checks every byte against the expected word-index pattern.
%   4. Reports the first mismatch and its logical word index.
%   5. Validates the CRC32 chain and DONE telemetry.

    %% Serial port selection

    if nargin < 1 || strlength(string(port)) == 0
        ports = serialportlist("available");

        if isempty(ports)
            error("No serial ports detected.");
        end

        fprintf("Available serial ports:\n");

        for k = 1:numel(ports)
            fprintf("  %d) %s\n", k, ports(k));
        end

        choice = input("Select port number: ");

        if choice < 1 || choice > numel(ports) || choice ~= floor(choice)
            error("Invalid serial-port selection.");
        end

        port = ports(choice);
    end

    %% Frame configuration

    width  = 640;
    height = 480;

    expectedRawBytes = uint32(width * height * 2);
    expectedWords = uint32(width * height / 2);
    expectedPixels = uint32(width * height);
    expectedUartBytes = uint32(width * height * 3);

    % Generate the complete expected synthetic byte stream.
    expectedPattern = generate_expected_pattern(double(expectedRawBytes));

    % Expected capture CRC is calculated from the new pattern.
    expectedCaptureCRC = crc32_msb(expectedPattern);

    fprintf("Opening %s at 115200 baud...\n", string(port));

    sp = serialport(port, 115200, ...
        "DataBits", 8, ...
        "Parity", "none", ...
        "StopBits", 1, ...
        "Timeout", 2);

    cleanupObj = onCleanup(@() delete(sp)); %#ok<NASGU>
    flush(sp);

    %% Receiver initialization

    rx = uint8([]);

    rgb = zeros(height, width, 3, "uint8");
    lineSeen = false(height, 1);

    packetCount = 0;
    badPacketCRC = 0;

    readySeen = false;
    doneSeen = false;
    errorSeen = false;

    done = struct();

    started = tic;
    overallTimeout_s = 600;

    fprintf("Waiting for FPGA packets.\n");
    fprintf("Trigger capture using KEY1 if necessary.\n");

    %% Packet reception and parsing

    while ~doneSeen && ~errorSeen

        n = sp.NumBytesAvailable;

        if n > 0
            incoming = read(sp, n, "uint8");
            rx = [rx, reshape(uint8(incoming), 1, [])]; %#ok<AGROW>
        else
            pause(0.005);
        end

        if toc(started) > overallTimeout_s
            error("Timed out before DONE/ERROR packet.");
        end

        while numel(rx) >= 2

            sof = find(rx(1:end-1) == hex2dec('A5') & ...
                       rx(2:end) == hex2dec('5A'), 1, "first");

            if isempty(sof)

                if rx(end) == hex2dec('A5')
                    rx = rx(end);
                else
                    rx = uint8([]);
                end

                break;
            end

            if sof > 1
                rx = rx(sof:end);
            end

            if numel(rx) < 7
                break;
            end

            packetType = rx(3);

            seq = double(rx(4)) + ...
                  256 * double(rx(5));

            payloadLength = double(rx(6)) + ...
                            256 * double(rx(7));

            if payloadLength > 4096
                rx = rx(2:end);
                continue;
            end

            packetLength = 9 + payloadLength;

            if numel(rx) < packetLength
                break;
            end

            packet = rx(1:packetLength);
            rx = rx(packetLength+1:end);

            crcCalculated = crc16_ccitt_false( ...
                packet(3:7+payloadLength));

            crcReceived = uint16(packet(8+payloadLength)) * 256 + ...
                          uint16(packet(9+payloadLength));

            packetCount = packetCount + 1;

            if crcCalculated ~= crcReceived

                badPacketCRC = badPacketCRC + 1;

                warning("Packet %d: CRC16 mismatch.", packetCount);
                continue;
            end

            payload = packet(8:7+payloadLength);

            switch double(packetType)

                case hex2dec('10') % STAGE

                    if numel(payload) >= 2
                        fprintf("Stage: code=0x%02X detail=0x%02X\n", ...
                            payload(1), payload(2));
                    end

                case hex2dec('11') % READY

                    if numel(payload) ~= 6
                        warning("Unexpected READY packet length.");
                        continue;
                    end

                    rxWidth = double(payload(1)) + ...
                              256 * double(payload(2));

                    rxHeight = double(payload(3)) + ...
                               256 * double(payload(4));

                    if rxWidth ~= width || ...
                       rxHeight ~= height || ...
                       payload(5) ~= 3 || ...
                       payload(6) ~= 1

                        error("Unexpected READY geometry or format.");
                    end

                    readySeen = true;

                    fprintf("READY: %dx%d RGB888 stream.\n", ...
                        width, height);

                case hex2dec('20') % LINE

                    if ~readySeen
                        warning("LINE received before READY.");
                        continue;
                    end

                    if seq >= height || payloadLength ~= width*3
                        warning("Invalid LINE seq=%d length=%d.", ...
                            seq, payloadLength);
                        continue;
                    end

                    if lineSeen(seq+1)
                        warning("Duplicate LINE %d.", seq);
                    end

                    row = reshape(payload, 3, width).';

                    rgb(seq+1,:,:) = reshape(row, 1, width, 3);

                    lineSeen(seq+1) = true;

                    if mod(seq+1, 40) == 0 || seq == height-1
                        fprintf("Received line %d/%d\n", ...
                            seq+1, height);
                    end

                case hex2dec('30') % DONE

                    if payloadLength ~= 46
                        error("Unexpected DONE payload length: %d", ...
                            payloadLength);
                    end

                    done = decode_done(payload);
                    doneSeen = true;

                case hex2dec('7F') % ERROR

                    errorSeen = true;

                    if numel(payload) >= 2
                        error("FPGA ERROR: code=0x%02X detail=0x%02X.", ...
                            payload(1), payload(2));
                    else
                        error("Malformed FPGA ERROR packet.");
                    end

                otherwise

                    warning("Unknown packet type 0x%02X.", packetType);

            end
        end
    end

    %% Check frame reception

    if ~doneSeen
        error("Capture ended without DONE packet.");
    end

    missingLines = find(~lineSeen);

    if ~isempty(missingLines)
        error("Missing %d image lines. First missing line: %d.", ...
            numel(missingLines), missingLines(1));
    end

    %% Reconstruct original RGB565 byte stream

    % The FPGA expands RGB565 components to RGB888 by bit replication.
    % Removing the replicated low bits recovers the original RGB565 values.

    raw565 = zeros(height, width*2, "uint8");

    for y = 1:height

        row = squeeze(rgb(y,:,:));

        r5 = bitshift(row(:,1), -3);
        g6 = bitshift(row(:,2), -2);
        b5 = bitshift(row(:,3), -3);

        pix = bitor(bitshift(uint16(r5), 11), ...
              bitor(bitshift(uint16(g6), 5), uint16(b5)));

        raw565(y,1:2:end) = uint8(bitshift(pix, -8));

        raw565(y,2:2:end) = uint8(bitand(pix, uint16(255)));

    end

    % Restore the original row-major byte order.
    rawBytes = reshape(raw565.', [], 1);

    %% Word-index pattern validation

    % Compare every received byte against:
    %
    %   word[n] = 0xA5000000 XOR n
    %
    % The byte index determines:
    %   word_index = floor(byte_index / 4)
    %   byte_position = byte_index mod 4
    %
    % Byte order is MSB first.

    mismatchIndex = find(rawBytes ~= expectedPattern, 1, "first");

    patternMatch = isempty(mismatchIndex);

    if patternMatch

        firstMismatchByte = NaN;
        firstMismatchWord = NaN;
        expectedMismatchByte = NaN;
        actualMismatchByte = NaN;

    else

        firstMismatchByte = mismatchIndex - 1;
        firstMismatchWord = floor(firstMismatchByte / 4);

        expectedMismatchByte = expectedPattern(mismatchIndex);
        actualMismatchByte = rawBytes(mismatchIndex);

    end

    %% CRC32 validation

    hostReadbackCRC = crc32_msb(rawBytes);

    %% DONE telemetry validation

    assert(done.height == height, "DONE height mismatch.");
    assert(done.lines == height, "DONE line count mismatch.");

    assert(done.pixels == expectedPixels, ...
        "DONE pixel count mismatch.");

    assert(done.uartBytes == expectedUartBytes, ...
        "DONE UART byte count mismatch.");

    assert(done.sourceBytes == expectedRawBytes, ...
        "DONE source byte count mismatch.");

    assert(done.captureBytes == expectedRawBytes, ...
        "DONE capture byte count mismatch.");

    assert(done.writeWords == expectedWords, ...
        "DONE write-word count mismatch.");

    assert(done.readIngressWords == expectedWords, ...
        "DONE read-ingress word count mismatch.");

    %% CRC chain

    crcMatch = ...
        (done.captureCRC == done.writeCRC) && ...
        (done.writeCRC == done.readIngressCRC) && ...
        (done.readIngressCRC == done.readbackCRC) && ...
        (hostReadbackCRC == done.readbackCRC);

    expectedCRCMatch = ...
        (done.captureCRC == expectedCaptureCRC) && ...
        (hostReadbackCRC == expectedCaptureCRC);

    %% Status flags

    % RTL:
    %   bit 0..12 : error/mismatch flags
    %   bit 13    : SYSTEM_OK
    %   bit 14..15: reserved
    %
    % MATLAB bitget uses one-based bit numbering.
    % Therefore RTL bit 13 corresponds to MATLAB bitget(...,14).

    systemOK = bitget(done.statusFlags, 14) == 1;

    errorFlagsClear = ...
        bitand(done.statusFlags, uint16(hex2dec('1FFF'))) == 0;

    reservedBitsClear = ...
        bitand(done.statusFlags, uint16(hex2dec('C000'))) == 0;

    statusValid = systemOK && errorFlagsClear && reservedBitsClear;

    %% Final report

    report = done;

    report.packetCount = packetCount;
    report.badPacketCRC = badPacketCRC;

    report.hostReadbackCRC = hostReadbackCRC;
    report.expectedCaptureCRC = expectedCaptureCRC;

    report.allLinesReceived = all(lineSeen);

    report.crcChainMatch = crcMatch;
    report.expectedCaptureCRCMatched = expectedCRCMatch;

    report.patternMatch = patternMatch;

    report.firstMismatchByte = firstMismatchByte;
    report.firstMismatchWord = firstMismatchWord;
    report.expectedMismatchByte = expectedMismatchByte;
    report.actualMismatchByte = actualMismatchByte;

    report.statusFlagsValid = statusValid;

    report.pass = ...
        crcMatch && ...
        expectedCRCMatch && ...
        patternMatch && ...
        statusValid && ...
        badPacketCRC == 0;

    report.elapsedSeconds = toc(started);

    %% Save results

    save("test3_report.mat", ...
        "report", "rgb", "raw565", "rawBytes", "expectedPattern");

    if exist("imwrite", "file") == 2
        imwrite(rgb, "test3_capture.png");
        fprintf("Saved test3_capture.png\n");
    end

    %% Print report

    fprintf("\n========== TEST 3 RESULT ==========\n");

    fprintf("Packets received             : %d\n", packetCount);
    fprintf("Bad packet CRC16             : %d\n", badPacketCRC);

    fprintf("Capture CRC32                : 0x%08X\n", done.captureCRC);
    fprintf("Writer CRC32                 : 0x%08X\n", done.writeCRC);
    fprintf("Read-ingress CRC32           : 0x%08X\n", done.readIngressCRC);
    fprintf("FPGA readback CRC32          : 0x%08X\n", done.readbackCRC);

    fprintf("Host reconstructed CRC32     : 0x%08X\n", hostReadbackCRC);
    fprintf("Expected pattern CRC32       : 0x%08X\n", expectedCaptureCRC);

    fprintf("Status flags                 : 0x%04X\n", done.statusFlags);

    fprintf("CRC chain consistent         : %s\n", string(crcMatch));
    fprintf("Expected CRC matched         : %s\n", string(expectedCRCMatch));
    fprintf("Word-index pattern matched   : %s\n", string(patternMatch));
    fprintf("Status flags valid           : %s\n", string(statusValid));

    if ~patternMatch

        fprintf("\n--- FIRST PATTERN MISMATCH ---\n");

        fprintf("Byte index (zero-based)      : %d\n", firstMismatchByte);
        fprintf("Word index                   : %d\n", firstMismatchWord);

        fprintf("Expected byte                : 0x%02X\n", ...
            expectedMismatchByte);

        fprintf("Received byte                : 0x%02X\n", ...
            actualMismatchByte);

    end

    fprintf("Elapsed                      : %.1f s\n", report.elapsedSeconds);

    if report.pass

        fprintf("\nRESULT: PASS\n");
        fprintf("The complete synthetic word-index pattern survived the capture, ");
        fprintf("HyperRAM write/read and UART path.\n");

    else

        fprintf("\nRESULT: FAIL\n");
        fprintf("Inspect the first pattern mismatch, CRC chain and status flags.\n");

    end

    if exist("imshow", "file") == 2
        figure("Name", "Test 3 Synthetic HyperRAM Readback");
        imshow(rgb);
        title("Synthetic Word-index Pattern — RGB888 Readback");
    end

end


%% ========================================================================
% Generate expected word-index pattern
% ========================================================================

function bytes = generate_expected_pattern(numberOfBytes)

    byteIndex = uint32((0:numberOfBytes-1).');

    wordIndex = bitshift(byteIndex, -2);

    wordValue = bitxor( ...
        uint32(hex2dec('A5000000')), wordIndex);

    bytePosition = mod(double(byteIndex), 4);

    bytes = zeros(numberOfBytes, 1, "uint8");

    % Extract bytes MSB first.
    for k = 0:3

        selected = (bytePosition == k);

        shiftAmount = 8 * (3-k);

        selectedWords = wordValue(selected);

        selectedBytes = bitand( ...
            bitshift(selectedWords, -shiftAmount), ...
            uint32(255));

        bytes(selected) = uint8(selectedBytes);

    end

end


%% ========================================================================
% Decode DONE telemetry
% ========================================================================

function value = read_u32_le(p, first)

    value = uint32(p(first)) + ...
            bitshift(uint32(p(first+1)), 8) + ...
            bitshift(uint32(p(first+2)), 16) + ...
            bitshift(uint32(p(first+3)), 24);

end


function d = decode_done(p)

    d.height = double(uint16(p(1)) + bitshift(uint16(p(2)),8));

    d.lines = double(uint16(p(3)) + bitshift(uint16(p(4)),8));

    d.pixels = read_u32_le(p,5);
    d.uartBytes = read_u32_le(p,9);

    d.readbackCRC = read_u32_le(p,13);
    d.captureCRC = read_u32_le(p,17);
    d.writeCRC = read_u32_le(p,21);
    d.readIngressCRC = read_u32_le(p,25);

    d.sourceBytes = read_u32_le(p,29);
    d.captureBytes = read_u32_le(p,33);

    d.writeWords = read_u32_le(p,37);
    d.readIngressWords = read_u32_le(p,41);

    d.statusFlags = uint16(p(45)) + ...
                    bitshift(uint16(p(46)),8);

end


%% ========================================================================
% CRC16-CCITT-FALSE
% ========================================================================

function crc = crc16_ccitt_false(bytes)

    c = uint16(hex2dec('FFFF'));
    poly = uint16(hex2dec('1021'));

    for k = 1:numel(bytes)

        c = bitxor(c, bitshift(uint16(bytes(k)), 8));

        for b = 1:8

            if bitget(c,16)
                c = bitxor(bitshift(c,1),poly);
            else
                c = bitshift(c,1);
            end

        end
    end

    crc = c;

end


%% ========================================================================
% CRC32 MSB-first
% ========================================================================

function crc = crc32_msb(bytes)

    c = uint32(hex2dec('FFFFFFFF'));
    poly = uint32(hex2dec('04C11DB7'));

    bytes = uint8(bytes(:));

    for k = 1:numel(bytes)

        for b = 7:-1:0

            feedback = xor(bitget(c,32), bitget(bytes(k),b+1));

            c = bitshift(c,1);

            if feedback
                c = bitxor(c,poly);
            end

        end
    end

    crc = c;

end