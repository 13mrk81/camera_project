# Test A_2 external oscillator reference.
# The 8 MHz board oscillator is used only by the PLL that generates 24 MHz.
create_clock -name clk8_ref -period 125.000 -waveform {0 62.500} [get_ports {clk8}]

# clk24 is the generated system/control clock. clk96 is generated from clk24
# for the HyperRAM memory interface. Confirm PLL clock propagation in Gowin
# Timing Analyzer. The sensor PCLK is not used by this test.
