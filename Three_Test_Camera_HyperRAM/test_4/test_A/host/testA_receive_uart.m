function report = testA_receive_uart(port)
%TESTA_RECEIVE_UART Loss-preserving receiver for Test A.
% Keeps every raw UART byte and every structurally parseable packet,
% including packets whose CRC16 is bad. CRC is diagnostic, not a filter.
%
% Usage:
%   report = testA_receive_uart("/dev/ttyUSB0");
%   report = testA_receive_uart("COM5");
%   report = testA_receive_uart();

    if nargin < 1 || strlength(string(port)) == 0
        ports = serialportlist("available");
        if isempty(ports)
            error("No serial ports detected. Check the USB-UART connection.");
        end
        fprintf("Available serial ports:\n");
        for k = 1:numel(ports), fprintf("  %d) %s\n", k, ports(k)); end
        choice = input("Select port number: ");
        if choice < 1 || choice > numel(ports) || choice ~= floor(choice)
            error("Invalid serial-port selection.");
        end
        port = ports(choice);
    end

    width = 640;
    height = 480;
    maxPayloadLength = 4096;

    fprintf("Opening %s at 115200 baud...\n", string(port));
    sp = serialport(port, 115200, "DataBits", 8, "Parity", "none", ...
                    "StopBits", 1, "Timeout", 2);
    cleanupObj = onCleanup(@() delete(sp)); %#ok<NASGU>
    % A line packet is 1,929 bytes. Keep ample headroom in MATLAB's serial
    % driver buffer so brief MATLAB scheduling delays do not overflow it.
    sp.InputBufferSize = 65536;
    flush(sp);

    rawUartBytes = uint8([]);
    rx = uint8([]);
    rxStartOffset = 1;
    framingGarbage = uint8([]);
    rgb = zeros(height, width, 3, "uint8");
    lineSeen = false(height, 1);
    lineCRCValid = false(height, 1);
    linePacketIndex = zeros(height, 1);
    duplicateLines = 0;
    packetCount = 0;
    badPacketCRC = 0;
    malformedHeaders = 0;
    readySeen = false;
    doneSeen = false;
    errorSeen = false;
    timedOut = false;
    done = struct();
    fpgaError = struct();
    packetLog = struct('rawStart', {}, 'rawEnd', {}, 'packetType', {}, ...
        'seq', {}, 'payloadLength', {}, 'payload', {}, ...
        'crcReceived', {}, 'crcCalculated', {}, 'crcValid', {});
    started = tic;
    overallTimeout_s = 240;

    fprintf("Receiving. All bytes and parseable packets will be retained, CRC-bad included.\n");

    while ~doneSeen && ~errorSeen
        n = sp.NumBytesAvailable;
        if n > 0
            incoming = reshape(uint8(read(sp, n, "uint8")), 1, []);
            rawUartBytes = [rawUartBytes, incoming]; %#ok<AGROW>
            rx = [rx, incoming]; %#ok<AGROW>
        else
            pause(0.002);
        end

        if toc(started) > overallTimeout_s
            timedOut = true;
            warning("Timed out after %.0f s. Saving all data received so far.", overallTimeout_s);
            break;
        end

        while numel(rx) >= 2
            sof = find(rx(1:end-1) == hex2dec('A5') & ...
                       rx(2:end) == hex2dec('5A'), 1, "first");
            if isempty(sof)
                keepLast = (rx(end) == hex2dec('A5'));
                if keepLast
                    framingGarbage = [framingGarbage, rx(1:end-1)]; %#ok<AGROW>
                    rxStartOffset = rxStartOffset + numel(rx) - 1;
                    rx = rx(end);
                else
                    framingGarbage = [framingGarbage, rx]; %#ok<AGROW>
                    rxStartOffset = rxStartOffset + numel(rx);
                    rx = uint8([]);
                end
                break;
            end
            if sof > 1
                framingGarbage = [framingGarbage, rx(1:sof-1)]; %#ok<AGROW>
                rxStartOffset = rxStartOffset + sof - 1;
                rx = rx(sof:end);
            end
            if numel(rx) < 7, break; end

            packetType = rx(3);
            seq = double(rx(4)) + 256 * double(rx(5));
            payloadLength = double(rx(6)) + 256 * double(rx(7));
            if payloadLength > maxPayloadLength
                malformedHeaders = malformedHeaders + 1;
                framingGarbage = [framingGarbage, rx(1)]; %#ok<AGROW>
                rx = rx(2:end);
                rxStartOffset = rxStartOffset + 1;
                continue;
            end

            packetLength = 9 + payloadLength;
            if numel(rx) < packetLength
                % If this header was corrupted, look for a later complete
                % CRC-valid SOF before waiting indefinitely on a false length.
                candidate = find_crc_valid_candidate(rx, maxPayloadLength);
                if candidate > 1
                    framingGarbage = [framingGarbage, rx(1:candidate-1)]; %#ok<AGROW>
                    rxStartOffset = rxStartOffset + candidate - 1;
                    rx = rx(candidate:end);
                    continue;
                end
                break;
            end

            packet = rx(1:packetLength);
            packetOffset = rxStartOffset;
            rx = rx(packetLength+1:end);
            rxStartOffset = rxStartOffset + packetLength;

            crcCalculated = crc16_ccitt_false(packet(3:7+payloadLength));
            crcReceived = uint16(packet(8+payloadLength)) * 256 + ...
                          uint16(packet(9+payloadLength));
            crcValid = (crcCalculated == crcReceived);
            payload = packet(8:7+payloadLength);
            packetCount = packetCount + 1;

            entry = struct('rawStart', packetOffset, ...
                'rawEnd', packetOffset + packetLength - 1, ...
                'packetType', packetType, 'seq', seq, ...
                'payloadLength', payloadLength, 'payload', payload, ...
                'crcReceived', crcReceived, 'crcCalculated', crcCalculated, ...
                'crcValid', crcValid);
            packetLog(end+1) = entry; %#ok<AGROW>

            if ~crcValid
                badPacketCRC = badPacketCRC + 1;
                warning("Packet %d (type %02X, seq %d): CRC16 mismatch; payload retained.", ...
                        packetCount, packetType, seq);
            end

            % IMPORTANT: no CRC-failure continue here. Structurally valid
            % payloads are decoded and retained regardless of CRC status.
            switch double(packetType)
                case hex2dec('10') % STAGE
                    if numel(payload) >= 2
                        fprintf("Stage: code=0x%02X detail=0x%02X (CRC %s)\n", ...
                            payload(1), payload(2), crc_text(crcValid));
                    end

                case hex2dec('11') % READY
                    if numel(payload) == 6
                        rxWidth = double(payload(1)) + 256*double(payload(2));
                        rxHeight = double(payload(3)) + 256*double(payload(4));
                        readySeen = (rxWidth == width && rxHeight == height && ...
                                     payload(5) == 3 && payload(6) == 1);
                        fprintf("READY packet: %dx%d RGB888, CRC %s\n", ...
                            rxWidth, rxHeight, crc_text(crcValid));
                    else
                        warning("READY packet has unexpected length %d; retained.", numel(payload));
                    end

                case hex2dec('20') % LINE
                    if seq < height && payloadLength == width*3
                        if lineSeen(seq+1)
                            duplicateLines = duplicateLines + 1;
                            warning("Duplicate LINE %d; latest payload retained.", seq);
                        end
                        row = reshape(payload, 3, width).';
                        rgb(seq+1,:,:) = reshape(row, 1, width, 3);
                        lineSeen(seq+1) = true;
                        lineCRCValid(seq+1) = crcValid;
                        linePacketIndex(seq+1) = packetCount;
                        if mod(seq+1, 40) == 0 || seq == height-1
                            fprintf("Retained line %d/%d (CRC %s)\n", ...
                                seq+1, height, crc_text(crcValid));
                        end
                    else
                        warning("Malformed LINE packet seq=%d length=%d; raw packet retained.", ...
                            seq, payloadLength);
                    end

                case hex2dec('30') % DONE
                    if payloadLength == 46
                        done = decode_done(payload);
                        doneSeen = true;
                        fprintf("DONE received (CRC %s).\n", crc_text(crcValid));
                    else
                        warning("DONE payload length %d; expected 46. Packet retained.", payloadLength);
                    end

                case hex2dec('7F') % ERROR
                    fpgaError.payload = payload;
                    fpgaError.crcValid = crcValid;
                    errorSeen = true;
                    warning("FPGA ERROR packet received; payload retained.");

                otherwise
                    % Unknown packet types remain available in packetLog.
                    fprintf("Unknown packet type 0x%02X seq=%d (retained).\n", packetType, seq);
            end
        end
    end

    missingLines = find(~lineSeen);
    receivedLines = find(lineSeen);
    goodLines = find(lineSeen & lineCRCValid);
    badLines = find(lineSeen & ~lineCRCValid);

    % Reconstruct RGB565 only for rows actually received. Missing rows remain
    % zero-filled in rgb/raw565 and are explicitly identified by lineSeen.
    raw565 = zeros(height, width*2, "uint8");
    for y = reshape(receivedLines, 1, [])
        row = squeeze(rgb(y,:,:));
        r5 = bitshift(row(:,1), -3);
        g6 = bitshift(row(:,2), -2);
        b5 = bitshift(row(:,3), -3);
        pix = bitor(bitshift(uint16(r5), 11), ...
              bitor(bitshift(uint16(g6), 5), uint16(b5)));
        raw565(y,1:2:end) = uint8(bitshift(pix, -8));
        raw565(y,2:2:end) = uint8(bitand(pix, uint16(255)));
    end

    if all(lineSeen)
        rawBytes = reshape(raw565.', [], 1);
        hostReadbackCRC = crc32_msb(rawBytes);
        expectedWords = uint32(width*height/2);
        receivedWords = bitshift(uint32(rawBytes(1:4:end)), 24) + ...
                        bitshift(uint32(rawBytes(2:4:end)), 16) + ...
                        bitshift(uint32(rawBytes(3:4:end)), 8) + ...
                        uint32(rawBytes(4:4:end));
        wordIndices = uint32((0:double(expectedWords)-1).');
        expectedWordValues = bitxor(repmat(uint32(hex2dec('A5000000')), ...
                                      double(expectedWords), 1), wordIndices);
        wordMismatchIndices = find(receivedWords ~= expectedWordValues);
        wordMismatchCount = numel(wordMismatchIndices);
        if isempty(wordMismatchIndices), firstMismatchWord = NaN;
        else, firstMismatchWord = wordMismatchIndices(1)-1; end
    else
        rawBytes = uint8([]);
        hostReadbackCRC = NaN;
        wordMismatchCount = NaN;
        firstMismatchWord = NaN;
    end

    report = struct();
    report.packetCount = packetCount;
    report.badPacketCRC = badPacketCRC;
    report.malformedHeaders = malformedHeaders;
    report.rawByteCount = numel(rawUartBytes);
    report.rawUartBytes = rawUartBytes;
    report.framingGarbage = framingGarbage;
    report.unparsedTail = rx;
    report.packetLog = packetLog;
    report.readySeen = readySeen;
    report.doneSeen = doneSeen;
    report.timedOut = timedOut;
    report.fpgaError = fpgaError;
    report.done = done;
    report.lineSeen = lineSeen;
    report.lineCRCValid = lineCRCValid;
    report.linePacketIndex = linePacketIndex;
    report.missingLines = missingLines;
    report.goodLines = goodLines;
    report.badLines = badLines;
    report.duplicateLines = duplicateLines;
    report.receivedLineCount = numel(receivedLines);
    report.hostReadbackCRC = hostReadbackCRC;
    report.wordMismatchCount = wordMismatchCount;
    report.firstMismatchWord = firstMismatchWord;
    report.elapsedSeconds = toc(started);
    report.pass = false; % This run is diagnostic until all checks are reviewed.

    save("testA_report.mat", "report", "rgb", "raw565", "rawBytes", ...
         "rawUartBytes", "packetLog", "rx", "framingGarbage", ...
         "lineSeen", "lineCRCValid", "done");

    if exist("imwrite", "file") == 2
        imwrite(rgb, "testA_capture_all_received.png");
        fprintf("Saved testA_capture_all_received.png (missing rows are black).\n");
    end
    if exist("imshow", "file") == 2
        figure("Name", "Test A — all received line payloads");
        imshow(rgb);
        title("All structurally valid received LINE payloads; CRC state is separate");
    end

    fprintf("\n========== TEST A DIAGNOSTIC RESULT ==========\n");
    fprintf("Raw UART bytes retained       : %d\n", numel(rawUartBytes));
    fprintf("Packets parsed                : %d\n", packetCount);
    fprintf("CRC16 bad packets             : %d\n", badPacketCRC);
    fprintf("Malformed headers             : %d\n", malformedHeaders);
    fprintf("Lines retained                : %d/%d\n", numel(receivedLines), height);
    fprintf("Lines CRC valid               : %d\n", numel(goodLines));
    fprintf("Lines CRC bad                 : %d\n", numel(badLines));
    fprintf("Missing line indices          : ");
    fprintf("%d ", missingLines-1); fprintf("\n");
    fprintf("Duplicate lines               : %d\n", duplicateLines);
    fprintf("DONE received                 : %s\n", string(doneSeen));
    fprintf("Timeout                       : %s\n", string(timedOut));
    fprintf("Elapsed                       : %.1f s\n", report.elapsedSeconds);
    fprintf("All raw bytes and packet payloads are saved in testA_report.mat.\n");
end

function candidate = find_crc_valid_candidate(buf, maxPayloadLength)
    candidate = 0;
    if numel(buf) < 11, return; end
    for k = 2:numel(buf)-8
        if buf(k) ~= hex2dec('A5') || buf(k+1) ~= hex2dec('5A'), continue; end
        len = double(buf(k+5)) + 256*double(buf(k+6));
        if len > maxPayloadLength, continue; end
        total = 9 + len;
        if k+total-1 > numel(buf), continue; end
        pkt = buf(k:k+total-1);
        calc = crc16_ccitt_false(pkt(3:7+len));
        got = uint16(pkt(8+len))*256 + uint16(pkt(9+len));
        if calc == got
            candidate = k;
            return;
        end
    end
end

function s = crc_text(valid)
    if valid, s = "OK"; else, s = "BAD"; end
end

function d = decode_done(p)
    d.height          = double(uint16(p(1)) + bitshift(uint16(p(2)),8));
    d.lines           = double(uint16(p(3)) + bitshift(uint16(p(4)),8));
    d.pixels           = read_u32_le(p,5);
    d.uartBytes        = read_u32_le(p,9);
    d.readbackCRC      = read_u32_le(p,13);
    d.captureCRC       = read_u32_le(p,17);
    d.writeCRC         = read_u32_le(p,21);
    d.readIngressCRC   = read_u32_le(p,25);
    d.sourceBytes      = read_u32_le(p,29);
    d.captureBytes     = read_u32_le(p,33);
    d.writeWords       = read_u32_le(p,37);
    d.readIngressWords = read_u32_le(p,41);
    d.statusFlags      = uint16(p(45)) + bitshift(uint16(p(46)),8);
end

function value = read_u32_le(p, first)
    value = uint32(p(first)) + bitshift(uint32(p(first+1)), 8) + ...
            bitshift(uint32(p(first+2)), 16) + bitshift(uint32(p(first+3)), 24);
end

function crc = crc16_ccitt_false(bytes)
    c = uint16(hex2dec('FFFF'));
    poly = uint16(hex2dec('1021'));
    for k = 1:numel(bytes)
        c = bitxor(c, bitshift(uint16(bytes(k)), 8));
        for b = 1:8
            if bitget(c,16), c = bitxor(bitshift(c,1),poly);
            else, c = bitshift(c,1); end
        end
    end
    crc = c;
end

function crc = crc32_msb(bytes)
    c = uint32(hex2dec('FFFFFFFF'));
    poly = uint32(hex2dec('04C11DB7'));
    bytes = uint8(bytes(:));
    for k = 1:numel(bytes)
        for b = 7:-1:0
            feedback = xor(bitget(c,32), bitget(bytes(k),b+1));
            c = bitshift(c,1);
            if feedback, c = bitxor(c,poly); end
        end
    end
    crc = c;
end
