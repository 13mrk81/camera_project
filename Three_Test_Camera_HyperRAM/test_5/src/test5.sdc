# Test 5 board reference oscillator.
create_clock -name clk8_ref -period 125.000 -waveform {0 62.500} [get_ports {clk8}]

# cam_pclk is an externally generated sensor clock. Its exact period and
# input-delay relationship must be measured/confirmed for the configured
# GC0308 mode before adding a numeric timing constraint.
