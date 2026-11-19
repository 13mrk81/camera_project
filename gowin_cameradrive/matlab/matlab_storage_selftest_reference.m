function ref = matlab_storage_selftest_reference(width, height)
% MATLAB_STORAGE_SELFTEST_REFERENCE
% Independent reference model for storage_test_pattern_generator.vhd.
%
% RGB565 pixel:
%   P(x,y) = mod(251*x + 911*y + 13*x*y + hex2dec('A65C'), 65536)
% Wire order per pixel is MSB byte followed by LSB byte.
% CRC32 is the FPGA's non-reflected, MSB-first implementation:
% poly=04C11DB7, init=FFFFFFFF, xorout=00000000.

    if nargin < 1, width = 640; end
    if nargin < 2, height = 480; end

    validateattributes(width, {'numeric'}, {'scalar','integer','positive','even'});
    validateattributes(height, {'numeric'}, {'scalar','integer','positive'});

    [x, y] = meshgrid(uint64(0:width-1), uint64(0:height-1));
    p64 = mod(uint64(251).*x + uint64(911).*y + ...
              uint64(13).*x.*y + uint64(hex2dec('A65C')), uint64(65536));
    p = uint16(p64);

    % Exact byte order presented to the RGB565 frame packer.
    raw = zeros(height, width*2, 'uint8');
    raw(:,1:2:end) = uint8(bitshift(p, -8));
    raw(:,2:2:end) = uint8(bitand(p, uint16(255)));

    % Match rgb565_line_serializer.vhd bit replication exactly.
    r5 = uint8(bitand(bitshift(p, -11), uint16(31)));
    g6 = uint8(bitand(bitshift(p, -5), uint16(63)));
    b5 = uint8(bitand(p, uint16(31)));

    r8 = bitor(bitshift(r5, 3), bitshift(r5, -2));
    g8 = bitor(bitshift(g6, 2), bitshift(g6, -4));
    b8 = bitor(bitshift(b5, 3), bitshift(b5, -2));

    rgb888 = zeros(height, width, 3, 'uint8');
    rgb888(:,:,1) = r8;
    rgb888(:,:,2) = g8;
    rgb888(:,:,3) = b8;

    % Flatten row by row, matching the FPGA's left-to-right line stream.\n    rawVector = reshape(raw.', [], 1);
    ref.width = width;
    ref.height = height;
    ref.rgb565 = p;
    ref.rawBytes = rawVector;
    ref.rgb888 = rgb888;
    ref.expectedRawBytes = uint32(width) * uint32(height) * uint32(2);
    ref.expectedWords32 = idivide(uint32(width) * uint32(height), uint32(2));
    ref.expectedPixels = uint32(width) * uint32(height);
    ref.expectedUartBytes = uint32(width) * uint32(height) * uint32(3);
    ref.expectedCaptureCrc32 = crc32MsbFirst(rawVector);
end

function crc = crc32MsbFirst(data)
    crc = uint32(hex2dec('FFFFFFFF'));
    polynomial = uint32(hex2dec('04C11DB7'));
    data = uint8(data(:));

    for n = 1:numel(data)
        crc = bitxor(crc, bitshift(uint32(data(n)), 24));
        for k = 1:8
            if bitget(crc, 32)
                crc = bitxor(bitshift(crc, 1), polynomial);
            else
                crc = bitshift(crc, 1);
            end
        end
    end
end
