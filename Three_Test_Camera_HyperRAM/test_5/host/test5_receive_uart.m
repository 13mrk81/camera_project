function report = test5_receive_uart(port)
%TEST5_RECEIVE_UART Receive one Test 5 camera-PCLK/FIFO diagnostic packet.
% UART 115200 8-N-1. Packet: A5 5A TYPE SEQ_LO SEQ_HI LEN_LO LEN_HI
% PAYLOAD CRC_HI CRC_LO. TYPE=50, CRC-16/CCITT-FALSE.

    if nargin < 1 || strlength(string(port)) == 0
        ports = serialportlist("available");
        if isempty(ports), error("No serial ports detected."); end
        fprintf("Available ports:\n");
        for k = 1:numel(ports), fprintf("  %d) %s\n", k, ports(k)); end
        choice = input("Select port number: ");
        if choice < 1 || choice > numel(ports) || choice ~= floor(choice)
            error("Invalid selection.");
        end
        port = ports(choice);
    end

    sp = serialport(port, 115200, "DataBits", 8, "Parity", "none", ...
                    "StopBits", 1, "Timeout", 2);
    cleanupObj = onCleanup(@() delete(sp)); %#ok<NASGU>
    flush(sp);

    rx = uint8([]);
    started = tic;
    timeout_s = 90;
    report = struct();
    fprintf("Listening on %s at 115200 baud. Waiting for camera frame/line event...\n", string(port));

    while toc(started) < timeout_s
        n = sp.NumBytesAvailable;
        if n > 0
            incoming = read(sp, n, "uint8");
            rx = [rx, reshape(uint8(incoming), 1, [])]; %#ok<AGROW>
        else
            pause(0.005);
        end

        while numel(rx) >= 2
            sof = find(rx(1:end-1) == hex2dec('A5') & ...
                       rx(2:end) == hex2dec('5A'), 1, "first");
            if isempty(sof)
                if rx(end) == hex2dec('A5'), rx = rx(end); else, rx = uint8([]); end
                break;
            end
            if sof > 1, rx = rx(sof:end); end
            if numel(rx) < 7, break; end

            packetType = rx(3);
            seq = double(rx(4)) + 256 * double(rx(5));
            payloadLength = double(rx(6)) + 256 * double(rx(7));
            if payloadLength > 256, rx = rx(2:end); continue; end
            packetLength = 9 + payloadLength;
            if numel(rx) < packetLength, break; end

            packet = rx(1:packetLength);
            rx = rx(packetLength+1:end);
            if packetType ~= hex2dec('50')
                warning("Ignoring packet type 0x%02X.", packetType);
                continue;
            end

            payload = packet(8:7+payloadLength);
            crcCalc = crc16_ccitt_false(packet(3:7+payloadLength));
            crcRx = uint16(packet(8+payloadLength)) * 256 + uint16(packet(9+payloadLength));

            report.sequence = seq;
            report.payloadLength = payloadLength;
            report.payload = payload;
            report.message = char(payload);
            report.crcCalculated = crcCalc;
            report.crcReceived = crcRx;
            report.crcPass = (crcCalc == crcRx);
            expected = uint8('CAM_PCLK_FIFO_TO_24M_UART_TEST5!');
            report.payloadPass = isequal(payload, expected);
            report.pass = report.crcPass && report.payloadPass && payloadLength == 32;
            report.elapsedSeconds = toc(started);

            fprintf("\n========== TEST 5 RESULT ==========\n");
            fprintf("Packet sequence : %u\n", seq);
            fprintf("Payload length  : %u bytes\n", payloadLength);
            fprintf("Message         : %s\n", report.message);
            fprintf("CRC received    : 0x%04X\n", crcRx);
            fprintf("CRC calculated  : 0x%04X\n", crcCalc);
            fprintf("CRC valid       : %s\n", string(report.crcPass));
            fprintf("Payload valid   : %s\n", string(report.payloadPass));
            fprintf("RESULT          : %s\n", string(report.pass));
            return;
        end
    end

    error("Timeout: no valid Test 5 packet received within %.0f seconds. Check camera configuration, PCLK, VSYNC/HREF, FIFO, and UART.", timeout_s);
end

function crc = crc16_ccitt_false(bytes)
    c = uint16(hex2dec('FFFF'));
    poly = uint16(hex2dec('1021'));
    for k = 1:numel(bytes)
        c = bitxor(c, bitshift(uint16(bytes(k)), 8));
        for b = 1:8
            if bitget(c, 16), c = bitxor(bitshift(c, 1), poly);
            else, c = bitshift(c, 1); end
        end
    end
    crc = c;
end
