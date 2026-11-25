# External 8 MHz oscillator feeds the existing PLL; its output clk24 is the synthetic source and packer clock.
create_clock -name clk8_ref -period 125.000 -waveform {0 62.500} [get_ports {clk8}]

# Test 3 retains the production clock constraints. Do not invent a cam_pclk
# period: measure the sensor PCLK on the board and add its external clock constraint.

# PLL output clk24 is configured from FCLKIN=8 MHz, FBDIV_SEL=2, ODIV_SEL=32.
# Confirm PLL-generated clock propagation in Gowin Timing Analyzer. Test 3 does
# not use camera PCLK, so no camera clock constraint is required.
