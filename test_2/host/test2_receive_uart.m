function report = test2_receive_uart(port)
%TEST2_RECEIVE_UART Receive and validate the Test 2 GC0308/HyperRAM stream.
%
% Usage:
%   report = test2_receive_uart("COM5");       % Windows
%   report = test2_receive_uart("/dev/ttyUSB0"); % Linux
%   report = test2_receive_uart();             % choose from detected ports
%
% UART: 115200 baud, 8-N-1. FPGA -> PC only.
% Packet: A5 5A TYPE SEQ_LO SEQ_HI LEN_LO LEN_HI PAYLOAD CRC_HI CRC_LO
% CRC16: CRC-16/CCITT-FALSE, init FFFF, poly 1021, no reflection/xorout.
%
% The receiver validates every packet CRC, line sequence/count, DONE telemetry,
% the reconstructed RGB565 readback CRC, and Test 2's expected capture CRC.
% It saves test2_capture.png and test2_report.mat in the current directory.

    if nargin < 1 || strlength(string(port)) == 0
        ports = serialportlist("available");
        if isempty(ports)
            error("No serial ports detected. Check the USB-UART connection.");
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

    width = 640;
    height = 480;
    expectedRawBytes = uint32(width * height * 2);
    expectedWords = uint32(width * height / 2);
    expectedPixels = uint32(width * height);
    expectedUartBytes = uint32(width * height * 3);
    expectedCaptureCRC = uint32(hex2dec('81BD9BFE'));

    fprintf("Opening %s at 115200 baud...\n", string(port));
    sp = serialport(port, 115200, "DataBits", 8, "Parity", "none", ...
                    "StopBits", 1, "Timeout", 2);
    cleanupObj = onCleanup(@() delete(sp)); %#ok<NASGU>
    flush(sp);

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
    overallTimeout_s = 240;

    fprintf("Waiting for FPGA packets. Trigger the capture with KEY1 if needed.\n");

    while ~doneSeen && ~errorSeen
        n = sp.NumBytesAvailable;
        if n > 0
            incoming = read(sp, n, "uint8");
            rx = [rx, reshape(uint8(incoming), 1, [])]; %#ok<AGROW>
        else
            pause(0.005);
        end

        if toc(started) > overallTimeout_s
            error("Timed out after %.0f s before DONE/ERROR packet.", overallTimeout_s);
        end

        % Parse all complete packets currently buffered.
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
            seq = double(rx(4)) + 256 * double(rx(5));
            payloadLength = double(rx(6)) + 256 * double(rx(7));
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
            crcCalculated = crc16_ccitt_false(packet(3:7+payloadLength));
            crcReceived = uint16(packet(8+payloadLength)) * 256 + ...
                          uint16(packet(9+payloadLength));
            packetCount = packetCount + 1;

            if crcCalculated ~= crcReceived
                badPacketCRC = badPacketCRC + 1;
                warning("Packet %d (type %02X, seq %d): CRC16 mismatch.", ...
                        packetCount, packetType, seq);
                continue;
            end

            payload = packet(8:7+payloadLength);

            switch double(packetType)
                case hex2dec('10') % STAGE [stage, detail]
                    if numel(payload) >= 2
                        fprintf("Stage: code=0x%02X detail=0x%02X\n", ...
                                payload(1), payload(2));
                    end

                case hex2dec('11') % READY [width, height, format=03, channels=01]
                    if numel(payload) ~= 6
                        warning("READY packet has unexpected length %d.", numel(payload));
                        continue;
                    end
                    rxWidth = double(payload(1)) + 256*double(payload(2));
                    rxHeight = double(payload(3)) + 256*double(payload(4));
                    if rxWidth ~= width || rxHeight ~= height || ...
                       payload(5) ~= 3 || payload(6) ~= 1
                        error("Unexpected READY geometry/format: %dx%d, format %d, channels %d.", ...
                              rxWidth, rxHeight, payload(5), payload(6));
                    end
                    readySeen = true;
                    fprintf("READY: %dx%d RGB888 stream.\n", width, height);

                case hex2dec('20') % LINE, payload is RGB888 triplets
                    if ~readySeen
                        warning("LINE received before READY; ignoring.");
                        continue;
                    end
                    if seq >= height || payloadLength ~= width*3
                        warning("Invalid LINE seq=%d length=%d.", seq, payloadLength);
                        continue;
                    end
                    if lineSeen(seq+1)
                        warning("Duplicate LINE %d; replacing previous row.", seq);
                    end
                    row = reshape(payload, 3, width).';
                    rgb(seq+1,:,:) = reshape(row, 1, width, 3);
                    lineSeen(seq+1) = true;
                    if mod(seq+1, 40) == 0 || seq == height-1
                        fprintf("Received line %d/%d\n", seq+1, height);
                    end

                case hex2dec('30') % DONE, fixed 46-byte telemetry
                    if payloadLength ~= 46
                        error("DONE payload length is %d; expected 46.", payloadLength);
                    end
                    done = decode_done(payload);
                    doneSeen = true;

                case hex2dec('7F') % ERROR [code, detail]
                    errorSeen = true;
                    if numel(payload) >= 2
                        error("FPGA ERROR packet: code=0x%02X detail=0x%02X.", ...
                              payload(1), payload(2));
                    else
                        error("FPGA sent an ERROR packet with malformed payload.");
                    end

                otherwise
                    warning("Unknown packet type 0x%02X (seq %d).", packetType, seq);
            end
        end
    end

    if ~doneSeen
        error("Capture ended without a DONE packet.");
    end

    missingLines = find(~lineSeen);
    if ~isempty(missingLines)
        error("DONE received, but %d image lines are missing (first missing: %d).", ...
              numel(missingLines), missingLines(1));
    end

    % Recreate the original RGB565 byte stream from the losslessly expanded
    % RGB888 values. The FPGA serializer expands by bit replication, so the
    % most-significant 5/6/5 bits recover each original component exactly.
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
    hostReadbackCRC = crc32_msb(reshape(raw565.', [], 1));

    % Validate DONE telemetry.
    assert(done.height == height, "DONE height mismatch.");
    assert(done.lines == height, "DONE line count mismatch.");
    assert(done.pixels == expectedPixels, "DONE pixel count mismatch.");
    assert(done.uartBytes == expectedUartBytes, "DONE UART byte count mismatch.");
    assert(done.sourceBytes == expectedRawBytes, "DONE source byte count mismatch.");
    assert(done.captureBytes == expectedRawBytes, "DONE capture byte count mismatch.");
    assert(done.writeWords == expectedWords, "DONE write-word count mismatch.");
    assert(done.readIngressWords == expectedWords, "DONE read-ingress word count mismatch.");

    crcMatch = (done.captureCRC == done.writeCRC) && ...
               (done.writeCRC == done.readIngressCRC) && ...
               (done.readIngressCRC == done.readbackCRC) && ...
               (hostReadbackCRC == done.readbackCRC);
    expectedMatch = (done.captureCRC == expectedCaptureCRC);
    statusClear = (done.statusFlags == 0);

    report = done;
    report.packetCount = packetCount;
    report.badPacketCRC = badPacketCRC;
    report.hostReadbackCRC = hostReadbackCRC;
    report.expectedCaptureCRC = expectedCaptureCRC;
    report.allLinesReceived = all(lineSeen);
    report.crcChainMatch = crcMatch;
    report.expectedCaptureCRCMatched = expectedMatch;
    report.statusFlagsClear = statusClear;
    report.elapsedSeconds = toc(started);

    save("test2_report.mat", "report", "rgb", "raw565");
    if exist("imwrite", "file") == 2
        imwrite(rgb, "test2_capture.png");
        fprintf("Saved test2_capture.png\\n");
    else
        warning("imwrite is unavailable; image is preserved in test2_report.mat.");
    end

    fprintf("\n========== TEST 2 RESULT ==========\n");
    fprintf("Packets received             : %d\n", packetCount);
    fprintf("Bad packet CRC16             : %d\n", badPacketCRC);
    fprintf("Capture CRC32                : 0x%08X\n", done.captureCRC);
    fprintf("Writer CRC32                 : 0x%08X\n", done.writeCRC);
    fprintf("Read-ingress CRC32           : 0x%08X\n", done.readIngressCRC);
    fprintf("FPGA readback CRC32          : 0x%08X\n", done.readbackCRC);
    fprintf("Host reconstructed CRC32     : 0x%08X\n", hostReadbackCRC);
    fprintf("Expected synthetic CRC32     : 0x%08X\n", expectedCaptureCRC);
    fprintf("Status flags                 : 0x%04X\n", done.statusFlags);
    fprintf("CRC chain consistent         : %s\n", string(crcMatch));
    fprintf("Expected capture CRC matched : %s\n", string(expectedMatch));
    fprintf("Status flags clear           : %s\n", string(statusClear));
    fprintf("Elapsed                      : %.1f s\n", report.elapsedSeconds);

    if crcMatch && expectedMatch && statusClear && badPacketCRC == 0
        fprintf("RESULT: PASS — synthetic payload survived the capture/write/read/host path.\n");
    else
        fprintf("RESULT: FAIL — inspect the first differing CRC, counters, and status bits.\n");
    end
    if exist("imshow", "file") == 2
        figure("Name", "Test 2 synthetic HyperRAM readback");
        imshow(rgb);
        title("Test 2 — RGB888 reconstructed from HyperRAM readback");
    else
        fprintf("imshow unavailable; inspect variable rgb or test2_report.mat.\\n");
    end
end

function value = read_u32_le(p, first)
    value = uint32(p(first)) + bitshift(uint32(p(first+1)), 8) + ...
            bitshift(uint32(p(first+2)), 16) + bitshift(uint32(p(first+3)), 24);
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
    crc = c; % no final XOR, matching the RTL telemetry convention
end
