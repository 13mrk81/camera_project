library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- One-shot GC0308 -> RGB565 HyperRAM capture and one-way RGB888 UART stream.
-- An on-board active-low pushbutton triggers capture; MATLAB is receive-only.
--
-- Memory format (640x480 defaults):
--   4 original RGB565 bytes per 32-bit user word
--   2 pixels per 32-bit word
--   320 words/line, 40 bursts/line, 8 user words/burst
--
-- HyperRAM command convention, 32-bit user bus, 8-beat burst and address
-- stride 16 are preserved from the supplied working top/reference design.
-- The address unit and command/data timing remain properties of the generated
-- Gowin IP and must be confirmed against its generated example/documentation.

entity Camera_HyperRAM_OneFrame is
    generic (
        G_FRAME_WIDTH             : positive := 640;
        G_FRAME_HEIGHT            : positive := 480;
        G_FIFO_ADDR_BITS          : positive := 12;
        G_OUTPUT_FIFO_ADDR_BITS   : positive := 9;
        G_CMD_INTERVAL_CYCLES     : positive := 32;
        G_WRITE_BURST_INTERVAL_CYCLES : positive := 32;
        G_WRITE_READ_GAP_CYCLES   : positive := 63;
        G_READ_TIMEOUT_CYCLES     : positive := 100_000;
        G_UART_PACKET_GAP_CYCLES   : positive := 160_000; -- 20 ms at 8 MHz
        G_UART_INTER_BYTE_GAP_CYCLES : positive := 80 -- 10 us at 8 MHz
    );
    port (
        -- 8 MHz board clock.
        clk8                : in  std_logic;

        -- Tang Nano 4K KEY2: active-low global system reset.
        key2_n_i            : in  std_logic;

        -- Tang Nano 4K KEY1: active-low on-board pushbutton trigger.
        trigger_n_i         : in  std_logic;
        -- FPGA -> MATLAB UART TX only; no host-to-FPGA UART data.
        uart_tx_o           : out std_logic;

        -- GC0308 connections.
        cam_clk             : out std_logic;
        cam_sda             : inout std_logic;
        cam_scl             : inout std_logic;
        cam_pclk            : in  std_logic;
        cam_vsync           : in  std_logic;
        cam_hsync           : in  std_logic;
        cam_pix_data        : in  std_logic_vector(7 downto 0);

        -- HyperRAM physical interface (same generated IP configuration).
        O_hpram_ck          : out std_logic_vector(0 downto 0);
        O_hpram_ck_n        : out std_logic_vector(0 downto 0);
        IO_hpram_dq         : inout std_logic_vector(7 downto 0);
        IO_hpram_rwds       : inout std_logic_vector(0 downto 0);
        O_hpram_cs_n        : out std_logic_vector(0 downto 0);
        O_hpram_reset_n     : out std_logic_vector(0 downto 0)
    );
end entity;

