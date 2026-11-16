# Compile in this order. Add the generated Gowin IP sources for
# Gowin_PLLVR_1, Gowin_PLLVR and HyperRAM_Memory_Interface_Top to the project.
i2c_master_nack.vhd
camera_interface.vhd
async_fifo_32.vhd
falling_edge_one_shot.vhd
rgb565_frame_packer.vhd
stable_bus_event_cdc.vhd
frame_integrity_checker.vhd
hyperram_line_reader.vhd
rgb565_line_serializer.vhd
hyperram_line_readout.vhd
gowin_hyperram_read_adapter.vhd
Camera_HyperRAM_OneFrame.vhd
