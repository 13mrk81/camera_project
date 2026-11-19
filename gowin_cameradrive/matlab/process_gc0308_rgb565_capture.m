%% Offline GC0308 RGB565 channel-order analysis (MSB-first)
% Uses raw bytes captured by matlab_gc0308_hyperram_receiver.m.
% Assumes the wire format is high byte then low byte for each RGB565 pixel.
% Tests all six permutations of the decoded R, G and B components.
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

% MSB-first: high byte followed by low byte for each pixel.
hi = uint16(wireBytes(:,1:2:end));
lo = uint16(wireBytes(:,2:2:end));
rgb565_msb = bitor(bitshift(hi, 8), lo);

% Extract RGB565 fields and expand each field to 8 bits.
% The six tests below only permute these three expanded components.
p = rgb565_msb;
r5 = bitshift(bitand(p, uint16(63488)), -11);
g6 = bitshift(bitand(p, uint16(2016)), -5);
b5 = bitand(p, uint16(31));

r8 = uint8(bitor(bitshift(r5, 3), bitshift(r5, -2)));
g8 = uint8(bitor(bitshift(g6, 2), bitshift(g6, -4)));
b8 = uint8(bitor(bitshift(b5, 3), bitshift(b5, -2)));

% All six possible channel permutations.
channelOrders = ["RGB", "RBG", "GRB", "GBR", "BRG", "BGR"];
candidates = cell(numel(channelOrders), 2);

figure("Name", "GC0308 RGB565 - MSB-first channel permutations", ...
    "Color", "w");

for k = 1:numel(channelOrders)
    order = char(channelOrders(k));

    switch order
        case "RGB"
            rgb = cat(3, r8, g8, b8);
        case "RBG"
            rgb = cat(3, r8, b8, g8);
        case "GRB"
            rgb = cat(3, g8, r8, b8);
        case "GBR"
            rgb = cat(3, g8, b8, r8);
        case "BRG"
            rgb = cat(3, b8, r8, g8);
        case "BGR"
            rgb = cat(3, b8, g8, r8);
    end

    candidates{k,1} = rgb;
    candidates{k,2} = "MSB-first / " + channelOrders(k);

    subplot(2,3,k);
    imshow(rgb);
    title(candidates{k,2}, "Interpreter", "none");

    outputFile = "gc0308_msb_" + lower(channelOrders(k)) + ".png";
    imwrite(rgb, outputFile);
end

save("gc0308_rgb565_offline_candidates.mat", ...
    "wireBytes", "rgb565_msb", "r8", "g8", "b8", ...
    "channelOrders", "candidates", "W", "H");

fprintf("Loaded one captured frame: %d x %d pixels.\\n", W, H);
fprintf("Generated all six MSB-first channel permutations.\\n");
fprintf("No FPGA transfer was performed.\\n");
fprintf("Wire byte order: high byte then low byte per pixel.\\n");
