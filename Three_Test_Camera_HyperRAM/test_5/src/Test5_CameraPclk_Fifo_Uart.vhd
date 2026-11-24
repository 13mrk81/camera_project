library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity Test5_CameraPclk_Fifo_Uart is
    port (
        clk8       : in  std_logic;
        key2_n_i   : in  std_logic;
        trigger_n_i : in  std_logic;
        uart_tx_o  : out std_logic;
        cam_clk    : out std_logic;
        cam_sda    : inout std_logic;
        cam_scl    : inout std_logic;
        cam_pclk   : in  std_logic;
        cam_vsync  : in  std_logic;
        cam_hsync  : in  std_logic
    );
end entity;

architecture rtl of Test5_CameraPclk_Fifo_Uart is
    component Gowin_PLLVR_1 is
        port (clkout : out std_logic; clkin : in std_logic);
    end component;

    component camera_interface is
        generic (
            G_CLK_FREQ_HZ     : positive := 24_000_000;
            G_I2C_DEVICE_ADDR : std_logic_vector(6 downto 0) := "0100001";
            G_RESET_WAIT_MS   : positive := 80;
            G_POR_RESET_MS    : positive := 1;
            G_FRAME_WIDTH     : positive := 640;
            G_FRAME_HEIGHT    : positive := 480
        );
        port (
            clk24               : in std_logic;
            clkcam              : out std_logic;
            rst_n               : in std_logic;
            rst_trigger         : in std_logic;
            cam_sda             : inout std_logic;
            cam_scl             : inout std_logic;
            cam_pclk            : in std_logic;
            cam_vsync           : in std_logic;
            cam_hsync           : in std_logic;
            cam_pix_data        : in std_logic_vector(7 downto 0);
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

    constant C_FIFO_WORDS : positive := 8;
    constant C_TRIGGER_DEBOUNCE_CYCLES : positive := 160_000; -- 20 ms at 8 MHz
    type payload_t is array (0 to C_FIFO_WORDS - 1) of std_logic_vector(31 downto 0);
    type wr_state_t is (WR_WAIT_FRAME, WR_FILL, WR_DONE);
    type rd_state_t is (RD_IDLE, RD_WAIT_DATA);
    type tx_state_t is (
        TX_IDLE, TX_SOF0, TX_SOF1, TX_TYPE, TX_SEQ_LO, TX_SEQ_HI,
        TX_LEN_LO, TX_LEN_HI, TX_PAYLOAD, TX_CRC_HI, TX_CRC_LO,
        TX_RELEASE
    );

    function diagnostic_word(index : natural) return std_logic_vector is
    begin
        case index is
            when 0 => return x"43414D5F"; -- CAM_
            when 1 => return x"50434C4B"; -- PCLK
            when 2 => return x"5F464946"; -- _FIF
            when 3 => return x"4F5F544F"; -- O_TO
            when 4 => return x"5F32344D"; -- _24M
            when 5 => return x"5F554152"; -- _UAR
            when 6 => return x"545F5445"; -- T_TE
            when others => return x"53543521"; -- ST5!
        end case;
    end function;

    function crc16_update(
        crc_in  : unsigned(15 downto 0);
        data_in : std_logic_vector(7 downto 0)
    ) return unsigned is
        variable c : unsigned(15 downto 0) := crc_in xor
            shift_left(resize(unsigned(data_in), 16), 8);
    begin
        for i in 0 to 7 loop
            if c(15) = '1' then
                c := shift_left(c, 1) xor to_unsigned(16#1021#, 16);
            else
                c := shift_left(c, 1);
            end if;
        end loop;
        return c;
    end function;

    signal rst_n       : std_logic := '0';
    signal rst_meta    : std_logic := '0';
    signal trigger_meta : std_logic := '1';
    signal trigger_sync : std_logic := '1';
    signal trigger_count : natural range 0 to C_TRIGGER_DEBOUNCE_CYCLES := 0;
    signal camera_trigger_req : std_logic := '0';
    signal clk24       : std_logic;
    signal clk24_rst_meta : std_logic := '0';
    signal clk24_rst_n : std_logic := '0';
    signal cam_rst_meta : std_logic := '0';
    signal cam_rst_n   : std_logic := '0';
    signal cam_clk_i   : std_logic;

    signal config_done : std_logic;
    signal config_pass : std_logic;
    signal config_done_meta_pclk : std_logic := '0';
    signal config_done_sync_pclk : std_logic := '0';
    signal config_pass_meta_pclk : std_logic := '0';
    signal config_pass_sync_pclk : std_logic := '0';

    signal vsync_prev    : std_logic := '0';
    signal hsync_prev    : std_logic := '0';
    signal frame_pending : std_logic := '0';
    signal wr_state      : wr_state_t := WR_WAIT_FRAME;
    signal wr_word_index : natural range 0 to C_FIFO_WORDS - 1 := 0;
    signal fifo_wr_en    : std_logic;
    signal fifo_wr_full  : std_logic;

    signal fifo_rd_en    : std_logic := '0';
    signal fifo_rd_data  : std_logic_vector(31 downto 0);
    signal fifo_rd_valid : std_logic;
    signal fifo_rd_empty : std_logic;
    signal rd_state      : rd_state_t := RD_IDLE;
    signal rd_word_index : natural range 0 to C_FIFO_WORDS - 1 := 0;
    signal payload_buf   : payload_t := (others => (others => '0'));
    signal payload_ready : std_logic := '0';
    signal payload_consumed : std_logic := '0';

    signal uart_data     : std_logic_vector(7 downto 0) := (others => '0');
    signal uart_valid    : std_logic := '0';
    signal uart_ready    : std_logic;
    signal tx_state      : tx_state_t := TX_IDLE;
    signal packet_seq    : unsigned(15 downto 0) := (others => '0');
    signal crc_reg       : unsigned(15 downto 0) := x"FFFF";
    signal payload_index : natural range 0 to 31 := 0;

begin
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
        port map (clkout => clk24, clkin => clk8);

    -- KEY1 is an active-low, debounced one-shot trigger for camera setup.
    -- The request remains high until reset; camera_interface detects its rising edge.
    process(clk8, rst_n)
    begin
        if rst_n = '0' then
            trigger_meta <= '1';
            trigger_sync <= '1';
            trigger_count <= 0;
            camera_trigger_req <= '0';
        elsif rising_edge(clk8) then
            trigger_meta <= trigger_n_i;
            trigger_sync <= trigger_meta;

            if camera_trigger_req = '0' then
                if trigger_sync = '0' then
                    if trigger_count = C_TRIGGER_DEBOUNCE_CYCLES - 1 then
                        camera_trigger_req <= '1';
                    else
                        trigger_count <= trigger_count + 1;
                    end if;
                else
                    trigger_count <= 0;
                end if;
            end if;
        end if;
    end process;

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

    -- Camera configuration is retained; the pixel data bus is unused and tied low.
    u_camera : camera_interface
        port map (
            clk24              => clk24,
            clkcam             => cam_clk_i,
            rst_n              => clk24_rst_n,
            rst_trigger        => camera_trigger_req,
            cam_sda            => cam_sda,
            cam_scl            => cam_scl,
            cam_pclk           => cam_pclk,
            cam_vsync          => cam_vsync,
            cam_hsync          => cam_hsync,
            cam_pix_data       => (others => '0'),
            frame_byte_o       => open,
            frame_byte_valid_o => open,
            frame_done_o       => open,
            frame_error_o      => open,
            config_done_o      => config_done,
            config_pass_o      => config_pass,
            line_count_o       => open,
            line_byte_count_o  => open
        );

    cam_clk <= cam_clk_i;

    -- Write one fixed diagnostic payload per frame, at the first active HREF
    -- rising edge after active-high VSYNC rises.
    fifo_wr_en <= '1' when (wr_state = WR_FILL) and (fifo_wr_full = '0') else '0';

    u_output_fifo : entity work.async_fifo_32
        generic map (G_ADDR_BITS => 4)
        port map (
            wr_rst_n   => cam_rst_n,
            rd_rst_n   => clk24_rst_n,
            wr_clk     => cam_pclk,
            wr_en_i    => fifo_wr_en,
            wr_data_i  => diagnostic_word(wr_word_index),
            wr_full_o  => fifo_wr_full,
            wr_level_o => open,
            rd_clk     => clk24,
            rd_en_i    => fifo_rd_en,
            rd_data_o  => fifo_rd_data,
            rd_valid_o => fifo_rd_valid,
            rd_empty_o => fifo_rd_empty,
            rd_level_o => open
        );

    process(cam_pclk, cam_rst_n)
    begin
        if cam_rst_n = '0' then
            config_done_meta_pclk <= '0';
            config_done_sync_pclk <= '0';
            config_pass_meta_pclk <= '0';
            config_pass_sync_pclk <= '0';
            vsync_prev <= '0';
            hsync_prev <= '0';
            frame_pending <= '0';
            wr_state <= WR_WAIT_FRAME;
            wr_word_index <= 0;
        elsif rising_edge(cam_pclk) then
            config_done_meta_pclk <= config_done;
            config_done_sync_pclk <= config_done_meta_pclk;
            config_pass_meta_pclk <= config_pass;
            config_pass_sync_pclk <= config_pass_meta_pclk;

            if (config_done_sync_pclk = '1') and (config_pass_sync_pclk = '1') then
                if cam_vsync = '0' then
                    vsync_prev <= '0';
                    hsync_prev <= cam_hsync;
                    frame_pending <= '0';
                else
                    if vsync_prev = '0' then
                        frame_pending <= '1';
                    end if;

                    if ((frame_pending = '1') or (vsync_prev = '0')) and
                       (cam_hsync = '1') and (hsync_prev = '0') and
                       (wr_state = WR_WAIT_FRAME) then
                        frame_pending <= '0';
                        wr_state <= WR_FILL;
                        wr_word_index <= 0;
                    end if;

                    vsync_prev <= '1';
                    hsync_prev <= cam_hsync;
                end if;
            else
                vsync_prev <= cam_vsync;
                hsync_prev <= cam_hsync;
                frame_pending <= '0';
            end if;

            if wr_state = WR_FILL then
                if fifo_wr_full = '0' then
                    if wr_word_index = C_FIFO_WORDS - 1 then
                        wr_word_index <= 0;
                        wr_state <= WR_DONE;
                    else
                        wr_word_index <= wr_word_index + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;

    -- 24 MHz FIFO reader. async_fifo_32 presents rd_valid one read-clock
    -- after an accepted rd_en; each word is collected before packetization.
    process(clk24, clk24_rst_n)
    begin
        if clk24_rst_n = '0' then
            fifo_rd_en <= '0';
            rd_state <= RD_IDLE;
            rd_word_index <= 0;
            payload_buf <= (others => (others => '0'));
            payload_ready <= '0';
        elsif rising_edge(clk24) then
            fifo_rd_en <= '0';
            if payload_consumed = '1' then
                payload_ready <= '0';
                rd_word_index <= 0;
                rd_state <= RD_IDLE;
            else
                case rd_state is
                    when RD_IDLE =>
                        if (payload_ready = '0') and (fifo_rd_empty = '0') then
                            fifo_rd_en <= '1';
                            rd_state <= RD_WAIT_DATA;
                        end if;
                    when RD_WAIT_DATA =>
                        if fifo_rd_valid = '1' then
                            payload_buf(rd_word_index) <= fifo_rd_data;
                            if rd_word_index = C_FIFO_WORDS - 1 then
                                rd_word_index <= 0;
                                payload_ready <= '1';
                                rd_state <= RD_IDLE;
                            else
                                rd_word_index <= rd_word_index + 1;
                                rd_state <= RD_IDLE;
                            end if;
                        end if;
                end case;
            end if;
        end if;
    end process;

    u_uart_tx : entity work.uart_tx
        generic map (
            G_CLK_FREQ_HZ => 24_000_000,
            G_BAUD_RATE => 115_200,
            G_INTER_BYTE_GAP_CYCLES => 80
        )
        port map (
            clk => clk24,
            rst_n => clk24_rst_n,
            data_i => uart_data,
            data_valid_i => uart_valid,
            data_ready_o => uart_ready,
            serial_tx_o => uart_tx_o
        );

    -- Same project packet envelope and CRC convention:
    -- A5 5A TYPE SEQ_LO SEQ_HI LEN_LO LEN_HI PAYLOAD CRC_HI CRC_LO.
    -- Test 5 uses TYPE=50 and a 32-byte payload.
    process(clk24, clk24_rst_n)
        variable shifted_word : unsigned(31 downto 0);
    begin
        if clk24_rst_n = '0' then
            uart_data <= (others => '0');
            uart_valid <= '0';
            tx_state <= TX_IDLE;
            packet_seq <= (others => '0');
            crc_reg <= x"FFFF";
            payload_index <= 0;
            payload_consumed <= '0';
        elsif rising_edge(clk24) then
            payload_consumed <= '0';

            if uart_valid = '1' then
                if uart_ready = '1' then
                    uart_valid <= '0';
                    case tx_state is
                        when TX_SOF0 => tx_state <= TX_SOF1;
                        when TX_SOF1 => tx_state <= TX_TYPE;
                        when TX_TYPE =>
                            crc_reg <= crc16_update(crc_reg, x"50");
                            tx_state <= TX_SEQ_LO;
                        when TX_SEQ_LO =>
                            crc_reg <= crc16_update(crc_reg, std_logic_vector(packet_seq(7 downto 0)));
                            tx_state <= TX_SEQ_HI;
                        when TX_SEQ_HI =>
                            crc_reg <= crc16_update(crc_reg, std_logic_vector(packet_seq(15 downto 8)));
                            tx_state <= TX_LEN_LO;
                        when TX_LEN_LO =>
                            crc_reg <= crc16_update(crc_reg, x"20");
                            tx_state <= TX_LEN_HI;
                        when TX_LEN_HI =>
                            crc_reg <= crc16_update(crc_reg, x"00");
                            payload_index <= 0;
                            tx_state <= TX_PAYLOAD;
                        when TX_PAYLOAD =>
                            crc_reg <= crc16_update(crc_reg, uart_data);
                            if payload_index = 31 then
                                tx_state <= TX_CRC_HI;
                            else
                                payload_index <= payload_index + 1;
                            end if;
                        when TX_CRC_HI => tx_state <= TX_CRC_LO;
                        when TX_CRC_LO =>
                            packet_seq <= packet_seq + 1;
                            payload_consumed <= '1';
                            tx_state <= TX_RELEASE;
                        when others => null;
                    end case;
                end if;
            else
                case tx_state is
                    when TX_IDLE =>
                        if payload_ready = '1' then
                            crc_reg <= x"FFFF";
                            tx_state <= TX_SOF0;
                        end if;
                    when TX_SOF0 =>
                        uart_data <= x"A5";
                        uart_valid <= '1';
                    when TX_SOF1 =>
                        uart_data <= x"5A";
                        uart_valid <= '1';
                    when TX_TYPE =>
                        uart_data <= x"50";
                        uart_valid <= '1';
                    when TX_SEQ_LO =>
                        uart_data <= std_logic_vector(packet_seq(7 downto 0));
                        uart_valid <= '1';
                    when TX_SEQ_HI =>
                        uart_data <= std_logic_vector(packet_seq(15 downto 8));
                        uart_valid <= '1';
                    when TX_LEN_LO =>
                        uart_data <= x"20";
                        uart_valid <= '1';
                    when TX_LEN_HI =>
                        uart_data <= x"00";
                        uart_valid <= '1';
                    when TX_PAYLOAD =>
                        shifted_word := shift_right(
                            unsigned(payload_buf(payload_index / 4)),
                            (3 - (payload_index mod 4)) * 8
                        );
                        uart_data <= std_logic_vector(shifted_word(7 downto 0));
                        uart_valid <= '1';
                    when TX_CRC_HI =>
                        uart_data <= std_logic_vector(crc_reg(15 downto 8));
                        uart_valid <= '1';
                    when TX_CRC_LO =>
                        uart_data <= std_logic_vector(crc_reg(7 downto 0));
                        uart_valid <= '1';
                    when TX_RELEASE =>
                        if payload_ready = '0' then
                            tx_state <= TX_IDLE;
                        end if;
                    when others => null;
                end case;
            end if;
        end if;
    end process;
end architecture;
