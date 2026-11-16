module gw_gao(
    uart_rx_i,
    init_calib_i,
    camera_start_pulse,
    cam_config_done,
    cam_config_pass,
    cam_vsync,
    cam_byte_valid,
    cap_packed_valid,
    cap_fifo_overflow_cam,
    write_done_reg,
    write_error_reg,
    read_pipeline_done,
    integrity_done,
    integrity_error,
    system_ok,
    \u_integrity_checker/capture_error_i ,
    \u_integrity_checker/write_error_i ,
    \u_integrity_checker/stream_error_i ,
    clk8,
    tms_pad_i,
    tck_pad_i,
    tdi_pad_i,
    tdo_pad_o
);

input uart_rx_i;
input init_calib_i;
input camera_start_pulse;
input cam_config_done;
input cam_config_pass;
input cam_vsync;
input cam_byte_valid;
input cap_packed_valid;
input cap_fifo_overflow_cam;
input write_done_reg;
input write_error_reg;
input read_pipeline_done;
input integrity_done;
input integrity_error;
input system_ok;
input \u_integrity_checker/capture_error_i ;
input \u_integrity_checker/write_error_i ;
input \u_integrity_checker/stream_error_i ;
input clk8;
input tms_pad_i;
input tck_pad_i;
input tdi_pad_i;
output tdo_pad_o;

wire uart_rx_i;
wire init_calib_i;
wire camera_start_pulse;
wire cam_config_done;
wire cam_config_pass;
wire cam_vsync;
wire cam_byte_valid;
wire cap_packed_valid;
wire cap_fifo_overflow_cam;
wire write_done_reg;
wire write_error_reg;
wire read_pipeline_done;
wire integrity_done;
wire integrity_error;
wire system_ok;
wire \u_integrity_checker/capture_error_i ;
wire \u_integrity_checker/write_error_i ;
wire \u_integrity_checker/stream_error_i ;
wire clk8;
wire tms_pad_i;
wire tck_pad_i;
wire tdi_pad_i;
wire tdo_pad_o;
wire tms_i_c;
wire tck_i_c;
wire tdi_i_c;
wire tdo_o_c;
wire [9:0] control0;
wire gao_jtag_tck;
wire gao_jtag_reset;
wire run_test_idle_er1;
wire run_test_idle_er2;
wire shift_dr_capture_dr;
wire update_dr;
wire pause_dr;
wire enable_er1;
wire enable_er2;
wire gao_jtag_tdi;
wire tdo_er1;

IBUF tms_ibuf (
    .I(tms_pad_i),
    .O(tms_i_c)
);

IBUF tck_ibuf (
    .I(tck_pad_i),
    .O(tck_i_c)
);

IBUF tdi_ibuf (
    .I(tdi_pad_i),
    .O(tdi_i_c)
);

OBUF tdo_obuf (
    .I(tdo_o_c),
    .O(tdo_pad_o)
);

GW_JTAG  u_gw_jtag(
    .tms_pad_i(tms_i_c),
    .tck_pad_i(tck_i_c),
    .tdi_pad_i(tdi_i_c),
    .tdo_pad_o(tdo_o_c),
    .tck_o(gao_jtag_tck),
    .test_logic_reset_o(gao_jtag_reset),
    .run_test_idle_er1_o(run_test_idle_er1),
    .run_test_idle_er2_o(run_test_idle_er2),
    .shift_dr_capture_dr_o(shift_dr_capture_dr),
    .update_dr_o(update_dr),
    .pause_dr_o(pause_dr),
    .enable_er1_o(enable_er1),
    .enable_er2_o(enable_er2),
    .tdi_o(gao_jtag_tdi),
    .tdo_er1_i(tdo_er1),
    .tdo_er2_i(1'b0)
);

gw_con_top  u_icon_top(
    .tck_i(gao_jtag_tck),
    .tdi_i(gao_jtag_tdi),
    .tdo_o(tdo_er1),
    .rst_i(gao_jtag_reset),
    .control0(control0[9:0]),
    .enable_i(enable_er1),
    .shift_dr_capture_dr_i(shift_dr_capture_dr),
    .update_dr_i(update_dr)
);

ao_top_0  u_la0_top(
    .control(control0[9:0]),
    .trig0_i(uart_rx_i),
    .data_i({uart_rx_i,init_calib_i,camera_start_pulse,cam_config_done,cam_config_pass,cam_vsync,cam_byte_valid,cap_packed_valid,cap_fifo_overflow_cam,write_done_reg,write_error_reg,read_pipeline_done,integrity_done,integrity_error,system_ok,\u_integrity_checker/capture_error_i ,\u_integrity_checker/write_error_i ,\u_integrity_checker/stream_error_i }),
    .clk_i(clk8)
);

endmodule
