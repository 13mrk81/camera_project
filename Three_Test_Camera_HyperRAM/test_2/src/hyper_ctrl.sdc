# External 8 MHz oscillator is only the PLL reference.
create_clock -name clk8_ref -period 125.000 -waveform {0 62.500} [get_ports {clk8}]

# Test 2 retains the production clock constraints. Do not invent a cam_pclk
# period: measure the sensor PCLK on the board and add its external clock constraint.
