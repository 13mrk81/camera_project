library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- GC0308 configuration sequencer for Tang Nano 4K.
--
-- Requirements for the existing i2c_master_nack component:
--   * 7-bit device address input
--   * rw='0': write reg_addr/wr_data
--   * rw='1': write register address, repeated START, read one byte
--   * active-low rst_n
--   * start is accepted in IDLE and done is a one-clock pulse
--   * scl/sda are open-drain inout ports
--
-- Register sequence is based on Espressif's public GC0308 default settings.
-- Register 0x24 is intentionally changed from 0xA2 (YUV422) to 0xA6 (RGB565).

entity camera_interface is
    generic (
        G_CLK_FREQ_HZ       : positive := 24_000_000;
        G_I2C_FREQ_HZ       : positive := 100_000;
        G_I2C_DEVICE_ADDR   : std_logic_vector(6 downto 0) := "0100001";
        G_RESET_WAIT_MS     : positive := 80;
        G_POR_RESET_MS      : positive := 1;
        G_FRAME_WIDTH       : positive := 640;
        G_FRAME_HEIGHT      : positive := 480
    );
    port (
        clk24         : in  std_logic;
        clkcam        : out std_logic;
        rst_n         : in  std_logic;
        rst_trigger   : in  std_logic;
        cam_sda       : inout std_logic;
        cam_scl       : inout std_logic;

        -- GC0308 DVP parallel video interface.
        cam_pclk      : in  std_logic;
        cam_vsync     : in  std_logic;
        cam_hsync     : in  std_logic;
        cam_pix_data  : in  std_logic_vector(7 downto 0);

        -- One-shot frame byte stream, all signals in cam_pclk domain.
        frame_byte_o       : out std_logic_vector(7 downto 0);
        frame_byte_valid_o : out std_logic;
        frame_done_o       : out std_logic;
        frame_error_o      : out std_logic;
        source_byte_count_o : out unsigned(31 downto 0);

        -- Configuration/debug outputs.
        config_done_o      : out std_logic;
        config_pass_o      : out std_logic;

        -- Configuration and SCCB diagnostics, synchronous to clk24.
        config_fail_o             : out std_logic;
        config_error_code_o       : out std_logic_vector(3 downto 0);
        config_state_o            : out std_logic_vector(4 downto 0);
        config_init_index_o       : out std_logic_vector(7 downto 0);
        config_verify_index_o     : out std_logic_vector(3 downto 0);
        config_reg_addr_o         : out std_logic_vector(7 downto 0);
        config_reg_data_o         : out std_logic_vector(7 downto 0);
        config_rw_o               : out std_logic;
        config_device_addr_o      : out std_logic_vector(6 downto 0);
        config_chip_id_o          : out std_logic_vector(7 downto 0);
        config_last_readback_o    : out std_logic_vector(7 downto 0);
        config_verify_addr_o      : out std_logic_vector(7 downto 0);
        config_verify_expected_o  : out std_logic_vector(7 downto 0);
        config_verify_fail_o      : out std_logic;

        i2c_start_o               : out std_logic;
        i2c_busy_o                : out std_logic;
        i2c_done_o                : out std_logic;
        i2c_ack_o                 : out std_logic;
        i2c_nack_o                : out std_logic;
        i2c_ack_count_o           : out std_logic_vector(1 downto 0);
        i2c_state_o               : out std_logic_vector(3 downto 0);
        i2c_sequence_o            : out std_logic_vector(1 downto 0);
        i2c_phase_o               : out std_logic_vector(1 downto 0);
        i2c_sda_sample_o          : out std_logic;
        i2c_scl_sample_o          : out std_logic;
        i2c_bus_idle_o            : out std_logic;
        i2c_scl_drive_low_o       : out std_logic;
        i2c_sda_drive_low_o       : out std_logic;

        -- Capture diagnostics; the byte stream itself remains unchanged.
        capture_state_o           : out std_logic_vector(2 downto 0);
        capture_active_o          : out std_logic;
        line_count_o              : out std_logic_vector(9 downto 0);
        line_byte_count_o         : out std_logic_vector(10 downto 0)
    );
end entity;

