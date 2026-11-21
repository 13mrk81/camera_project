library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Version 1 diagnostic top:
--   1) Configure GC0308 and capture one complete frame (camera bytes are discarded).
--   2) Write a deterministic, address-dependent test pattern to HyperRAM.
--   3) Read the same address range back and compare every 32-bit word.
--
-- The camera is deliberately NOT connected to the HyperRAM write-data path.
-- HyperRAM uses the same 32-bit user interface, 8-beat burst and address stride
-- convention as the previous Camera_HyperRAM_OneFrame design.

entity Camera_HyperRAM_MemoryTest is
    generic (
        G_FRAME_WIDTH              : positive := 640;
        G_FRAME_HEIGHT             : positive := 480;
        G_CMD_INTERVAL_CYCLES      : positive := 21;
        G_WRITE_READ_GAP_CYCLES    : positive := 63;
        G_READ_TIMEOUT_CYCLES      : positive := 100_000;
        G_CAMERA_TIMEOUT_CYCLES    : positive := 120_000_000
    );
    port (
        clk8                : in  std_logic;
        trigger_n_i         : in  std_logic;
        test_pass_o         : out std_logic;

        cam_clk             : out std_logic;
        cam_sda             : inout std_logic;
        cam_scl             : inout std_logic;
        cam_pclk            : in  std_logic;
        cam_vsync           : in  std_logic;
        cam_hsync           : in  std_logic;
        cam_pix_data        : in  std_logic_vector(7 downto 0);

        O_hpram_ck          : out std_logic_vector(0 downto 0);
        O_hpram_ck_n        : out std_logic_vector(0 downto 0);
        IO_hpram_dq         : inout std_logic_vector(7 downto 0);
        IO_hpram_rwds       : inout std_logic_vector(0 downto 0);
        O_hpram_cs_n        : out std_logic_vector(0 downto 0);
        O_hpram_reset_n     : out std_logic_vector(0 downto 0)
    );
end entity;