architecture rtl of Camera_HyperRAM_OneFrame is
    --------------------------------------------------------------------------
    -- Constants and types.
    --------------------------------------------------------------------------
    constant C_BYTES_PER_PIXEL       : positive := 2;
    constant C_PIXELS_PER_WORD       : positive := 2;
    constant C_WORDS_PER_LINE        : positive := G_FRAME_WIDTH / C_PIXELS_PER_WORD;
    constant C_BURST_WORDS           : positive := 8;
    constant C_BURSTS_PER_LINE       : positive := C_WORDS_PER_LINE / C_BURST_WORDS;
    constant C_TOTAL_PIXELS          : positive := G_FRAME_WIDTH * G_FRAME_HEIGHT;
    constant C_TOTAL_RAW_BYTES       : positive := C_TOTAL_PIXELS * C_BYTES_PER_PIXEL;
    constant C_TOTAL_WORDS           : positive := C_TOTAL_RAW_BYTES / 4;
    constant C_TOTAL_BURSTS          : positive := C_TOTAL_WORDS / C_BURST_WORDS;
    constant C_ADDR_STEP             : unsigned(21 downto 0) := to_unsigned(16, 22);
    constant C_PLL_STABLE_CYCLES     : positive := 48_000; -- 2 ms at 24 MHz
    constant C_TRIGGER_DEBOUNCE_CYCLES : positive := 160_000; -- 20 ms at 8 MHz
    constant C_MIN_GAP_CYCLES        : positive := G_WRITE_BURST_INTERVAL_CYCLES - C_BURST_WORDS;

    type burst_buffer_t is array (0 to C_BURST_WORDS - 1) of std_logic_vector(31 downto 0);

    type write_state_t is (
        W_WAIT_INIT,
        W_WAIT_BURST,
        W_LOAD_FIRST,
        W_WRITE_CMD,
        W_WRITE_DATA,
        W_LOAD_NEXT,
        W_WAIT_CAPTURE_END,
        W_DONE,
        W_ERROR
    );

    --------------------------------------------------------------------------
    -- Component declarations for generated Gowin IP and unchanged camera IP.
    --------------------------------------------------------------------------
    component Gowin_PLLVR_1 is
        port (
            clkout : out std_logic;
            clkin  : in  std_logic
        );
    end component;

    component Gowin_PLLVR is
        port (
            clkout : out std_logic;
            lock   : out std_logic;
            clkin  : in  std_logic
        );
    end component;

    component HyperRAM_Memory_Interface_Top is
        port (
            clk             : in    std_logic;
            memory_clk      : in    std_logic;
            pll_lock        : in    std_logic;
            rst_n           : in    std_logic;
            O_hpram_ck      : out   std_logic_vector(0 downto 0);
            O_hpram_ck_n    : out   std_logic_vector(0 downto 0);
            IO_hpram_dq     : inout std_logic_vector(7 downto 0);
            IO_hpram_rwds   : inout std_logic_vector(0 downto 0);
            O_hpram_cs_n    : out   std_logic_vector(0 downto 0);
            O_hpram_reset_n : out   std_logic_vector(0 downto 0);
            wr_data         : in    std_logic_vector(31 downto 0);
            rd_data         : out   std_logic_vector(31 downto 0);
            rd_data_valid   : out   std_logic;
            addr            : in    std_logic_vector(21 downto 0);
            cmd             : in    std_logic;
            cmd_en          : in    std_logic;
            init_calib      : out   std_logic;
            clk_out         : out   std_logic;
            data_mask       : in    std_logic_vector(3 downto 0)
        );
    end component;

    component camera_interface is
        generic (
            G_CLK_FREQ_HZ       : positive := 24_000_000;
            G_I2C_DEVICE_ADDR   : std_logic_vector(6 downto 0) := "0100001";
            G_RESET_WAIT_MS     : positive := 80;
            G_POR_RESET_MS      : positive := 1;
            G_FRAME_WIDTH       : positive := 640;
            G_FRAME_HEIGHT      : positive := 480
        );
        port (
            clk24               : in  std_logic;
            clkcam              : out std_logic;
            rst_n               : in  std_logic;
            rst_trigger         : in  std_logic;
            cam_sda             : inout std_logic;
            cam_scl             : inout std_logic;
            cam_pclk            : in  std_logic;
            cam_vsync           : in  std_logic;
            cam_hsync           : in  std_logic;
            cam_pix_data        : in  std_logic_vector(7 downto 0);
            frame_byte_o        : out std_logic_vector(7 downto 0);
            frame_byte_valid_o  : out std_logic;
            frame_done_o        : out std_logic;
            frame_error_o       : out std_logic;
            config_done_o       : out std_logic;
            config_pass_o       : out std_logic;
            line_count_o        : out std_logic_vector(9 downto 0);
            line_byte_count_o   : out std_logic_vector(10 downto 0)
        );
    end component;


    -- Global reset: asynchronous assertion from KEY2, synchronous release to clk8.
    signal rst_n              : std_logic := '0';
    signal rst_meta           : std_logic := '0';

    -- Reset releases synchronized independently into derived clock domains.
    signal clk24_rst_meta     : std_logic := '0';
    signal clk24_rst_n        : std_logic := '0';
    signal cam_rst_meta       : std_logic := '0';
    signal cam_rst_n          : std_logic := '0';
    --------------------------------------------------------------------------
    -- Clocks and HyperRAM IP interface.
    --------------------------------------------------------------------------
    signal clk24              : std_logic;
    signal clk96              : std_logic;
    signal usr_clk            : std_logic;
    signal pll_locked         : std_logic;
    signal pll_lock_meta      : std_logic := '0';
    signal pll_lock_sync      : std_logic := '0';
    signal pll_stable         : std_logic := '0';
    signal pll_lock_count     : natural range 0 to C_PLL_STABLE_CYCLES := 0;
    signal ip_rst_n           : std_logic;
    signal usr_rst_meta       : std_logic := '0';
    signal usr_rst_n          : std_logic := '0';
    signal init_calib_i       : std_logic;

    signal mem_cmd_i          : std_logic := '0';
    signal mem_cmd_en_i       : std_logic := '0';
    signal mem_addr_i         : std_logic_vector(21 downto 0) := (others => '0');
    signal mem_wr_data_i      : std_logic_vector(31 downto 0) := (others => '0');
    signal mem_rd_data_i      : std_logic_vector(31 downto 0);
    signal mem_rd_valid_i     : std_logic;
    signal mem_data_mask_i    : std_logic_vector(3 downto 0) := (others => '0');

    --------------------------------------------------------------------------
    -- Debounced KEY1 trigger, one-way UART TX protocol and CDC status levels.
    --------------------------------------------------------------------------
    signal camera_start_pulse : std_logic;
    signal protocol_transfer_start : std_logic;
    signal protocol_line_start : std_logic;
    signal protocol_line_index : std_logic_vector(15 downto 0);

    signal trigger_meta       : std_logic := '1';
    signal trigger_sync       : std_logic := '1';
    signal trigger_stable     : std_logic := '1';
    signal trigger_pulse      : std_logic := '0';
    signal trigger_count      : natural range 0 to C_TRIGGER_DEBOUNCE_CYCLES := 0;

    signal protocol_tx_data   : std_logic_vector(7 downto 0);
    signal protocol_tx_valid  : std_logic;
    signal protocol_tx_ready  : std_logic;
    signal protocol_src_ready : std_logic;
    signal protocol_busy      : std_logic;
    signal protocol_done      : std_logic;
    signal protocol_error     : std_logic;
    signal protocol_line_ack  : std_logic;
    signal line_ack_usr       : std_logic;

    signal write_done_meta_8  : std_logic := '0';
    signal write_done_sync_8  : std_logic := '0';
    signal frame_error_meta_8 : std_logic := '0';
    signal frame_error_sync_8: std_logic := '0';

    signal cam_config_done_meta_8 : std_logic := '0';
    signal cam_config_done_sync_8 : std_logic := '0';
    signal cam_config_pass_meta_8 : std_logic := '0';
    signal cam_config_pass_sync_8 : std_logic := '0';
    signal reader_error_meta_8    : std_logic := '0';
    signal reader_error_sync_8    : std_logic := '0';
    signal readout_error_8        : std_logic;

    signal serializer_error_meta_usr : std_logic := '0';
    signal serializer_error_sync_usr : std_logic := '0';
    signal protocol_error_meta_usr   : std_logic := '0';
    signal protocol_error_sync_usr   : std_logic := '0';

    signal cam_clk_i          : std_logic;
    signal cam_byte_data      : std_logic_vector(7 downto 0);
    signal cam_byte_valid     : std_logic;
    signal cam_frame_done     : std_logic;
    signal cam_frame_error    : std_logic;
    signal cam_config_done    : std_logic;
    signal cam_config_pass    : std_logic;
    signal cam_line_count     : std_logic_vector(9 downto 0);
    signal cam_line_byte_count: std_logic_vector(10 downto 0);

    --------------------------------------------------------------------------
    -- Raw RGB565 frame packer and capture FIFO #1.
    --------------------------------------------------------------------------
    signal cap_packed_word    : std_logic_vector(31 downto 0);
    signal cap_packed_valid   : std_logic;
    signal cap_capture_done   : std_logic;
    signal cap_capture_error  : std_logic;
    signal cap_capture_crc    : std_logic_vector(31 downto 0);
    signal cap_byte_count     : unsigned(31 downto 0);
    signal cap_word_count     : unsigned(31 downto 0);

    signal cap_fifo_full      : std_logic;
    signal cap_fifo_wr_level  : unsigned(G_FIFO_ADDR_BITS downto 0);
    signal cap_fifo_rd_level  : unsigned(G_FIFO_ADDR_BITS downto 0);
    signal cap_fifo_rd_empty  : std_logic;
    signal cap_fifo_rd_en     : std_logic;
    signal cap_fifo_rd_data   : std_logic_vector(31 downto 0);
    signal cap_fifo_rd_valid  : std_logic;
    signal cap_fifo_overflow_cam : std_logic := '0';
    signal capture_error_cam  : std_logic;

    --------------------------------------------------------------------------
    -- Capture-domain snapshot crossing to HyperRAM user-clock domain.
    --------------------------------------------------------------------------
    signal capture_snapshot_src : std_logic_vector(95 downto 0);
    signal capture_snapshot_usr : std_logic_vector(95 downto 0);
    signal capture_snapshot_valid_usr : std_logic;
    signal capture_crc_usr     : std_logic_vector(31 downto 0);
    signal capture_byte_count_usr : unsigned(31 downto 0);
    signal capture_word_count_usr : unsigned(31 downto 0);

    signal capture_error_meta_usr : std_logic := '0';
    signal capture_error_sync_usr : std_logic := '0';
    attribute async_reg : string;
    attribute async_reg of capture_error_meta_usr : signal is "true";
    attribute async_reg of capture_error_sync_usr : signal is "true";
    attribute async_reg of usr_rst_meta : signal is "true";
    attribute async_reg of rst_meta : signal is "true";
    attribute async_reg of clk24_rst_meta : signal is "true";
    attribute async_reg of clk24_rst_n : signal is "true";
    attribute async_reg of cam_rst_meta : signal is "true";
    attribute async_reg of cam_rst_n : signal is "true";
    attribute async_reg of write_done_meta_8 : signal is "true";
    attribute async_reg of write_done_sync_8 : signal is "true";
    attribute async_reg of frame_error_meta_8 : signal is "true";
    attribute async_reg of frame_error_sync_8 : signal is "true";
    attribute async_reg of serializer_error_meta_usr : signal is "true";
    attribute async_reg of serializer_error_sync_usr : signal is "true";
    attribute async_reg of protocol_error_meta_usr : signal is "true";
    attribute async_reg of protocol_error_sync_usr : signal is "true";
    attribute async_reg of trigger_meta : signal is "true";
    attribute async_reg of trigger_sync : signal is "true";
    attribute async_reg of cam_config_done_meta_8 : signal is "true";
    attribute async_reg of cam_config_done_sync_8 : signal is "true";
    attribute async_reg of cam_config_pass_meta_8 : signal is "true";
    attribute async_reg of cam_config_pass_sync_8 : signal is "true";
    attribute async_reg of reader_error_meta_8 : signal is "true";
    attribute async_reg of reader_error_sync_8 : signal is "true";

    --------------------------------------------------------------------------
    -- Capture FIFO -> HyperRAM write engine.
    --------------------------------------------------------------------------
    signal write_state        : write_state_t := W_WAIT_INIT;
    signal burst_buffer       : burst_buffer_t := (others => (others => '0'));
    signal write_fifo_rd_en   : std_logic;
    signal load_req_count     : natural range 0 to C_BURST_WORDS := 0;
    signal load_rsp_count     : natural range 0 to C_BURST_WORDS := 0;
    signal load_complete      : std_logic := '0';
    signal write_beat_index   : natural range 1 to C_BURST_WORDS - 1 := 1;
    signal write_addr         : unsigned(21 downto 0) := (others => '0');
    -- Independent address reference advances from its own emitted-word counter.
    signal write_addr_ref     : unsigned(21 downto 0) := (others => '0');
    signal write_ref_word_count : natural range 0 to C_TOTAL_WORDS := 0;
    signal write_ref_beat_count : natural range 0 to C_BURST_WORDS - 1 := 0;
    signal write_addr_error_reg : std_logic := '0';
    signal read_addr_error    : std_logic;
    signal write_word_count   : natural range 0 to C_TOTAL_WORDS := 0;
    signal write_crc_reg      : std_logic_vector(31 downto 0) := x"FFFFFFFF";
    signal write_done_reg     : std_logic := '0';
    signal write_error_reg    : std_logic := '0';
    signal gap_count          : natural range 0 to C_MIN_GAP_CYCLES := 0;

    --------------------------------------------------------------------------
    -- Read adapter and line-by-line readout subsystem.
    --------------------------------------------------------------------------
    signal readout_start_reg      : std_logic := '0'; -- clk8 domain, sticky
    signal readout_start_meta_usr : std_logic := '0';
    signal readout_start_sync_usr : std_logic := '0';
    attribute async_reg of readout_start_meta_usr : signal is "true";
    attribute async_reg of readout_start_sync_usr : signal is "true";

    signal line_cmd_valid     : std_logic;
    signal line_cmd_ready     : std_logic;
    signal line_cmd_addr      : std_logic_vector(21 downto 0);
    signal read_ip_addr       : std_logic_vector(21 downto 0);
    signal read_ip_cmd        : std_logic;
    signal read_ip_cmd_en     : std_logic;
    signal read_data_usr      : std_logic_vector(31 downto 0);
    signal read_data_valid_usr: std_logic;

    signal uart_tx_data       : std_logic_vector(7 downto 0);
    signal uart_tx_valid      : std_logic;
    signal uart_r_valid       : std_logic;
    signal uart_g_valid       : std_logic;
    signal uart_b_valid       : std_logic;
    signal rgb_r              : std_logic_vector(7 downto 0);
    signal rgb_g              : std_logic_vector(7 downto 0);
    signal rgb_b              : std_logic_vector(7 downto 0);

    signal line_read_req      : std_logic;
    signal line_ready         : std_logic;
    signal line_complete      : std_logic;
    signal frame_reader_done  : std_logic;
    signal serializer_done    : std_logic;
    signal read_pipeline_done : std_logic;
    signal read_ingress_crc_usr : std_logic_vector(31 downto 0);
    signal read_ingress_word_count_usr : unsigned(31 downto 0);
    signal reader_error       : std_logic;
    signal serializer_error   : std_logic;
    signal line_index         : unsigned(15 downto 0);
    signal line_word_count    : unsigned(15 downto 0);
    signal output_fifo_level  : unsigned(G_OUTPUT_FIFO_ADDR_BITS downto 0);
    signal readback_crc_uart       : std_logic_vector(31 downto 0);
    signal readback_raw_bytes_uart : unsigned(31 downto 0);
    signal readback_word_count_uart: unsigned(31 downto 0);
    signal output_pixel_count_uart : unsigned(31 downto 0);
    signal uart_byte_count_uart    : unsigned(31 downto 0);
    signal lines_sent_uart         : unsigned(15 downto 0);

    -- Serializer counters cross to usr_clk when the serializer completes.
    signal stream_stats_src       : std_logic_vector(175 downto 0);
    signal stream_stats_usr       : std_logic_vector(175 downto 0);
    signal stream_stats_valid_usr : std_logic;

    -- Final integrity telemetry crosses back to clk8 before the DONE packet.
    signal telemetry_snapshot_src : std_logic_vector(239 downto 0);
    signal telemetry_snapshot_8   : std_logic_vector(239 downto 0);
    signal telemetry_valid_8      : std_logic;
    signal telemetry_status_usr   : std_logic_vector(15 downto 0);
    signal telemetry_capture_crc_8 : std_logic_vector(31 downto 0);
    signal telemetry_write_crc_8 : std_logic_vector(31 downto 0);
    signal telemetry_read_ingress_crc_8 : std_logic_vector(31 downto 0);
    signal telemetry_source_bytes_8 : unsigned(31 downto 0);
    signal telemetry_capture_bytes_8 : unsigned(31 downto 0);
    signal telemetry_write_words_8 : unsigned(31 downto 0);
    signal telemetry_read_words_8 : unsigned(31 downto 0);
    signal telemetry_status_8 : std_logic_vector(15 downto 0);
    signal readback_crc           : std_logic_vector(31 downto 0);
    signal readback_raw_bytes     : unsigned(31 downto 0);
    signal readback_word_count    : unsigned(31 downto 0);
    signal output_pixel_count     : unsigned(31 downto 0);
    signal uart_byte_count        : unsigned(31 downto 0);
    signal lines_sent             : unsigned(15 downto 0);

    --------------------------------------------------------------------------
    -- Integrity checker and readback debug index.
    --------------------------------------------------------------------------
    signal system_ok          : std_logic;
    signal integrity_done     : std_logic;
    signal integrity_error    : std_logic;
    signal stream_error       : std_logic;
    signal read_response_count: natural range 0 to C_TOTAL_WORDS := 0;
    signal readback_index_reg : std_logic_vector(18 downto 0) := (others => '0');

    signal write_word_count_u32 : unsigned(31 downto 0);
    signal top_error            : std_logic;
    signal top_frame_error      : std_logic;

    --------------------------------------------------------------------------
    -- CRC helpers. Byte order is the original camera byte order, MSB first.
    --------------------------------------------------------------------------
    function crc32_byte(
        crc_in  : std_logic_vector(31 downto 0);
        data_in : std_logic_vector(7 downto 0)
    ) return std_logic_vector is
        variable c        : unsigned(31 downto 0) := unsigned(crc_in);
        variable feedback : std_logic;
        constant POLY     : unsigned(31 downto 0) := x"04C11DB7";
    begin
        for i in 7 downto 0 loop
            feedback := c(31) xor data_in(i);
            c := shift_left(c, 1);
            if feedback = '1' then
                c := c xor POLY;
            end if;
        end loop;
        return std_logic_vector(c);
    end function;

    function crc32_word(
        crc_in  : std_logic_vector(31 downto 0);
        data_in : std_logic_vector(31 downto 0)
    ) return std_logic_vector is
        variable c : std_logic_vector(31 downto 0) := crc_in;
    begin
        c := crc32_byte(c, data_in(31 downto 24));
        c := crc32_byte(c, data_in(23 downto 16));
        c := crc32_byte(c, data_in(15 downto 8));
        c := crc32_byte(c, data_in(7 downto 0));
        return c;
    end function;

