%% Offline GC0308 RGB565 byte-order and channel-order analysis
% Uses raw bytes captured by matlab_gc0308_hyperram_receiver.m.
% No FPGA/UART transfer is needed for these experiments.

clear;
clc;
close all;

captureFile = "uart_received_frame.mat";
S = load(captureFile, "raw565Bytes", "width", "height", ...
    "frameComplete", "receivedRows");

assert(isfield(S, "raw565Bytes"), "Capture does not contain raw565Bytes.");
assert(isfield(S, "width") && isfield(S, "height"), "Missing frame geometry.");
assert(all(S.receivedRows), "Capture contains missing/corrupt rows.");
assert(S.frameComplete, "Capture is not marked complete.");

W = double(S.width);
H = double(S.height);
wireBytes = uint8(S.raw565Bytes);
assert(isequal(size(wireBytes), [H, 2*W]), ...
    "Raw byte matrix has an unexpected size.");

% Candidate A: FPGA wire contract, high byte then low byte per pixel.
hi = uint16(wireBytes(:,1:2:end));
lo = uint16(wireBytes(:,2:2:end));
rgb565_msb = bitor(bitshift(hi, 8), lo);

% Candidate B: byte-swapped 16-bit words.
rgb565_lsb = bitor(bitshift(lo, 8), hi);

candidates = {
    decode565(rgb565_msb, "RGB"), "MSB-first / RGB565";
    decode565(rgb565_msb, "BGR"), "MSB-first / BGR565";
    decode565(rgb565_lsb, "RGB"), "LSB-first / RGB565";
    decode565(rgb565_lsb, "BGR"), "LSB-first / BGR565"
};

figure("Name", "GC0308 RGB565 interpretation candidates", "Color", "w");
for k = 1:size(candidates,1)
    subplot(2,2,k);
    imshow(candidates{k,1});
    title(candidates{k,2}, "Interpreter", "none");
end

imwrite(candidates{1,1}, "gc0308_msb_rgb565.png");
imwrite(candidates{2,1}, "gc0308_msb_bgr565.png");
imwrite(candidates{3,1}, "gc0308_lsb_rgb565.png");
imwrite(candidates{4,1}, "gc0308_lsb_bgr565.png");

save("gc0308_rgb565_offline_candidates.mat", ...
    "wireBytes", "rgb565_msb", "rgb565_lsb", "candidates", "W", "H");

fprintf("Loaded one captured frame: %d x %d pixels.\n", W, H);
fprintf("Generated four offline interpretations; no FPGA transfer was performed.\n");
fprintf("Wire byte order in this revision is high byte then low byte per pixel.\n");

function rgb = decode565(frame, channelOrder)
    p = uint16(frame);
    c5a = bitshift(bitand(p, uint16(63488)), -11);
    c6  = bitshift(bitand(p, uint16(2016)), -5);
    c5b = bitand(p, uint16(31));

    c8a = uint8(bitor(bitshift(c5a, 3), bitshift(c5a, -2)));
    g8  = uint8(bitor(bitshift(c6, 2), bitshift(c6, -4)));
    c8b = uint8(bitor(bitshift(c5b, 3), bitshift(c5b, -2)));

    switch upper(channelOrder)
        case "RGB"
            rgb = cat(3, c8a, g8, c8b);
        case "BGR"
            rgb = cat(3, c8b, g8, c8a);
        otherwise
            error("Unsupported channel order: %s", channelOrder);
    end
end