architecture rtl of camera_interface is



    -- Power-on reset for the I2C master after the PLL starts producing clocks.
    constant C_POR_CYCLES : natural := (G_CLK_FREQ_HZ / 1000) * G_POR_RESET_MS;
    constant C_RESET_WAIT_CYCLES : natural := (G_CLK_FREQ_HZ / 1000) * G_RESET_WAIT_MS;
    signal por_count : natural range 0 to C_POR_CYCLES := 0;
    signal i2c_rst_n : std_logic := '0';

    -- Synchronized rising-edge detector. rst_trigger is a START command,
    -- not the GC0308's physical RESETB pin.
    signal trig_meta : std_logic := '0';
    signal trig_sync : std_logic := '0';
    signal trig_prev : std_logic := '0';

    signal i2c_start_sig : std_logic := '0';
    signal i2c_rw_sig    : std_logic := '0';
    signal i2c_dev_sig   : std_logic_vector(6 downto 0) := G_I2C_DEVICE_ADDR;
    signal i2c_reg_sig   : std_logic_vector(7 downto 0) := (others => '0');
    signal i2c_wdata_sig : std_logic_vector(7 downto 0) := (others => '0');
    signal i2c_rdata_sig : std_logic_vector(7 downto 0);
    signal i2c_ack_count_sig : std_logic_vector(1 downto 0);
    signal dbg_state_sig : std_logic_vector(3 downto 0);
    signal dbg_sda_in_sig, dbg_scl_in_sig, dbg_bus_idle_sig : std_logic;
    signal dbg_scl_low_sig, dbg_sda_low_sig : std_logic;
    signal ack_out_sig   : std_logic;
    signal nack_seen_sig : std_logic;
    signal busy_sig      : std_logic;
    signal done_sig      : std_logic;
    signal dbg_rx_sig    : std_logic_vector(7 downto 0);
    signal dbg_shift_sig : std_logic_vector(7 downto 0);
    signal dbg_phase_sig : std_logic_vector(1 downto 0);
    signal dbg_seq_sig   : std_logic_vector(1 downto 0);

    type reg_pair_t is record
        addr : std_logic_vector(7 downto 0);
        data : std_logic_vector(7 downto 0);
    end record;
    type reg_table_t is array (natural range <>) of reg_pair_t;

    -- Full baseline register profile. Page switching is part of this table.
    -- 0x24=A6 selects RGB565 while preserving the baseline upper control bits.
    constant C_INIT_TABLE : reg_table_t := (
        (x"FE", x"00"),
        (x"EC", x"20"),
        (x"05", x"00"), (x"06", x"00"), (x"07", x"00"), (x"08", x"00"),
        (x"09", x"01"), (x"0A", x"E8"), (x"0B", x"02"), (x"0C", x"88"),
        (x"0D", x"02"), (x"0E", x"02"),
        (x"10", x"26"), (x"11", x"0D"), (x"12", x"2A"), (x"13", x"00"),
        (x"14", x"10"), (x"15", x"0A"), (x"16", x"05"), (x"17", x"01"),
        (x"18", x"44"), (x"19", x"44"), (x"1A", x"2A"), (x"1B", x"00"),
        (x"1C", x"49"), (x"1D", x"9A"), (x"1E", x"61"), (x"1F", x"00"),
        (x"20", x"7F"), (x"21", x"FA"), (x"22", x"57"),
        (x"24", x"A6"), (x"25", x"0F"), (x"26", x"03"), (x"28", x"00"),
        (x"2D", x"0A"), (x"2F", x"01"),
        (x"30", x"F7"), (x"31", x"50"), (x"32", x"00"),
        (x"33", x"28"), (x"34", x"2A"), (x"35", x"28"),
        (x"39", x"04"), (x"3A", x"20"), (x"3B", x"20"),
        (x"3C", x"00"), (x"3D", x"00"), (x"3E", x"00"), (x"3F", x"00"),
        (x"50", x"14"), (x"52", x"41"),
        (x"53", x"80"), (x"54", x"80"), (x"55", x"80"), (x"56", x"80"),
        (x"5A", x"56"), (x"5B", x"40"), (x"5C", x"4A"),
        (x"8B", x"20"), (x"8C", x"20"), (x"8D", x"20"),
        (x"8E", x"14"), (x"8F", x"10"), (x"90", x"14"),
        (x"91", x"3C"), (x"92", x"50"),
        (x"5D", x"12"), (x"5E", x"1A"), (x"5F", x"24"),
        (x"60", x"07"), (x"61", x"15"), (x"62", x"08"), (x"64", x"03"),
        (x"66", x"E8"), (x"67", x"86"), (x"68", x"82"),
        (x"69", x"18"), (x"6A", x"0F"), (x"6B", x"00"),
        (x"6C", x"5F"), (x"6D", x"8F"), (x"6E", x"55"), (x"6F", x"38"),
        (x"70", x"15"), (x"71", x"33"), (x"72", x"DC"), (x"73", x"00"),
        (x"74", x"02"), (x"75", x"3F"), (x"76", x"02"),
        (x"77", x"38"), (x"78", x"88"), (x"79", x"81"),
        (x"7A", x"81"), (x"7B", x"22"), (x"7C", x"FF"),
        (x"93", x"48"), (x"94", x"02"), (x"95", x"07"),
        (x"96", x"E0"), (x"97", x"40"), (x"98", x"F0"),
        (x"B1", x"40"), (x"B2", x"40"), (x"B3", x"40"),
        (x"B6", x"E0"), (x"BD", x"38"), (x"BE", x"36"),
        (x"D0", x"CB"), (x"D1", x"10"), (x"D2", x"90"), (x"D3", x"48"),
        (x"D5", x"F2"), (x"D6", x"16"), (x"DB", x"92"), (x"DC", x"A5"),
        (x"DF", x"23"), (x"D9", x"00"), (x"DA", x"00"),
        (x"E0", x"09"), (x"ED", x"04"), (x"EE", x"A0"), (x"EF", x"40"),
        (x"80", x"03"),
        (x"9F", x"10"), (x"A0", x"20"), (x"A1", x"38"), (x"A2", x"4E"),
        (x"A3", x"63"), (x"A4", x"76"), (x"A5", x"87"), (x"A6", x"A2"),
        (x"A7", x"B8"), (x"A8", x"CA"), (x"A9", x"D8"), (x"AA", x"E3"),
        (x"AB", x"EB"), (x"AC", x"F0"), (x"AD", x"F8"), (x"AE", x"FD"),
        (x"AF", x"FF"),
        (x"C0", x"00"), (x"C1", x"10"), (x"C2", x"1C"), (x"C3", x"30"),
        (x"C4", x"43"), (x"C5", x"54"), (x"C6", x"65"), (x"C7", x"75"),
        (x"C8", x"93"), (x"C9", x"B0"), (x"CA", x"CB"), (x"CB", x"E6"),
        (x"CC", x"FF"),
        (x"F0", x"02"), (x"F1", x"01"), (x"F2", x"02"), (x"F3", x"30"),
        (x"F7", x"04"), (x"F8", x"02"), (x"F9", x"9F"), (x"FA", x"78"),
        (x"FE", x"01"),
        (x"00", x"F5"), (x"02", x"20"), (x"04", x"10"), (x"05", x"08"),
        (x"06", x"20"), (x"08", x"0A"), (x"0A", x"A0"), (x"0B", x"60"),
        (x"0C", x"08"), (x"0E", x"44"), (x"0F", x"32"),
        (x"10", x"41"), (x"11", x"37"), (x"12", x"22"), (x"13", x"19"),
        (x"14", x"44"), (x"15", x"44"), (x"16", x"C2"), (x"17", x"A8"),
        (x"18", x"18"), (x"19", x"50"), (x"1A", x"D8"), (x"1B", x"F5"),
        (x"70", x"40"), (x"71", x"58"), (x"72", x"30"), (x"73", x"48"),
        (x"74", x"20"), (x"75", x"60"), (x"77", x"20"), (x"78", x"32"),
        (x"30", x"03"), (x"31", x"40"), (x"32", x"10"), (x"33", x"E0"),
        (x"34", x"E0"), (x"35", x"00"), (x"36", x"80"), (x"37", x"00"),
        (x"38", x"04"), (x"39", x"09"), (x"3A", x"12"), (x"3B", x"1C"),
        (x"3C", x"28"), (x"3D", x"31"), (x"3E", x"44"), (x"3F", x"57"),
        (x"40", x"6C"), (x"41", x"81"), (x"42", x"94"), (x"43", x"A7"),
        (x"44", x"B8"), (x"45", x"D6"), (x"46", x"EE"), (x"47", x"0D"),
        (x"62", x"F7"), (x"63", x"68"), (x"64", x"D3"), (x"65", x"D3"),
        (x"66", x"60"),
        (x"FE", x"00"),
        (x"01", x"32"), (x"02", x"0C"), (x"0F", x"01"),
        (x"E2", x"00"), (x"E3", x"78"), (x"E4", x"00"), (x"E5", x"FE"),
        (x"E6", x"01"), (x"E7", x"E0"), (x"E8", x"01"), (x"E9", x"E0"),
        (x"EA", x"01"), (x"EB", x"E0"),
        (x"FE", x"00")
    );

    -- Readback checks are intentionally limited to stable, mode-defining
    -- registers. Exposure/AEC registers are dynamic and are not compared.
    constant C_VERIFY_TABLE : reg_table_t := (
        (x"00", x"9B"), -- Chip ID (read-only)
        (x"09", x"01"), (x"0A", x"E8"), -- 488-line sensor window -> 480 valid lines
        (x"0B", x"02"), (x"0C", x"88"), -- 648-pixel sensor window -> 640 valid pixels
        (x"14", x"10"), -- no mirror / no flip
        (x"25", x"0F"), -- DVP data, PCLK, HSYNC, VSYNC enabled
        (x"26", x"03"), -- reference sync polarity
        (x"28", x"00")  -- XCLK/PCLK divider register
    );

    type cfg_state_t is (
        ST_WAIT_TRIGGER,
        ST_PAGE0_REQ, ST_PAGE0_WAIT,
        ST_ID_READ_REQ, ST_ID_READ_WAIT,
        ST_SOFT_RESET_REQ, ST_SOFT_RESET_WAIT, ST_SOFT_RESET_DELAY,
        ST_INIT_WRITE_REQ, ST_INIT_WRITE_WAIT, ST_INIT_SETTLE_DELAY,
        ST_VERIFY_READ_REQ, ST_VERIFY_READ_WAIT,
        ST_RGB565_READ_REQ, ST_RGB565_READ_WAIT,
        ST_COMPLETE, ST_ERROR
    );
    signal cfg_state : cfg_state_t := ST_WAIT_TRIGGER;

    signal delay_count : natural range 0 to C_RESET_WAIT_CYCLES := 0;
    signal init_index  : natural range 0 to C_INIT_TABLE'length := 0;
    signal verify_index : natural range 0 to C_VERIFY_TABLE'length := 0;

    ---------------------------------------------------------------------------
    -- DVP capture path. This FSM is clocked by cam_pclk, not clk24.
    -- Register 0x26 is configured to 0x03, so HSYNC and VSYNC are active high.
    ---------------------------------------------------------------------------
    type capture_state_t is (
        CAP_WAIT_CONFIG,
        CAP_WAIT_VSYNC_INACTIVE,
        CAP_WAIT_VSYNC_ACTIVE,
        CAP_CAPTURE,
        CAP_DONE,
        CAP_ERROR
    );
    signal capture_state : capture_state_t := CAP_WAIT_CONFIG;

    signal cap_rst_meta       : std_logic := '0';
    signal cap_rst_sync       : std_logic := '0';
    signal cfg_done_meta_pclk : std_logic := '0';
    signal cfg_done_sync_pclk : std_logic := '0';
    signal cfg_pass_meta_pclk : std_logic := '0';
    signal cfg_pass_sync_pclk : std_logic := '0';

    -- Sampled DVP byte and one-clock byte-valid pulse.
    signal pix_data_reg          : std_logic_vector(7 downto 0) := (others => '0');
    signal vsync_reg             : std_logic := '0';
    signal hsync_reg             : std_logic := '0';
    signal pixel_byte_valid_sig  : std_logic := '0';
    signal frame_done_sig        : std_logic := '0';
    signal capture_active_sig    : std_logic := '0';
    signal capture_error_sig     : std_logic := '0';

    signal vsync_prev             : std_logic := '0';
    signal hsync_prev             : std_logic := '0';
    signal frame_start_pulse_sig  : std_logic := '0';
    signal line_start_pulse_sig   : std_logic := '0';
    signal frame_count_sig        : unsigned(15 downto 0) := (others => '0');
    signal line_count_sig         : unsigned(9 downto 0) := (others => '0');
    signal line_byte_count_sig    : unsigned(10 downto 0) := (others => '0');
    signal last_line_bytes_sig    : unsigned(10 downto 0) := (others => '0');
    signal capture_state_dbg      : std_logic_vector(2 downto 0);

    constant C_BYTES_PER_LINE : positive := G_FRAME_WIDTH * 2;
    signal line_count_i       : natural range 0 to G_FRAME_HEIGHT := 0;
    signal line_byte_count_i  : natural range 0 to C_BYTES_PER_LINE := 0;
    signal source_byte_count_sig : unsigned(31 downto 0) := (others => '0');

    signal chip_id_sig       : std_logic_vector(7 downto 0) := (others => '0');
    signal last_readback_sig : std_logic_vector(7 downto 0) := (others => '0');
    signal rgb565_readback_sig : std_logic_vector(7 downto 0) := (others => '0');
    signal rgb565_confirm_sig  : std_logic := '0';
    signal verify_addr_sig   : std_logic_vector(7 downto 0) := (others => '0');
    signal verify_expect_sig : std_logic_vector(7 downto 0) := (others => '0');
    signal verify_fail_sig   : std_logic := '0';
    signal config_done_sig   : std_logic := '0';
    signal config_pass_sig   : std_logic := '0';
    signal config_fail_sig   : std_logic := '0';
    signal error_code_sig    : std_logic_vector(3 downto 0) := (others => '0');

    signal cfg_state_dbg     : std_logic_vector(4 downto 0);
    signal init_index_dbg    : std_logic_vector(7 downto 0);
    signal verify_index_dbg  : std_logic_vector(3 downto 0);

    attribute syn_keep : integer;
    attribute syn_keep of ack_out_sig       : signal is 1;
    attribute syn_keep of nack_seen_sig     : signal is 1;
    attribute syn_keep of busy_sig          : signal is 1;
    attribute syn_keep of done_sig          : signal is 1;
    attribute syn_keep of dbg_rx_sig        : signal is 1;
    attribute syn_keep of dbg_shift_sig     : signal is 1;
    attribute syn_keep of dbg_phase_sig     : signal is 1;
    attribute syn_keep of dbg_seq_sig       : signal is 1;
    attribute syn_keep of chip_id_sig       : signal is 1;
    attribute syn_keep of last_readback_sig : signal is 1;
    attribute syn_keep of rgb565_readback_sig : signal is 1;
    attribute syn_keep of rgb565_confirm_sig  : signal is 1;
    attribute syn_keep of verify_addr_sig   : signal is 1;
    attribute syn_keep of verify_expect_sig : signal is 1;
    attribute syn_keep of verify_fail_sig   : signal is 1;
    attribute syn_keep of config_done_sig   : signal is 1;
    attribute syn_keep of config_pass_sig   : signal is 1;
    attribute syn_keep of config_fail_sig   : signal is 1;
    attribute syn_keep of error_code_sig    : signal is 1;
    attribute syn_keep of cfg_state_dbg    : signal is 1;
    attribute syn_keep of init_index_dbg   : signal is 1;
    attribute syn_keep of verify_index_dbg : signal is 1;
    attribute syn_keep of cfg_done_sync_pclk : signal is 1;
    attribute syn_keep of cfg_pass_sync_pclk : signal is 1;
    attribute syn_keep of pix_data_reg : signal is 1;
    attribute syn_keep of vsync_reg : signal is 1;
    attribute syn_keep of hsync_reg : signal is 1;
    attribute syn_keep of pixel_byte_valid_sig : signal is 1;
    attribute syn_keep of capture_active_sig : signal is 1;
    attribute syn_keep of capture_error_sig : signal is 1;
    attribute syn_keep of frame_start_pulse_sig : signal is 1;
    attribute syn_keep of line_start_pulse_sig : signal is 1;
    attribute syn_keep of frame_count_sig : signal is 1;
    attribute syn_keep of line_count_sig : signal is 1;
    attribute syn_keep of line_byte_count_sig : signal is 1;
    attribute syn_keep of last_line_bytes_sig : signal is 1;
    attribute syn_keep of capture_state_dbg : signal is 1;
    attribute syn_keep of frame_done_sig : signal is 1;
    attribute syn_keep of line_count_i : signal is 1;
    attribute syn_keep of line_byte_count_i : signal is 1;