architecture rtl of Camera_HyperRAM_MemoryTest is
    constant C_BURST_WORDS       : positive := 8;
    -- One 32-bit word represents the same storage footprint as two RGB565 pixels.
    constant C_TEST_WORDS        : positive := (G_FRAME_WIDTH * G_FRAME_HEIGHT) / 2;
    constant C_TEST_BURSTS       : positive := C_TEST_WORDS / C_BURST_WORDS;
    constant C_ADDR_STEP         : unsigned(21 downto 0) := to_unsigned(16, 22);
    constant C_PLL_STABLE_CYCLES : positive := 48_000;
    constant C_TRIGGER_DEBOUNCE  : positive := 160_000;
    constant C_CMD_GAP_CYCLES    : positive := G_CMD_INTERVAL_CYCLES - C_BURST_WORDS;

    component Gowin_PLLVR_1 is
        port (clkout : out std_logic; clkin : in std_logic);
    end component;

    component Gowin_PLLVR is
        port (clkout : out std_logic; lock : out std_logic; clkin : in std_logic);
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

    type test_state_t is (
        ST_WAIT_INIT,
        ST_WAIT_CAMERA,
        ST_WRITE_CMD,
        ST_WRITE_DATA,
        ST_WRITE_GAP,
        ST_WRITE_SETTLE,
        ST_READ_CMD,
        ST_READ_DATA,
        ST_DONE,
        ST_ERROR
    );

    signal rst_n                 : std_logic := '1';
    signal clk24                 : std_logic;
    signal clk96                 : std_logic;
    signal usr_clk               : std_logic;
    signal pll_locked            : std_logic;
    signal pll_lock_meta         : std_logic := '0';
    signal pll_lock_sync         : std_logic := '0';
    signal pll_lock_count        : natural range 0 to C_PLL_STABLE_CYCLES := 0;
    signal pll_stable            : std_logic := '0';
    signal ip_rst_n              : std_logic;
    signal usr_rst_meta          : std_logic := '0';
    signal usr_rst_n             : std_logic := '0';
    signal init_calib            : std_logic;

    signal trigger_meta          : std_logic := '1';
    signal trigger_sync          : std_logic := '1';
    signal trigger_stable        : std_logic := '1';
    signal trigger_count         : natural range 0 to C_TRIGGER_DEBOUNCE := 0;
    signal trigger_pulse         : std_logic := '0';
    signal camera_start_pulse    : std_logic;
    signal test_start_event      : std_logic;

    signal cam_clk_i             : std_logic;
    signal cam_frame_done        : std_logic;
    signal cam_frame_error       : std_logic;
    signal cam_config_done       : std_logic;
    signal cam_config_pass       : std_logic;
    signal cam_line_count        : std_logic_vector(9 downto 0);
    signal cam_line_byte_count   : std_logic_vector(10 downto 0);
    signal camera_frame_event    : std_logic;
    signal camera_frame_seen     : std_logic := '0';
    signal camera_error_meta     : std_logic := '0';
    signal camera_error_sync     : std_logic := '0';
    signal camera_timeout_count  : natural range 0 to G_CAMERA_TIMEOUT_CYCLES := 0;

    signal test_state            : test_state_t := ST_WAIT_INIT;
    signal write_addr            : unsigned(21 downto 0) := (others => '0');
    signal read_addr             : unsigned(21 downto 0) := (others => '0');
    signal write_word_index      : natural range 0 to C_TEST_WORDS - 1 := 0;
    signal read_word_index       : natural range 0 to C_TEST_WORDS - 1 := 0;
    signal write_word_count      : natural range 0 to C_TEST_WORDS := 0;
    signal read_word_count       : natural range 0 to C_TEST_WORDS := 0;
    signal write_beat_index      : natural range 1 to C_BURST_WORDS - 1 := 1;
    signal read_beat_index       : natural range 0 to C_BURST_WORDS - 1 := 0;
    signal gap_count             : natural range 0 to C_CMD_GAP_CYCLES - 1 := 0;
    signal settle_count          : natural range 0 to G_WRITE_READ_GAP_CYCLES := 0;
    signal read_timeout_count    : natural range 0 to G_READ_TIMEOUT_CYCLES := 0;
    signal cmd_wait_count        : natural range 0 to G_READ_TIMEOUT_CYCLES := 0;

    signal write_crc             : std_logic_vector(31 downto 0) := x"FFFFFFFF";
    signal read_crc              : std_logic_vector(31 downto 0) := x"FFFFFFFF";
    signal mismatch_found        : std_logic := '0';
    signal first_mismatch_addr   : std_logic_vector(21 downto 0) := (others => '0');
    signal first_expected        : std_logic_vector(31 downto 0) := (others => '0');
    signal first_actual          : std_logic_vector(31 downto 0) := (others => '0');
    signal test_error             : std_logic := '0';

    signal read_cmd_ready        : std_logic;
    signal read_ip_addr          : std_logic_vector(21 downto 0);
    signal read_ip_cmd           : std_logic;
    signal read_ip_cmd_en        : std_logic;
    signal read_data             : std_logic_vector(31 downto 0);
    signal read_data_valid       : std_logic;

    signal mem_cmd               : std_logic := '0';
    signal mem_cmd_en            : std_logic := '0';
    signal mem_addr              : std_logic_vector(21 downto 0) := (others => '0');
    signal mem_wr_data           : std_logic_vector(31 downto 0) := (others => '0');
    signal mem_rd_data           : std_logic_vector(31 downto 0);
    signal mem_rd_valid          : std_logic;
    signal mem_data_mask         : std_logic_vector(3 downto 0) := (others => '0');

    attribute syn_keep : integer;
    attribute syn_keep of test_state : signal is 1;
    attribute syn_keep of camera_frame_seen : signal is 1;
    attribute syn_keep of camera_error_sync : signal is 1;
    attribute syn_keep of write_addr : signal is 1;
    attribute syn_keep of read_addr : signal is 1;
    attribute syn_keep of write_word_count : signal is 1;
    attribute syn_keep of read_word_count : signal is 1;
    attribute syn_keep of write_crc : signal is 1;
    attribute syn_keep of read_crc : signal is 1;
    attribute syn_keep of mismatch_found : signal is 1;
    attribute syn_keep of first_mismatch_addr : signal is 1;
    attribute syn_keep of first_expected : signal is 1;
    attribute syn_keep of first_actual : signal is 1;
    attribute syn_keep of test_error : signal is 1;
    attribute syn_keep of cam_config_done : signal is 1;
    attribute syn_keep of cam_config_pass : signal is 1;
    attribute syn_keep of cam_line_count : signal is 1;
    attribute syn_keep of cam_line_byte_count : signal is 1;

    function test_pattern(index : natural) return std_logic_vector is
    begin
        -- Address-dependent data catches wrong address increments and aliasing.
        return x"CAFE0000" xor std_logic_vector(to_unsigned(index, 32));
    end function;

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
            if feedback = '1' then c := c xor POLY; end if;
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
    assert (G_FRAME_WIDTH mod 16) = 0
        report "G_FRAME_WIDTH must be divisible by 16 for 8-word burst alignment"
        severity failure;
    assert (C_TEST_WORDS mod C_BURST_WORDS) = 0
        report "Test word count must be divisible by the 8-word burst length"
        severity failure;
    assert G_CMD_INTERVAL_CYCLES > C_BURST_WORDS
        report "Command interval must exceed the burst length"
        severity failure;
    assert G_WRITE_READ_GAP_CYCLES > 0
        report "Write-to-read guard interval must be nonzero"
        severity failure;

    rst_n <= '1';

    u_pll_24 : Gowin_PLLVR_1
        port map (clkout => clk24, clkin => clk8);

    u_pll_96 : Gowin_PLLVR
        port map (clkout => clk96, lock => pll_locked, clkin => clk24);

    process(clk24, rst_n)
    begin
        if rst_n = '0' then
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

    ip_rst_n <= rst_n and pll_stable;

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

    -- KEY1 active-low debounce and one-shot trigger.
    process(clk8, rst_n)
    begin
        if rst_n = '0' then
            trigger_meta   <= '1';
            trigger_sync   <= '1';
            trigger_stable <= '1';
            trigger_count  <= 0;
            trigger_pulse  <= '0';
        elsif rising_edge(clk8) then
            trigger_meta <= trigger_n_i;
            trigger_sync <= trigger_meta;
            trigger_pulse <= '0';
            if trigger_sync = trigger_stable then
                trigger_count <= 0;
            elsif trigger_count = C_TRIGGER_DEBOUNCE - 1 then
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

    u_camera_start_cdc : entity work.pulse_toggle_cdc
        port map (
            src_clk => clk8, src_rst_n => rst_n, src_pulse_i => trigger_pulse,
            dst_clk => clk24, dst_rst_n => ip_rst_n, dst_pulse_o => camera_start_pulse
        );

    u_test_start_cdc : entity work.pulse_toggle_cdc
        port map (
            src_clk => clk8, src_rst_n => rst_n, src_pulse_i => trigger_pulse,
            dst_clk => usr_clk, dst_rst_n => usr_rst_n, dst_pulse_o => test_start_event
        );

    u_camera_frame_cdc : entity work.pulse_toggle_cdc
        port map (
            src_clk => cam_pclk, src_rst_n => ip_rst_n, src_pulse_i => cam_frame_done,
            dst_clk => usr_clk, dst_rst_n => usr_rst_n, dst_pulse_o => camera_frame_event
        );

    u_camera : entity work.camera_interface
        generic map (
            G_CLK_FREQ_HZ => 24_000_000,
            G_FRAME_WIDTH => G_FRAME_WIDTH,
            G_FRAME_HEIGHT => G_FRAME_HEIGHT
        )
        port map (
            clk24 => clk24,
            clkcam => cam_clk_i,
            rst_n => ip_rst_n,
            rst_trigger => camera_start_pulse,
            cam_sda => cam_sda,
            cam_scl => cam_scl,
            cam_pclk => cam_pclk,
            cam_vsync => cam_vsync,
            cam_hsync => cam_hsync,
            cam_pix_data => cam_pix_data,
            frame_byte_o => open,
            frame_byte_valid_o => open,
            frame_done_o => cam_frame_done,
            frame_error_o => cam_frame_error,
            config_done_o => cam_config_done,
            config_pass_o => cam_config_pass,
            line_count_o => cam_line_count,
            line_byte_count_o => cam_line_byte_count
        );

    cam_clk <= cam_clk_i;

    process(usr_clk, usr_rst_n)
    begin
        if usr_rst_n = '0' then
            camera_frame_seen <= '0';
            camera_error_meta <= '0';
            camera_error_sync <= '0';
        elsif rising_edge(usr_clk) then
            camera_error_meta <= cam_frame_error;
            camera_error_sync <= camera_error_meta;
            if camera_frame_event = '1' then
                camera_frame_seen <= '1';
            end if;
        end if;
    end process;

    u_read_adapter : entity work.gowin_hyperram_read_adapter
        generic map (
            G_ADDR_WIDTH => 22,
            G_CMD_INTERVAL_CYCLES => G_CMD_INTERVAL_CYCLES
        )
        port map (
            clk => usr_clk,
            rst_n => usr_rst_n,
            enable_i => '1' when (test_state = ST_READ_CMD or test_state = ST_READ_DATA) else '0',
            rd_cmd_valid_i => '1' when test_state = ST_READ_CMD else '0',
            rd_cmd_ready_o => read_cmd_ready,
            rd_cmd_addr_i => std_logic_vector(read_addr),
            ip_addr_o => read_ip_addr,
            ip_cmd_o => read_ip_cmd,
            ip_cmd_en_o => read_ip_cmd_en,
            ip_rd_data_i => mem_rd_data,
            ip_rd_data_valid_i => mem_rd_valid,
            rd_data_o => read_data,
            rd_data_valid_o => read_data_valid
        );

    -- HyperRAM writer and readback comparator.
    process(usr_clk, usr_rst_n)
    begin
        if usr_rst_n = '0' then
            test_state <= ST_WAIT_INIT;
            camera_timeout_count <= 0;
            write_addr <= (others => '0');
            read_addr <= (others => '0');
            write_word_index <= 0;
            read_word_index <= 0;
            write_word_count <= 0;
            read_word_count <= 0;
            write_beat_index <= 1;
            read_beat_index <= 0;
            gap_count <= 0;
            settle_count <= 0;
            read_timeout_count <= 0;
            cmd_wait_count <= 0;
            write_crc <= x"FFFFFFFF";
            read_crc <= x"FFFFFFFF";
            mismatch_found <= '0';
            first_mismatch_addr <= (others => '0');
            first_expected <= (others => '0');
            first_actual <= (others => '0');
            test_error <= '0';
        elsif rising_edge(usr_clk) then
            if camera_error_sync = '1' then
                test_error <= '1';
                test_state <= ST_ERROR;
            else
                case test_state is
                    when ST_WAIT_INIT =>
                        if init_calib = '1' then
                            test_state <= ST_WAIT_CAMERA;
                        end if;

                    when ST_WAIT_CAMERA =>
                        if test_start_event = '1' then
                            camera_timeout_count <= 0;
                        elsif camera_frame_seen = '1' then
                            test_state <= ST_WRITE_CMD;
                        elsif camera_timeout_count = G_CAMERA_TIMEOUT_CYCLES - 1 then
                            test_error <= '1';
                            test_state <= ST_ERROR;
                        elsif camera_timeout_count < G_CAMERA_TIMEOUT_CYCLES then
                            camera_timeout_count <= camera_timeout_count + 1;
                        end if;

                    when ST_WRITE_CMD =>
                        write_crc <= crc32_word(write_crc, test_pattern(write_word_index));
                        write_word_count <= write_word_count + 1;
                        write_word_index <= write_word_index + 1;
                        write_beat_index <= 1;
                        test_state <= ST_WRITE_DATA;

                    when ST_WRITE_DATA =>
                        write_crc <= crc32_word(write_crc, test_pattern(write_word_index));
                        write_word_count <= write_word_count + 1;
                        if write_beat_index = C_BURST_WORDS - 1 then
                            if write_word_index = C_TEST_WORDS - 1 then
                                settle_count <= 0;
                                test_state <= ST_WRITE_SETTLE;
                            else
                                write_addr <= write_addr + C_ADDR_STEP;
                                gap_count <= 0;
                                test_state <= ST_WRITE_GAP;
                            end if;
                        else
                            write_word_index <= write_word_index + 1;
                            write_beat_index <= write_beat_index + 1;
                        end if;

                    when ST_WRITE_GAP =>
                        if gap_count = C_CMD_GAP_CYCLES - 1 then
                            test_state <= ST_WRITE_CMD;
                        else
                            gap_count <= gap_count + 1;
                        end if;

                    when ST_WRITE_SETTLE =>
                        if settle_count = G_WRITE_READ_GAP_CYCLES - 1 then
                            read_addr <= (others => '0');
                            read_word_index <= 0;
                            read_word_count <= 0;
                            read_beat_index <= 0;
                            cmd_wait_count <= 0;
                            test_state <= ST_READ_CMD;
                        else
                            settle_count <= settle_count + 1;
                        end if;

                    when ST_READ_CMD =>
                        if read_cmd_ready = '1' then
                            read_beat_index <= 0;
                            read_timeout_count <= 0;
                            cmd_wait_count <= 0;
                            test_state <= ST_READ_DATA;
                        elsif cmd_wait_count = G_READ_TIMEOUT_CYCLES - 1 then
                            test_error <= '1';
                            test_state <= ST_ERROR;
                        else
                            cmd_wait_count <= cmd_wait_count + 1;
                        end if;

                    when ST_READ_DATA =>
                        if read_data_valid = '1' then
                            read_timeout_count <= 0;
                            read_crc <= crc32_word(read_crc, read_data);
                            read_word_count <= read_word_count + 1;

                            if read_data /= test_pattern(read_word_index) then
                                if mismatch_found = '0' then
                                    first_mismatch_addr <= std_logic_vector(
                                        read_addr + to_unsigned(read_beat_index * 2, 22)
                                    );
                                    first_expected <= test_pattern(read_word_index);
                                    first_actual <= read_data;
                                end if;
                                mismatch_found <= '1';
                            end if;

                            if read_beat_index = C_BURST_WORDS - 1 then
                                if read_word_index = C_TEST_WORDS - 1 then
                                    test_state <= ST_DONE;
                                else
                                    read_addr <= read_addr + C_ADDR_STEP;
                                    read_word_index <= read_word_index + 1;
                                    test_state <= ST_READ_CMD;
                                end if;
                            else
                                read_beat_index <= read_beat_index + 1;
                                read_word_index <= read_word_index + 1;
                            end if;
                        elsif read_timeout_count = G_READ_TIMEOUT_CYCLES - 1 then
                            test_error <= '1';
                            test_state <= ST_ERROR;
                        else
                            read_timeout_count <= read_timeout_count + 1;
                        end if;

                    when ST_DONE =>
                        test_state <= ST_DONE;

                    when ST_ERROR =>
                        test_state <= ST_ERROR;

                    when others =>
                        test_error <= '1';
                        test_state <= ST_ERROR;
                end case;
            end if;
        end if;
    end process;

    -- Single shared HyperRAM user port. Writer owns it until readback begins.
    process(test_state, write_addr, write_word_index, read_ip_addr, read_ip_cmd,
            read_ip_cmd_en)
    begin
        mem_cmd     <= read_ip_cmd;
        mem_cmd_en  <= read_ip_cmd_en;
        mem_addr    <= read_ip_addr;
        mem_wr_data <= (others => '0');

        if test_state = ST_WRITE_CMD then
            mem_cmd     <= '1';
            mem_cmd_en  <= '1';
            mem_addr    <= std_logic_vector(write_addr);
            mem_wr_data <= test_pattern(write_word_index);
        elsif test_state = ST_WRITE_DATA then
            mem_cmd     <= '0';
            mem_cmd_en  <= '0';
            mem_addr    <= std_logic_vector(write_addr);
            mem_wr_data <= test_pattern(write_word_index);
        end if;
    end process;

    mem_data_mask <= (others => '0');

    u_hyperram : HyperRAM_Memory_Interface_Top
        port map (
            clk => clk24,
            memory_clk => clk96,
            pll_lock => pll_stable,
            rst_n => ip_rst_n,
            O_hpram_ck => O_hpram_ck,
            O_hpram_ck_n => O_hpram_ck_n,
            IO_hpram_dq => IO_hpram_dq,
            IO_hpram_rwds => IO_hpram_rwds,
            O_hpram_cs_n => O_hpram_cs_n,
            O_hpram_reset_n => O_hpram_reset_n,
            wr_data => mem_wr_data,
            rd_data => mem_rd_data,
            rd_data_valid => mem_rd_valid,
            addr => mem_addr,
            cmd => mem_cmd,
            cmd_en => mem_cmd_en,
            init_calib => init_calib,
            clk_out => usr_clk,
            data_mask => mem_data_mask
        );

    -- LED is asserted only after all words have been read and every comparison passes.
    test_pass_o <= '1' when
        (test_state = ST_DONE) and
        (mismatch_found = '0') and
        (test_error = '0') and
        (read_crc = write_crc) and
        (read_word_count = C_TEST_WORDS) and
        (write_word_count = C_TEST_WORDS)
        else '0';
end architecture;