begin
    --------------------------------------------------------------------------
    -- Static geometry checks.
    --------------------------------------------------------------------------
    assert (G_FRAME_WIDTH mod (C_PIXELS_PER_WORD * C_BURST_WORDS)) = 0
        report "G_FRAME_WIDTH must be divisible by 16 for 2-pixel words and 8-word bursts"
        severity failure;
    assert (C_TOTAL_WORDS mod C_BURST_WORDS) = 0
        report "Total raw RGB565 word count must be divisible by 8"
        severity failure;
    assert (2 ** G_OUTPUT_FIFO_ADDR_BITS) >= C_WORDS_PER_LINE
        report "Output FIFO must hold one complete line"
        severity failure;
    assert C_TOTAL_WORDS <= 524287
        report "Frame word count must fit the 19-bit debug counters"
        severity failure;
    assert G_CMD_INTERVAL_CYCLES > 0
        report "G_CMD_INTERVAL_CYCLES must be greater than zero"
        severity failure;
    assert G_WRITE_BURST_INTERVAL_CYCLES > C_BURST_WORDS
        report "G_WRITE_BURST_INTERVAL_CYCLES must be greater than the 8-beat burst length"
        severity failure;
    assert G_WRITE_READ_GAP_CYCLES > 0
        report "G_WRITE_READ_GAP_CYCLES must be greater than zero"
        severity failure;

    --------------------------------------------------------------------------
    -- Clock generation: unchanged 8 MHz -> 24 MHz -> 96 MHz configuration.
    --------------------------------------------------------------------------

    -- KEY2 is active-low. Assertion is asynchronous; release is synchronized
    -- to the always-running 8 MHz board clock.
    process(clk8, key2_n_i)
    begin
        if key2_n_i = '0' then
            rst_meta <= '0';
            rst_n    <= '0';
        elsif rising_edge(clk8) then
            rst_meta <= '1';
            rst_n    <= rst_meta;
        end if;
    end process;

    u_pll_24 : Gowin_PLLVR_1
        port map (
            clkout => clk24,
            clkin  => clk8
        );

    u_pll_96 : Gowin_PLLVR
        port map (
            clkout => clk96,
            lock   => pll_locked,
            clkin  => clk24
        );

    -- Release reset synchronously in the 24 MHz domain.
    process(clk24, rst_n)
    begin
        if rst_n = '0' then
            clk24_rst_meta <= '0';
            clk24_rst_n    <= '0';
        elsif rising_edge(clk24) then
            clk24_rst_meta <= '1';
            clk24_rst_n    <= clk24_rst_meta;
        end if;
    end process;

    -- Release reset synchronously in the camera pixel-clock domain.
    process(cam_pclk, rst_n)
    begin
        if rst_n = '0' then
            cam_rst_meta <= '0';
            cam_rst_n    <= '0';
        elsif rising_edge(cam_pclk) then
            cam_rst_meta <= '1';
            cam_rst_n    <= cam_rst_meta;
        end if;
    end process;

    process(clk24, clk24_rst_n)
    begin
        if clk24_rst_n = '0' then
            pll_lock_meta  <= '0';
            pll_lock_sync  <= '0';
            pll_lock_count <= 0;
            pll_stable     <= '0';
        elsif rising_edge(clk24) then
            pll_lock_meta <= pll_locked;
            pll_lock_sync <= pll_lock_meta;
            if pll_lock_sync = '0' then
                pll_lock_count <= 0;
                pll_stable <= '0';
            elsif pll_lock_count < C_PLL_STABLE_CYCLES then
                pll_lock_count <= pll_lock_count + 1;
            else
                pll_stable <= '1';
            end if;
        end if;
    end process;

    ip_rst_n <= clk24_rst_n and pll_stable;

    -- HyperRAM user-clock reset: asynchronous assertion, synchronous release.
    process(usr_clk, ip_rst_n)
    begin
        if ip_rst_n = '0' then
            usr_rst_meta <= '0';
            usr_rst_n    <= '0';
        elsif rising_edge(usr_clk) then
            usr_rst_meta <= '1';
            usr_rst_n    <= usr_rst_meta;
        end if;
    end process;

    --------------------------------------------------------------------------
    -- KEY1 active-low trigger: synchronize, debounce for 20 ms, and emit one
    -- clk8 pulse on a stable high-to-low transition.
    --------------------------------------------------------------------------
    process(clk8, rst_n)
    begin
        if rst_n = '0' then
            trigger_meta   <= '1';
            trigger_sync   <= '1';
            trigger_stable <= '1';
            trigger_count  <= 0;
            trigger_pulse  <= '0';
        elsif rising_edge(clk8) then
            trigger_meta  <= trigger_n_i;
            trigger_sync  <= trigger_meta;
            trigger_pulse <= '0';

            if trigger_sync = trigger_stable then
                trigger_count <= 0;
            elsif trigger_count = C_TRIGGER_DEBOUNCE_CYCLES - 1 then
                trigger_stable <= trigger_sync;
                trigger_count <= 0;
                if (trigger_stable = '1') and (trigger_sync = '0') then
                    trigger_pulse <= '1';
                end if;
            else
                trigger_count <= trigger_count + 1;
            end if;
        end if;
    end process;

    --------------------------------------------------------------------------
    -- One-way UART TX physical layer and staged camera stream protocol.
    --------------------------------------------------------------------------
    u_uart_tx : entity work.uart_tx
        generic map (
            G_CLK_FREQ_HZ           => 8_000_000,
            G_BAUD_RATE             => 115_200,
            G_INTER_BYTE_GAP_CYCLES => G_UART_INTER_BYTE_GAP_CYCLES
        )
        port map (
            clk => clk8, rst_n => rst_n, data_i => protocol_tx_data,
            data_valid_i => protocol_tx_valid, data_ready_o => protocol_tx_ready,
            serial_tx_o => uart_tx_o
        );

    u_camera_protocol : entity work.camera_uart_frame_protocol
        generic map (
            G_FRAME_WIDTH           => G_FRAME_WIDTH,
            G_FRAME_HEIGHT          => G_FRAME_HEIGHT,
            G_PACKET_GAP_CYCLES     => G_UART_PACKET_GAP_CYCLES,
            G_SOURCE_TIMEOUT_CYCLES => 32_000_000,
            G_FRAME_TIMEOUT_CYCLES  => 120_000_000
        )
        port map (
            clk => clk8, rst_n => rst_n,
            trigger_i => trigger_pulse,
            camera_config_done_i => cam_config_done_sync_8,
            camera_config_pass_i => cam_config_pass_sync_8,
            frame_available_i => write_done_sync_8,
            frame_error_i => frame_error_sync_8,
            readout_error_i => readout_error_8,
            serializer_done_i => serializer_done,
            telemetry_ready_i => telemetry_valid_8,
            capture_crc_i => telemetry_capture_crc_8,
            write_crc_i => telemetry_write_crc_8,
            read_ingress_crc_i => telemetry_read_ingress_crc_8,
            source_byte_count_i => telemetry_source_bytes_8,
            capture_byte_count_i => telemetry_capture_bytes_8,
            write_word_count_i => telemetry_write_words_8,
            read_ingress_word_count_i => telemetry_read_words_8,
            status_flags_i => telemetry_status_8,
            readback_crc_i => readback_crc_uart,
            pixel_count_i => output_pixel_count_uart,
            uart_byte_count_i => uart_byte_count_uart,
            lines_sent_i => lines_sent_uart,
            tx_data_o => protocol_tx_data,
            tx_valid_o => protocol_tx_valid,
            tx_ready_i => protocol_tx_ready,
            line_start_o => protocol_line_start,
            line_index_o => protocol_line_index,
            src_data_i => uart_tx_data,
            src_valid_i => uart_tx_valid,
            src_ready_o => protocol_src_ready,
            transfer_start_o => protocol_transfer_start,
            line_ack_o => protocol_line_ack,
            busy_o => protocol_busy, done_o => protocol_done,
            error_o => protocol_error
        );

    -- Debounced KEY1 event crosses into the camera's 24 MHz control domain.
    u_camera_start_cdc : entity work.pulse_toggle_cdc
        port map (
            src_clk => clk8, src_rst_n => rst_n,
            src_pulse_i => protocol_transfer_start,
            dst_clk => clk24, dst_rst_n => clk24_rst_n,
            dst_pulse_o => camera_start_pulse
        );

    -- Host ACK/NACK events cross from protocol clk8 to HyperRAM usr_clk.
    u_line_ack_cdc : entity work.pulse_toggle_cdc
        port map (
            src_clk => clk8, src_rst_n => rst_n,
            src_pulse_i => protocol_line_ack,
            dst_clk => usr_clk, dst_rst_n => usr_rst_n,
            dst_pulse_o => line_ack_usr
        );

    -- Synchronize sticky status levels into clk8 from clk24 and usr_clk.
    process(clk8, rst_n)
    begin
        if rst_n = '0' then
            write_done_meta_8 <= '0';
            write_done_sync_8 <= '0';
            frame_error_meta_8 <= '0';
            frame_error_sync_8 <= '0';
            cam_config_done_meta_8 <= '0';
            cam_config_done_sync_8 <= '0';
            cam_config_pass_meta_8 <= '0';
            cam_config_pass_sync_8 <= '0';
            reader_error_meta_8 <= '0';
            reader_error_sync_8 <= '0';
        elsif rising_edge(clk8) then
            write_done_meta_8 <= write_done_reg;
            write_done_sync_8 <= write_done_meta_8;
            frame_error_meta_8 <= capture_error_sync_usr or write_error_reg;
            frame_error_sync_8 <= frame_error_meta_8;

            cam_config_done_meta_8 <= cam_config_done;
            cam_config_done_sync_8 <= cam_config_done_meta_8;
            cam_config_pass_meta_8 <= cam_config_pass;
            cam_config_pass_sync_8 <= cam_config_pass_meta_8;

            reader_error_meta_8 <= reader_error;
            reader_error_sync_8 <= reader_error_meta_8;
        end if;
    end process;

    readout_error_8 <= reader_error_sync_8 or serializer_error;

    -- Serializer error is a clk8-domain status; synchronize it for the
    -- HyperRAM-domain integrity checker.
    process(usr_clk, usr_rst_n)
    begin
        if usr_rst_n = '0' then
            serializer_error_meta_usr <= '0';
            serializer_error_sync_usr <= '0';
        elsif rising_edge(usr_clk) then
            serializer_error_meta_usr <= serializer_error;
            serializer_error_sync_usr <= serializer_error_meta_usr;
        end if;
    end process;

    process(usr_clk, usr_rst_n)
    begin
        if usr_rst_n = '0' then
            protocol_error_meta_usr <= '0';
            protocol_error_sync_usr <= '0';
        elsif rising_edge(usr_clk) then
            protocol_error_meta_usr <= protocol_error;
            protocol_error_sync_usr <= protocol_error_meta_usr;
        end if;
    end process;

    u_camera : camera_interface
        generic map (
            G_FRAME_WIDTH  => G_FRAME_WIDTH,
            G_FRAME_HEIGHT => G_FRAME_HEIGHT
        )
        port map (
            clk24               => clk24,
            clkcam              => cam_clk_i,
            rst_n               => clk24_rst_n,
            rst_trigger         => camera_start_pulse,
            cam_sda             => cam_sda,
            cam_scl             => cam_scl,
            cam_pclk            => cam_pclk,
            cam_vsync           => cam_vsync,
            cam_hsync           => cam_hsync,
            cam_pix_data        => cam_pix_data,
            frame_byte_o        => cam_byte_data,
            frame_byte_valid_o  => cam_byte_valid,
            frame_done_o        => cam_frame_done,
            frame_error_o       => cam_frame_error,
            config_done_o       => cam_config_done,
            config_pass_o       => cam_config_pass,
            line_count_o        => cam_line_count,
            line_byte_count_o   => cam_line_byte_count
        );

    cam_clk <= cam_clk_i;

    --------------------------------------------------------------------------
    -- Capture packer: preserves the four original RGB565 bytes per word.
    --------------------------------------------------------------------------
    u_rgb565_packer : entity work.rgb565_frame_packer
        generic map (
            G_FRAME_WIDTH  => G_FRAME_WIDTH,
            G_FRAME_HEIGHT => G_FRAME_HEIGHT
        )
        port map (
            cam_pclk          => cam_pclk,
            rst_n             => cam_rst_n,
            cam_byte_i        => cam_byte_data,
            cam_byte_valid_i  => cam_byte_valid,
            cam_frame_done_i  => cam_frame_done,
            cam_frame_error_i => cam_frame_error,
            packed_word_o     => cap_packed_word,
            packed_valid_o    => cap_packed_valid,
            capture_done_o    => cap_capture_done,
            capture_error_o   => cap_capture_error,
            capture_crc_o     => cap_capture_crc,
            byte_count_o      => cap_byte_count,
            word_count_o      => cap_word_count
        );

    u_capture_fifo : entity work.async_fifo_32
        generic map (
            G_ADDR_BITS => G_FIFO_ADDR_BITS
        )
        port map (
            wr_rst_n   => cam_rst_n,
            rd_rst_n   => usr_rst_n,
            wr_clk     => cam_pclk,
            wr_en_i    => cap_packed_valid,
            wr_data_i  => cap_packed_word,
            wr_full_o  => cap_fifo_full,
            wr_level_o => cap_fifo_wr_level,
            rd_clk     => usr_clk,
            rd_en_i    => write_fifo_rd_en,
            rd_data_o  => cap_fifo_rd_data,
            rd_valid_o => cap_fifo_rd_valid,
            rd_empty_o => cap_fifo_rd_empty,
            rd_level_o => cap_fifo_rd_level
        );

    -- async_fifo_32 deliberately rejects a write while full; make that loss
    -- visible as a sticky capture error instead of silently accepting it.
    process(cam_pclk, cam_rst_n)
    begin
        if cam_rst_n = '0' then
            cap_fifo_overflow_cam <= '0';
        elsif rising_edge(cam_pclk) then
            if (cap_packed_valid = '1') and (cap_fifo_full = '1') then
                cap_fifo_overflow_cam <= '1';
            end if;
        end if;
    end process;

    capture_error_cam <= cap_capture_error or cap_fifo_overflow_cam;
    capture_snapshot_src <= cap_capture_crc &
                            std_logic_vector(cap_byte_count) &
                            std_logic_vector(cap_word_count);

    u_capture_snapshot_cdc : entity work.stable_bus_event_cdc
        generic map (
            G_WIDTH => 96
        )
        port map (
            src_clk     => cam_pclk,
            src_rst_n   => cam_rst_n,
            src_event_i => cap_capture_done,
            src_data_i  => capture_snapshot_src,
            dst_clk     => usr_clk,
            dst_rst_n   => usr_rst_n,
            dst_event_o => capture_snapshot_valid_usr,
            dst_data_o  => capture_snapshot_usr
        );

    capture_crc_usr        <= capture_snapshot_usr(95 downto 64);
    capture_byte_count_usr <= unsigned(capture_snapshot_usr(63 downto 32));
    capture_word_count_usr <= unsigned(capture_snapshot_usr(31 downto 0));

    process(usr_clk, usr_rst_n)
    begin
        if usr_rst_n = '0' then
            capture_error_meta_usr <= '0';
            capture_error_sync_usr <= '0';
        elsif rising_edge(usr_clk) then
            capture_error_meta_usr <= capture_error_cam;
            capture_error_sync_usr <= capture_error_meta_usr;
        end if;
    end process;

    process(usr_clk, usr_rst_n)
    begin
        if usr_rst_n = '0' then
            readout_start_meta_usr <= '0';
            readout_start_sync_usr <= '0';
        elsif rising_edge(usr_clk) then
            readout_start_meta_usr <= readout_start_reg;
            readout_start_sync_usr <= readout_start_meta_usr;
        end if;
    end process;

    --------------------------------------------------------------------------
    -- HyperRAM write engine.
    --------------------------------------------------------------------------
    write_fifo_rd_en <= '1' when
        ((write_state = W_LOAD_FIRST) or (write_state = W_LOAD_NEXT)) and
        (load_req_count < C_BURST_WORDS) and
        (cap_fifo_rd_empty = '0') else '0';

    process(usr_clk, usr_rst_n)
    begin
        if usr_rst_n = '0' then
            write_state      <= W_WAIT_INIT;
            burst_buffer     <= (others => (others => '0'));
            load_req_count   <= 0;
            load_rsp_count   <= 0;
            load_complete    <= '0';
            write_beat_index <= 1;
            write_word_count <= 0;
            write_crc_reg    <= x"FFFFFFFF";
            write_done_reg   <= '0';
            write_error_reg  <= '0';
            gap_count        <= 0;
        elsif rising_edge(usr_clk) then
            if (write_state = W_LOAD_FIRST) or (write_state = W_LOAD_NEXT) then
                if write_fifo_rd_en = '1' then
                    if load_req_count < C_BURST_WORDS then
                        load_req_count <= load_req_count + 1;
                    end if;
                end if;

                if cap_fifo_rd_valid = '1' then
                    if load_rsp_count < C_BURST_WORDS then
                        burst_buffer(load_rsp_count) <= cap_fifo_rd_data;
                        load_rsp_count <= load_rsp_count + 1;
                        if load_rsp_count = C_BURST_WORDS - 1 then
                            load_complete <= '1';
                        end if;
                    else
                        write_error_reg <= '1';
                        write_state <= W_ERROR;
                    end if;
                end if;
            end if;

            if (capture_error_sync_usr = '1') and
               (write_state /= W_DONE) and (write_state /= W_ERROR) then
                write_error_reg <= '1';
                write_state <= W_ERROR;
            else
                case write_state is
                    when W_WAIT_INIT =>
                        if init_calib_i = '1' then
                            write_state <= W_WAIT_BURST;
                        end if;

                    when W_WAIT_BURST =>
                        if cap_fifo_rd_level >= to_unsigned(C_BURST_WORDS,
                                                           cap_fifo_rd_level'length) then
                            load_req_count <= 0;
                            load_rsp_count <= 0;
                            load_complete <= '0';
                            write_state <= W_LOAD_FIRST;
                        elsif (capture_snapshot_valid_usr = '1') and
                              (cap_fifo_rd_empty = '1') and
                              (write_word_count < C_TOTAL_WORDS) then
                            write_error_reg <= '1';
                            write_state <= W_ERROR;
                        end if;

                    when W_LOAD_FIRST =>
                        if load_complete = '1' then
                            write_beat_index <= 1;
                            write_state <= W_WRITE_CMD;
                        end if;

                    when W_WRITE_CMD =>
                        write_crc_reg <= crc32_word(write_crc_reg, burst_buffer(0));
                        write_word_count <= write_word_count + 1;
                        write_beat_index <= 1;
                        write_state <= W_WRITE_DATA;

                    when W_WRITE_DATA =>
                        write_crc_reg <= crc32_word(write_crc_reg,
                                                    burst_buffer(write_beat_index));
                        write_word_count <= write_word_count + 1;

                        if write_beat_index = C_BURST_WORDS - 1 then
                            if write_word_count = C_TOTAL_WORDS - 1 then
                                write_state <= W_WAIT_CAPTURE_END;
                            else
                                load_req_count <= 0;
                                load_rsp_count <= 0;
                                load_complete <= '0';
                                gap_count <= 0;
                                write_state <= W_LOAD_NEXT;
                            end if;
                        else
                            write_beat_index <= write_beat_index + 1;
                        end if;

                    when W_LOAD_NEXT =>
                        if gap_count < C_MIN_GAP_CYCLES then
                            gap_count <= gap_count + 1;
                        end if;
                        if (load_complete = '1') and
                           (gap_count >= C_MIN_GAP_CYCLES - 1) then
                            write_beat_index <= 1;
                            write_state <= W_WRITE_CMD;
                        end if;

                    when W_WAIT_CAPTURE_END =>
                        if capture_snapshot_valid_usr = '1' then
                            if (capture_byte_count_usr /= to_unsigned(C_TOTAL_RAW_BYTES, 32)) or
                               (capture_word_count_usr /= to_unsigned(C_TOTAL_WORDS, 32)) then
                                write_error_reg <= '1';
                                write_state <= W_ERROR;
                            elsif (cap_fifo_rd_empty = '1') and
                                  (write_word_count = C_TOTAL_WORDS) then
                                write_done_reg <= '1';
                                write_state <= W_DONE;
                            end if;
                        end if;

                    when W_DONE =>
                        write_state <= W_DONE;

                    when W_ERROR =>
                        write_state <= W_ERROR;

                    when others =>
                        write_error_reg <= '1';
                        write_state <= W_ERROR;
                end case;
            end if;
        end if;
    end process;

    --------------------------------------------------------------------------
    -- HyperRAM read adapter, line reader, output FIFO #2 and RGB serializer.
    -- Serializer byte stream is consumed by the clk8 UART protocol engine.
    --------------------------------------------------------------------------
    u_hyperram_read_adapter : entity work.gowin_hyperram_read_adapter
        generic map (
            G_ADDR_WIDTH          => 22,
            G_CMD_INTERVAL_CYCLES => G_CMD_INTERVAL_CYCLES
        )
        port map (
            clk                => usr_clk,
            rst_n              => usr_rst_n,
            enable_i           => readout_start_sync_usr,
            rd_cmd_valid_i     => line_cmd_valid,
            rd_cmd_ready_o     => line_cmd_ready,
            rd_cmd_addr_i      => line_cmd_addr,
            ip_addr_o          => read_ip_addr,
            ip_cmd_o           => read_ip_cmd,
            ip_cmd_en_o        => read_ip_cmd_en,
            ip_rd_data_i       => mem_rd_data_i,
            ip_rd_data_valid_i => mem_rd_valid_i,
            rd_data_o          => read_data_usr,
            rd_data_valid_o    => read_data_valid_usr
        );

    u_line_readout : entity work.hyperram_line_readout
        generic map (
            G_FRAME_WIDTH          => G_FRAME_WIDTH,
            G_FRAME_HEIGHT         => G_FRAME_HEIGHT,
            G_ADDR_WIDTH           => 22,
            G_BASE_ADDR            => (others => '0'),
            G_BURST_WORDS          => C_BURST_WORDS,
            G_BURST_ADDR_STRIDE    => 16,
            G_FIFO_ADDR_BITS       => G_OUTPUT_FIFO_ADDR_BITS,
            G_READ_TIMEOUT_CYCLES  => G_READ_TIMEOUT_CYCLES
        )
        port map (
            mem_clk                => usr_clk,
            uart_clk               => clk8,
            mem_rst_n              => usr_rst_n,
            uart_rst_n             => rst_n,
            frame_written_i        => readout_start_sync_usr,
            line_ack_i             => line_ack_usr,
            line_retry_i           => '0', -- no host NACK on the one-way stream
            line_ack_uart_i        => protocol_line_ack,
            line_retry_uart_i      => '0',
            mem_rd_cmd_valid_o     => line_cmd_valid,
            mem_rd_cmd_ready_i     => line_cmd_ready,
            mem_rd_addr_o          => line_cmd_addr,
            mem_rd_data_i          => read_data_usr,
            mem_rd_data_valid_i    => read_data_valid_usr,
            uart_tx_data_o         => uart_tx_data,
            uart_tx_valid_o        => uart_tx_valid,
            uart_tx_ready_i        => protocol_src_ready,
            uart_r_valid_o         => uart_r_valid,
            uart_g_valid_o         => uart_g_valid,
            uart_b_valid_o         => uart_b_valid,
            rgb_r_o                => rgb_r,
            rgb_g_o                => rgb_g,
            rgb_b_o                => rgb_b,
            line_read_req_o        => line_read_req,
            line_ready_o           => line_ready,
            line_consumed_o        => open,
            line_complete_o        => line_complete,
            frame_stream_done_o    => frame_reader_done,
            serializer_done_o      => serializer_done,
            reader_error_o         => reader_error,
            serializer_error_o     => serializer_error,
            line_index_o           => line_index,
            line_word_count_o      => line_word_count,
            fifo_write_level_o     => output_fifo_level,
            readback_crc_o         => readback_crc_uart,
            read_ingress_crc_o        => read_ingress_crc_usr,
            read_ingress_word_count_o => read_ingress_word_count_usr,
            raw_byte_count_o       => readback_raw_bytes_uart,
            read_word_count_o      => readback_word_count_uart,
            pixel_count_o          => output_pixel_count_uart,
            uart_byte_count_o      => uart_byte_count_uart,
            lines_sent_o           => lines_sent_uart,
            addr_check_error_o     => read_addr_error
        );

    -- Begin prefetch when the protocol starts the first LINE packet. The
    -- synchronized level remains asserted for every row in this one-shot frame.
    process(clk8, rst_n)
    begin
        if rst_n = '0' then
            readout_start_reg <= '0';
        elsif rising_edge(clk8) then
            if protocol_line_start = '1' then
                readout_start_reg <= '1';
            end if;
        end if;
    end process;

    -- Shared user interface to HyperRAM: writer has priority until write_done.
    process(write_state, write_addr, burst_buffer, write_beat_index,
            read_ip_addr, read_ip_cmd, read_ip_cmd_en)
    begin
        mem_cmd_i     <= read_ip_cmd;
        mem_cmd_en_i  <= read_ip_cmd_en;
        mem_addr_i    <= read_ip_addr;
        mem_wr_data_i <= (others => '0');

        if write_state = W_WRITE_CMD then
            mem_cmd_i     <= '1';
            mem_cmd_en_i  <= '1';
            mem_addr_i    <= std_logic_vector(write_addr);
            mem_wr_data_i <= burst_buffer(0);
        elsif write_state = W_WRITE_DATA then
            mem_cmd_i     <= '0';
            mem_cmd_en_i  <= '0';
            mem_wr_data_i <= burst_buffer(write_beat_index);
        end if;
    end process;

    mem_data_mask_i <= (others => '0');

    u_hyperram : HyperRAM_Memory_Interface_Top
        port map (
            clk             => clk24,
            memory_clk      => clk96,
            pll_lock        => pll_stable,
            rst_n           => ip_rst_n,
            O_hpram_ck      => O_hpram_ck,
            O_hpram_ck_n    => O_hpram_ck_n,
            IO_hpram_dq     => IO_hpram_dq,
            IO_hpram_rwds   => IO_hpram_rwds,
            O_hpram_cs_n    => O_hpram_cs_n,
            O_hpram_reset_n => O_hpram_reset_n,
            wr_data         => mem_wr_data_i,
            rd_data         => mem_rd_data_i,
            rd_data_valid   => mem_rd_valid_i,
            addr            => mem_addr_i,
            cmd             => mem_cmd_i,
            cmd_en          => mem_cmd_en_i,
            init_calib      => init_calib_i,
            clk_out         => usr_clk,
            data_mask       => mem_data_mask_i
        );

    --------------------------------------------------------------------------
    -- Read-response index tracking (retained internally for debug/analysis).
    --------------------------------------------------------------------------
    process(usr_clk, usr_rst_n)
    begin
        if usr_rst_n = '0' then
            read_response_count <= 0;
            readback_index_reg <= (others => '0');
        elsif rising_edge(usr_clk) then
            if read_data_valid_usr = '1' then
                if read_response_count < C_TOTAL_WORDS then
                    readback_index_reg <= std_logic_vector(to_unsigned(read_response_count, 19));
                    read_response_count <= read_response_count + 1;
                end if;
            end if;
        end if;
    end process;

    --------------------------------------------------------------------------
    -- End-to-end integrity checker. The final statistics snapshot is captured
    -- only after the DONE packet has completed its UART stop bit.
    --------------------------------------------------------------------------
    -- Serializer statistics cross when the serializer has consumed the frame.
    stream_stats_src <= readback_crc_uart &
                        std_logic_vector(readback_raw_bytes_uart) &
                        std_logic_vector(readback_word_count_uart) &
                        std_logic_vector(output_pixel_count_uart) &
                        std_logic_vector(uart_byte_count_uart) &
                        std_logic_vector(lines_sent_uart);

    u_stream_stats_cdc : entity work.stable_bus_event_cdc
        generic map (G_WIDTH => 176)
        port map (
            src_clk => clk8, src_rst_n => rst_n,
            src_event_i => serializer_done, src_data_i => stream_stats_src,
            dst_clk => usr_clk, dst_rst_n => usr_rst_n,
            dst_event_o => stream_stats_valid_usr, dst_data_o => stream_stats_usr
        );

    readback_crc       <= stream_stats_usr(175 downto 144);
    readback_raw_bytes <= unsigned(stream_stats_usr(143 downto 112));
    readback_word_count<= unsigned(stream_stats_usr(111 downto 80));
    output_pixel_count <= unsigned(stream_stats_usr(79 downto 48));
    uart_byte_count    <= unsigned(stream_stats_usr(47 downto 16));
    lines_sent         <= unsigned(stream_stats_usr(15 downto 0));

    write_word_count_u32 <= to_unsigned(write_word_count, 32);
    stream_error <= reader_error or serializer_error_sync_usr or protocol_error_sync_usr;
    read_pipeline_done <= frame_reader_done and stream_stats_valid_usr;

    u_integrity_checker : entity work.frame_integrity_checker
        generic map (
            G_FRAME_WIDTH  => G_FRAME_WIDTH,
            G_FRAME_HEIGHT => G_FRAME_HEIGHT
        )
        port map (
            clk                   => usr_clk,
            rst_n                 => usr_rst_n,
            capture_done_i        => capture_snapshot_valid_usr,
            write_done_i          => write_done_reg,
            stream_done_i         => read_pipeline_done,
            uart_idle_i           => frame_reader_done,
            capture_error_i       => capture_error_sync_usr,
            write_error_i         => write_error_reg or write_addr_error_reg,
            stream_error_i        => stream_error or read_addr_error,
            capture_crc_i         => capture_crc_usr,
            write_crc_i           => write_crc_reg,
            read_ingress_crc_i     => read_ingress_crc_usr,
            readback_crc_i        => readback_crc,
            capture_byte_count_i  => capture_byte_count_usr,
            write_word_count_i    => write_word_count_u32,
            read_ingress_word_count_i => read_ingress_word_count_usr,
            readback_raw_bytes_i  => readback_raw_bytes,
            readback_word_count_i => readback_word_count,
            pixel_count_i         => output_pixel_count,
            uart_byte_count_i     => uart_byte_count,
            line_count_i          => lines_sent,
            system_ok_o           => system_ok,
            integrity_done_o      => integrity_done,
            error_o               => integrity_error
        );

    telemetry_status_usr(0)  <= capture_error_sync_usr;
    telemetry_status_usr(1)  <= write_error_reg;
    telemetry_status_usr(2)  <= reader_error;
    telemetry_status_usr(3)  <= serializer_error_sync_usr;
    telemetry_status_usr(4)  <= protocol_error_sync_usr;
    telemetry_status_usr(5)  <= '1' when capture_crc_usr /= write_crc_reg else '0';
    telemetry_status_usr(6)  <= '1' when write_crc_reg /= read_ingress_crc_usr else '0';
    telemetry_status_usr(7)  <= '1' when capture_byte_count_usr /= to_unsigned(C_TOTAL_RAW_BYTES, 32) else '0';
    telemetry_status_usr(8)  <= '1' when write_word_count_u32 /= to_unsigned(C_TOTAL_WORDS, 32) else '0';
    telemetry_status_usr(9)  <= '1' when read_ingress_word_count_usr /= to_unsigned(C_TOTAL_WORDS, 32) else '0';
    -- The packer exposes a single source-byte counter, so both payload fields
    -- report that same measured source/capture byte total.
    telemetry_status_usr(10) <= '0';
    -- DONE status bit 11: write-address reference mismatch (0 = PASS).
    telemetry_status_usr(11) <= write_addr_error_reg;
    -- DONE status bit 12: read-address reference mismatch (0 = PASS).
    telemetry_status_usr(12) <= read_addr_error;
    telemetry_status_usr(13) <= system_ok;
    telemetry_status_usr(15 downto 14) <= (others => '0');

    telemetry_snapshot_src <= capture_crc_usr &
                              write_crc_reg &
                              read_ingress_crc_usr &
                              std_logic_vector(capture_byte_count_usr) &
                              std_logic_vector(capture_byte_count_usr) &
                              std_logic_vector(write_word_count_u32) &
                              std_logic_vector(read_ingress_word_count_usr) &
                              telemetry_status_usr;

    u_telemetry_snapshot_cdc : entity work.stable_bus_event_cdc
        generic map (G_WIDTH => 240)
        port map (
            src_clk     => usr_clk,
            src_rst_n   => usr_rst_n,
            src_event_i => integrity_done,
            src_data_i  => telemetry_snapshot_src,
            dst_clk     => clk8,
            dst_rst_n   => rst_n,
            dst_event_o => telemetry_valid_8,
            dst_data_o  => telemetry_snapshot_8
        );

    telemetry_capture_crc_8       <= telemetry_snapshot_8(239 downto 208);
    telemetry_write_crc_8          <= telemetry_snapshot_8(207 downto 176);
    telemetry_read_ingress_crc_8   <= telemetry_snapshot_8(175 downto 144);
    telemetry_source_bytes_8       <= unsigned(telemetry_snapshot_8(143 downto 112));
    telemetry_capture_bytes_8      <= unsigned(telemetry_snapshot_8(111 downto 80));
    telemetry_write_words_8        <= unsigned(telemetry_snapshot_8(79 downto 48));
    telemetry_read_words_8         <= unsigned(telemetry_snapshot_8(47 downto 16));
    telemetry_status_8             <= telemetry_snapshot_8(15 downto 0);

    --------------------------------------------------------------------------
    -- Internal status/error aggregation. No debug/status top-level ports.
    --------------------------------------------------------------------------
    top_frame_error <= capture_error_sync_usr or write_error_reg or write_addr_error_reg or
                       reader_error or read_addr_error or serializer_error_sync_usr or protocol_error_sync_usr;
    top_error <= top_frame_error or integrity_error;

    --------------------------------------------------------------------------
    -- Dedicated HyperRAM write address register.
    -- Address advances once after each completed 8-word burst,
    -- except after the final burst.
    --------------------------------------------------------------------------
    process(usr_clk, usr_rst_n)
    begin
        if usr_rst_n = '0' then
            write_addr <= (others => '0');
        elsif rising_edge(usr_clk) then
            if (write_state = W_WRITE_DATA) and
               (write_beat_index = C_BURST_WORDS - 1) and
               (write_word_count /= C_TOTAL_WORDS - 1) then
                write_addr <= write_addr + C_ADDR_STEP;
            end if;
        end if;
    end process;

    -- Independent WRITE address checker. The reference uses its own word/beat
    -- counters and does not use write_word_count, write_beat_index or write_addr.
    process(usr_clk, usr_rst_n)
    begin
        if usr_rst_n = '0' then
            write_addr_ref        <= (others => '0');
            write_ref_word_count  <= 0;
            write_ref_beat_count  <= 0;
            write_addr_error_reg  <= '0';
        elsif rising_edge(usr_clk) then
            if write_addr /= write_addr_ref then
                write_addr_error_reg <= '1';
            end if;

            -- W_WRITE_CMD emits word 0; each W_WRITE_DATA cycle emits one
            -- subsequent word. Count these independently of the main counters.
            if (write_state = W_WRITE_CMD) or (write_state = W_WRITE_DATA) then
                if write_ref_word_count < C_TOTAL_WORDS then
                    write_ref_word_count <= write_ref_word_count + 1;
                end if;

                if write_ref_beat_count = C_BURST_WORDS - 1 then
                    write_ref_beat_count <= 0;
                    if write_ref_word_count < C_TOTAL_WORDS - 1 then
                        write_addr_ref <= write_addr_ref + C_ADDR_STEP;
                    end if;
                else
                    write_ref_beat_count <= write_ref_beat_count + 1;
                end if;
            end if;
        end if;
    end process;

end architecture rtl;