begin

    clkcam <= clk24;

    frame_byte_o       <= pix_data_reg;
    frame_byte_valid_o <= pixel_byte_valid_sig;
    frame_done_o       <= frame_done_sig;
    frame_error_o       <= capture_error_sig;
    source_byte_count_o <= source_byte_count_sig;
    config_done_o       <= config_done_sig;
    config_pass_o       <= config_pass_sig;

    -- Configuration-controller observability.
    config_fail_o            <= config_fail_sig;
    config_error_code_o      <= error_code_sig;
    config_state_o           <= cfg_state_dbg;
    config_init_index_o      <= init_index_dbg;
    config_verify_index_o    <= verify_index_dbg;
    config_reg_addr_o        <= i2c_reg_sig;
    config_reg_data_o        <= i2c_wdata_sig;
    config_rw_o              <= i2c_rw_sig;
    config_device_addr_o     <= i2c_dev_sig;
    config_chip_id_o         <= chip_id_sig;
    config_last_readback_o   <= last_readback_sig;
    config_verify_addr_o     <= verify_addr_sig;
    config_verify_expected_o <= verify_expect_sig;
    config_verify_fail_o     <= verify_fail_sig;

    -- I2C master and physical-line observability.
    i2c_start_o         <= i2c_start_sig;
    i2c_busy_o          <= busy_sig;
    i2c_done_o          <= done_sig;
    i2c_ack_o           <= ack_out_sig;
    i2c_nack_o           <= nack_seen_sig;
    i2c_ack_count_o     <= i2c_ack_count_sig;
    i2c_state_o         <= dbg_state_sig;
    i2c_sequence_o      <= dbg_seq_sig;
    i2c_phase_o         <= dbg_phase_sig;
    i2c_sda_sample_o    <= dbg_sda_in_sig;
    i2c_scl_sample_o    <= dbg_scl_in_sig;
    i2c_bus_idle_o      <= dbg_bus_idle_sig;
    i2c_scl_drive_low_o <= dbg_scl_low_sig;
    i2c_sda_drive_low_o <= dbg_sda_low_sig;

    capture_state_o   <= capture_state_dbg;
    capture_active_o  <= capture_active_sig;
    line_count_o      <= std_logic_vector(line_count_sig);
    line_byte_count_o <= std_logic_vector(line_byte_count_sig);

    u_i2c_master : entity work.i2c_master_nack
        generic map (
            G_CLK_FREQ_HZ => G_CLK_FREQ_HZ,
            G_I2C_FREQ_HZ => G_I2C_FREQ_HZ
        )
        port map (
            clk       => clk24,
            rst_n     => i2c_rst_n,
            start     => i2c_start_sig,
            rw        => i2c_rw_sig,
            dev_addr  => i2c_dev_sig,
            reg_addr  => i2c_reg_sig,
            wr_data   => i2c_wdata_sig,
            rd_data   => i2c_rdata_sig,
            ack_out   => ack_out_sig,
            nack_seen => nack_seen_sig,
            ack_count => i2c_ack_count_sig,
            busy      => busy_sig,
            done      => done_sig,
            dbg_rx    => dbg_rx_sig,
            dbg_shift => dbg_shift_sig,
            dbg_phase => dbg_phase_sig,
            dbg_seq   => dbg_seq_sig,
            dbg_state => dbg_state_sig,
            dbg_sda_in => dbg_sda_in_sig,
            dbg_scl_in => dbg_scl_in_sig,
            dbg_bus_idle => dbg_bus_idle_sig,
            dbg_scl_low => dbg_scl_low_sig,
            dbg_sda_low => dbg_sda_low_sig,
            scl       => cam_scl,
            sda       => cam_sda
        );

    -- Hold the I2C master in reset briefly after PLL clocking begins.
    por_reset : process(clk24)
    begin
        if rising_edge(clk24) then
            if rst_n = '0' then
                por_count <= 0;
                i2c_rst_n <= '0';
            elsif por_count < C_POR_CYCLES then
                por_count <= por_count + 1;
                i2c_rst_n <= '0';
            else
                i2c_rst_n <= '1';
            end if;
        end if;
    end process;

    -- Main configuration controller.
    config_fsm : process(clk24)
    begin
        if rising_edge(clk24) then
            -- Default: start is always a one-clock pulse.
            i2c_start_sig <= '0';

            -- Two-flop synchronizer for the external trigger.
            trig_meta <= rst_trigger;
            trig_sync <= trig_meta;
            trig_prev <= trig_sync;

            if i2c_rst_n = '0' then
                cfg_state          <= ST_WAIT_TRIGGER;
                i2c_start_sig      <= '0';
                i2c_rw_sig         <= '0';
                i2c_dev_sig        <= G_I2C_DEVICE_ADDR;
                i2c_reg_sig        <= (others => '0');
                i2c_wdata_sig      <= (others => '0');
                delay_count        <= 0;
                init_index         <= 0;
                verify_index       <= 0;
                chip_id_sig        <= (others => '0');
                last_readback_sig  <= (others => '0');
                rgb565_readback_sig <= (others => '0');
                rgb565_confirm_sig  <= '0';
                verify_addr_sig    <= (others => '0');
                verify_expect_sig  <= (others => '0');
                verify_fail_sig    <= '0';
                config_done_sig    <= '0';
                config_pass_sig    <= '0';
                config_fail_sig    <= '0';
                error_code_sig     <= (others => '0');
                trig_meta          <= '0';
                trig_sync          <= '0';
                trig_prev          <= '0';
            else
                case cfg_state is

                    when ST_WAIT_TRIGGER =>
                        if (trig_sync = '1') and (trig_prev = '0') then
                            config_done_sig <= '0';
                            config_pass_sig <= '0';
                            config_fail_sig <= '0';
                            verify_fail_sig <= '0';
                            error_code_sig  <= (others => '0');
                            cfg_state <= ST_PAGE0_REQ;
                        end if;

                    -- Explicitly select page 0 before reading the chip ID.
                    when ST_PAGE0_REQ =>
                        i2c_rw_sig    <= '0';
                        i2c_reg_sig   <= x"FE";
                        i2c_wdata_sig <= x"00";
                        i2c_start_sig <= '1';
                        cfg_state <= ST_PAGE0_WAIT;

                    when ST_PAGE0_WAIT =>
                        if done_sig = '1' then
                            if (nack_seen_sig = '1') or (i2c_ack_count_sig /= "11") then
                                error_code_sig <= x"1";
                                cfg_state <= ST_ERROR;
                            else
                                cfg_state <= ST_ID_READ_REQ;
                            end if;
                        end if;

                    -- Verify that the responding device identifies as GC0308.
                    when ST_ID_READ_REQ =>
                        i2c_rw_sig    <= '1';
                        i2c_reg_sig   <= x"00";
                        i2c_wdata_sig <= x"00";
                        i2c_start_sig <= '1';
                        cfg_state <= ST_ID_READ_WAIT;

                    when ST_ID_READ_WAIT =>
                        if done_sig = '1' then
                            if (nack_seen_sig = '1') or (i2c_ack_count_sig /= "11") then
                                error_code_sig <= x"2";
                                cfg_state <= ST_ERROR;
                            elsif i2c_rdata_sig = x"9B" then
                                chip_id_sig <= i2c_rdata_sig;
                                cfg_state <= ST_SOFT_RESET_REQ;
                            else
                                chip_id_sig <= i2c_rdata_sig;
                                error_code_sig <= x"3";
                                cfg_state <= ST_ERROR;
                            end if;
                        end if;

                    -- Soft reset: bit[7]=1, bit[4]=1, page select bit[0]=0.
                    when ST_SOFT_RESET_REQ =>
                        i2c_rw_sig    <= '0';
                        i2c_reg_sig   <= x"FE";
                        i2c_wdata_sig <= x"F0";
                        i2c_start_sig <= '1';
                        cfg_state <= ST_SOFT_RESET_WAIT;

                    when ST_SOFT_RESET_WAIT =>
                        if done_sig = '1' then
                            if (nack_seen_sig = '1') or (i2c_ack_count_sig /= "11") then
                                error_code_sig <= x"4";
                                cfg_state <= ST_ERROR;
                            else
                                delay_count <= 0;
                                cfg_state <= ST_SOFT_RESET_DELAY;
                            end if;
                        end if;

                    when ST_SOFT_RESET_DELAY =>
                        if delay_count < C_RESET_WAIT_CYCLES then
                            delay_count <= delay_count + 1;
                        else
                            delay_count <= 0;
                            init_index <= 0;
                            cfg_state <= ST_INIT_WRITE_REQ;
                        end if;

                    -- Write the complete baseline register table.
                    when ST_INIT_WRITE_REQ =>
                        if init_index < C_INIT_TABLE'length then
                            i2c_rw_sig    <= '0';
                            i2c_reg_sig   <= C_INIT_TABLE(init_index).addr;
                            i2c_wdata_sig <= C_INIT_TABLE(init_index).data;
                            i2c_start_sig <= '1';
                            cfg_state <= ST_INIT_WRITE_WAIT;
                        else
                            delay_count <= 0;
                            cfg_state <= ST_INIT_SETTLE_DELAY;
                        end if;

                    when ST_INIT_WRITE_WAIT =>
                        if done_sig = '1' then
                            if (nack_seen_sig = '1') or (i2c_ack_count_sig /= "11") then
                                error_code_sig <= x"5";
                                cfg_state <= ST_ERROR;
                            elsif init_index = C_INIT_TABLE'length - 1 then
                                init_index <= C_INIT_TABLE'length;
                                delay_count <= 0;
                                cfg_state <= ST_INIT_SETTLE_DELAY;
                            else
                                init_index <= init_index + 1;
                                cfg_state <= ST_INIT_WRITE_REQ;
                            end if;
                        end if;

                    -- Match the settling interval used by the reference driver.
                    when ST_INIT_SETTLE_DELAY =>
                        if delay_count < C_RESET_WAIT_CYCLES then
                            delay_count <= delay_count + 1;
                        else
                            delay_count <= 0;
                            verify_index <= 0;
                            cfg_state <= ST_VERIFY_READ_REQ;
                        end if;

                    -- Read back every entry in the stable verification list.
                    when ST_VERIFY_READ_REQ =>
                        if verify_index < C_VERIFY_TABLE'length then
                            verify_addr_sig   <= C_VERIFY_TABLE(verify_index).addr;
                            verify_expect_sig <= C_VERIFY_TABLE(verify_index).data;
                            i2c_rw_sig        <= '1';
                            i2c_reg_sig       <= C_VERIFY_TABLE(verify_index).addr;
                            i2c_wdata_sig     <= x"00";
                            i2c_start_sig     <= '1';
                            cfg_state <= ST_VERIFY_READ_WAIT;
                        else
                            cfg_state <= ST_RGB565_READ_REQ;
                        end if;

                    when ST_VERIFY_READ_WAIT =>
                        if done_sig = '1' then
                            if (nack_seen_sig = '1') or (i2c_ack_count_sig /= "11") then
                                error_code_sig <= x"6";
                                config_fail_sig <= '1';
                                cfg_state <= ST_ERROR;
                            else
                                last_readback_sig <= i2c_rdata_sig;
                                if i2c_rdata_sig /= verify_expect_sig then
                                    verify_fail_sig <= '1';
                                    config_fail_sig <= '1';
                                    error_code_sig <= x"7";
                                    cfg_state <= ST_ERROR;
                                elsif verify_index = C_VERIFY_TABLE'length - 1 then
                                    verify_index <= C_VERIFY_TABLE'length;
                                    cfg_state <= ST_RGB565_READ_REQ;
                                else
                                    verify_index <= verify_index + 1;
                                    cfg_state <= ST_VERIFY_READ_REQ;
                                end if;
                            end if;
                        end if;

                    -- Dedicated final check of the GC0308 color-format register.
                    -- Page 0, register 0x24 = 0xA6 is the selected RGB565 setting.
                    when ST_RGB565_READ_REQ =>
                        i2c_rw_sig    <= '1';
                        i2c_reg_sig   <= x"24";
                        i2c_wdata_sig <= x"00";
                        i2c_start_sig <= '1';
                        cfg_state <= ST_RGB565_READ_WAIT;

                    when ST_RGB565_READ_WAIT =>
                        if done_sig = '1' then
                            if (nack_seen_sig = '1') or (i2c_ack_count_sig /= "11") then
                                error_code_sig <= x"8";
                                config_fail_sig <= '1';
                                rgb565_confirm_sig <= '0';
                                cfg_state <= ST_ERROR;
                            else
                                rgb565_readback_sig <= i2c_rdata_sig;
                                if i2c_rdata_sig = x"A6" then
                                    rgb565_confirm_sig <= '1';
                                    cfg_state <= ST_COMPLETE;
                                else
                                    rgb565_confirm_sig <= '0';
                                    error_code_sig <= x"9";
                                    config_fail_sig <= '1';
                                    cfg_state <= ST_ERROR;
                                end if;
                            end if;
                        end if;

                    when ST_COMPLETE =>
                        config_done_sig <= '1';
                        config_pass_sig <= rgb565_confirm_sig;
                        -- Remain here; another trigger does not silently rerun
                        -- a configuration after the master's sticky NACK flag.

                    when ST_ERROR =>
                        config_done_sig <= '1';
                        config_pass_sig <= '0';
                        config_fail_sig <= '1';
                        -- Sticky error state for easy GAO inspection.

                    when others =>
                        cfg_state <= ST_ERROR;
                        error_code_sig <= x"F";
                end case;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- DVP capture FSM.
    --
    -- config_done/config_pass are generated in the clk24 domain. They are
    -- synchronized into the independent camera PCLK domain before use.
    -- The FSM waits for a VSYNC inactive interval, then the next active frame.
    -- While capturing, data/HSYNC/VSYNC are registered on the same PCLK edge.
    ---------------------------------------------------------------------------
    dvp_capture_fsm : process(cam_pclk)
    begin
        if rising_edge(cam_pclk) then
            -- Reset synchronizer for the PCLK clock domain.
            cap_rst_meta <= i2c_rst_n;
            cap_rst_sync <= cap_rst_meta;

            if cap_rst_sync = '0' then
                cfg_done_meta_pclk <= '0';
                cfg_done_sync_pclk <= '0';
                cfg_pass_meta_pclk <= '0';
                cfg_pass_sync_pclk <= '0';

                capture_state <= CAP_WAIT_CONFIG;
                pix_data_reg <= (others => '0');
                vsync_reg <= '0';
                hsync_reg <= '0';
                pixel_byte_valid_sig <= '0';
                frame_done_sig <= '0';
                capture_active_sig <= '0';
                capture_error_sig <= '0';
                vsync_prev <= '0';
                hsync_prev <= '0';
                frame_start_pulse_sig <= '0';
                line_start_pulse_sig <= '0';
                frame_count_sig <= (others => '0');
                line_count_sig <= (others => '0');
                line_byte_count_sig <= (others => '0');
                last_line_bytes_sig <= (others => '0');
                line_count_i <= 0;
                line_byte_count_i <= 0;
                source_byte_count_sig <= (others => '0');

            else
                cfg_done_meta_pclk <= config_done_sig;
                cfg_done_sync_pclk <= cfg_done_meta_pclk;
                cfg_pass_meta_pclk <= config_pass_sig;
                cfg_pass_sync_pclk <= cfg_pass_meta_pclk;

                -- Event outputs are one cam_pclk wide.
                pixel_byte_valid_sig <= '0';
                frame_done_sig <= '0';
                frame_start_pulse_sig <= '0';
                line_start_pulse_sig <= '0';

                -- Sample sync/data for ILA visibility.
                pix_data_reg <= cam_pix_data;
                vsync_reg <= cam_vsync;
                hsync_reg <= cam_hsync;

                case capture_state is
                    when CAP_WAIT_CONFIG =>
                        vsync_prev <= cam_vsync;
                        hsync_prev <= cam_hsync;

                        if cfg_done_sync_pclk = '1' then
                            if cfg_pass_sync_pclk = '1' then
                                capture_state <= CAP_WAIT_VSYNC_INACTIVE;
                            else
                                capture_error_sig <= '1';
                                capture_state <= CAP_ERROR;
                            end if;
                        end if;

                    when CAP_WAIT_VSYNC_INACTIVE =>
                        vsync_prev <= cam_vsync;
                        hsync_prev <= cam_hsync;

                        if cam_vsync = '0' then
                            capture_state <= CAP_WAIT_VSYNC_ACTIVE;
                        end if;

                    when CAP_WAIT_VSYNC_ACTIVE =>
                        hsync_prev <= cam_hsync;
                        vsync_prev <= cam_vsync;

                        if (cam_vsync = '1') and (vsync_prev = '0') then
                            line_count_i <= 0;
                            line_byte_count_i <= 0;
                            source_byte_count_sig <= (others => '0');
                            line_count_sig <= (others => '0');
                            line_byte_count_sig <= (others => '0');
                            capture_active_sig <= '1';
                            frame_start_pulse_sig <= '1';
                            frame_count_sig <= frame_count_sig + 1;
                            capture_state <= CAP_CAPTURE;
                        end if;

                    when CAP_CAPTURE =>
                        -- VSYNC and HSYNC are active high in the selected
                        -- GC0308 configuration. Exactly G_FRAME_WIDTH*2 bytes
                        -- are accepted from each of G_FRAME_HEIGHT active lines.
                        if cam_vsync = '0' then
                            capture_active_sig <= '0';

                            if hsync_prev = '1' then
                                capture_error_sig <= '1';
                                capture_state <= CAP_ERROR;
                            elsif line_count_i = G_FRAME_HEIGHT then
                                frame_done_sig <= '1';
                                capture_state <= CAP_DONE;
                            else
                                capture_error_sig <= '1';
                                capture_state <= CAP_ERROR;
                            end if;

                        else
                            if (cam_hsync = '1') and (hsync_prev = '0') then
                                line_start_pulse_sig <= '1';
                                line_byte_count_i <= 0;
                                line_byte_count_sig <= (others => '0');

                                if line_count_i >= G_FRAME_HEIGHT then
                                    capture_error_sig <= '1';
                                    capture_state <= CAP_ERROR;
                                end if;
                            end if;

                            if cam_hsync = '1' then
                                if line_count_i < G_FRAME_HEIGHT then
                                    if line_byte_count_i < C_BYTES_PER_LINE then
                                        pixel_byte_valid_sig <= '1';
                                        source_byte_count_sig <= source_byte_count_sig + 1;
                                        -- This byte is the current DVP byte,
                                        -- sampled on this rising PCLK edge.
                                        pix_data_reg <= cam_pix_data;
                                        line_byte_count_i <= line_byte_count_i + 1;
                                        line_byte_count_sig <=
                                            to_unsigned(line_byte_count_i + 1,
                                                        line_byte_count_sig'length);
                                    else
                                        -- More than the configured active-line
                                        -- byte count: reject the frame.
                                        capture_error_sig <= '1';
                                        capture_state <= CAP_ERROR;
                                    end if;
                                end if;
                            end if;

                            if (hsync_prev = '1') and (cam_hsync = '0') then
                                last_line_bytes_sig <=
                                    to_unsigned(line_byte_count_i,
                                                last_line_bytes_sig'length);

                                if line_byte_count_i = C_BYTES_PER_LINE then
                                    if line_count_i < G_FRAME_HEIGHT then
                                        line_count_i <= line_count_i + 1;
                                        line_count_sig <=
                                            to_unsigned(line_count_i + 1,
                                                        line_count_sig'length);
                                    end if;
                                else
                                    capture_error_sig <= '1';
                                    capture_state <= CAP_ERROR;
                                end if;

                                line_byte_count_i <= 0;
                                line_byte_count_sig <= (others => '0');
                            end if;
                        end if;

                        vsync_prev <= cam_vsync;
                        hsync_prev <= cam_hsync;

                    when CAP_DONE =>
                        capture_active_sig <= '0';
                        pixel_byte_valid_sig <= '0';
                        -- One frame only. No retrigger from this instance.

                    when CAP_ERROR =>
                        capture_active_sig <= '0';
                        pixel_byte_valid_sig <= '0';

                    when others =>
                        capture_error_sig <= '1';
                        capture_state <= CAP_ERROR;
                end case;
            end if;
        end if;
    end process;

    capture_state_dbg <= std_logic_vector(
        to_unsigned(capture_state_t'pos(capture_state), capture_state_dbg'length)
    );

    cfg_state_dbg    <= std_logic_vector(to_unsigned(cfg_state_t'pos(cfg_state), cfg_state_dbg'length));
    init_index_dbg   <= std_logic_vector(to_unsigned(init_index, init_index_dbg'length));
    verify_index_dbg <= std_logic_vector(to_unsigned(verify_index, verify_index_dbg'length));

    assert G_FRAME_WIDTH <= 1023
        report "G_FRAME_WIDTH is too large for the line-byte counter"
        severity failure;

    assert G_FRAME_HEIGHT <= 1023
        report "G_FRAME_HEIGHT is too large for the line counter"
        severity failure;

end architecture;