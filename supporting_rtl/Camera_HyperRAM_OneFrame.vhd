library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- One-shot GC0308 -> RGB888 pixel words -> HyperRAM -> full readback/CRC.
--
-- Pixel memory format:
--   one 32-bit HyperRAM user word per pixel = 0x00RRGGBB
--   row-major order, exactly G_FRAME_WIDTH words per line.
--
-- The HyperRAM user interface and its burst timing follow the supplied
-- HyperRAM_Burst_Test: 32-bit user data, 8 beats/burst, address step 16.

entity Camera_HyperRAM_OneFrame is
    generic (
        G_FRAME_WIDTH             : positive := 640;
        G_FRAME_HEIGHT            : positive := 480;
        G_FIFO_ADDR_BITS          : positive := 10;
        G_CMD_INTERVAL_CYCLES     : positive := 21;
        G_WRITE_READ_GAP_CYCLES   : positive := 63
    );
    port (
        -- 8 MHz board clock and global active-low reset.
        clk8                : in  std_logic;
        rst_n               : in  std_logic;

        -- One rising-edge command from UART. This starts camera configuration.
        rst_trigger         : in  std_logic;

        -- GC0308 connections.
        cam_clk             : out std_logic;
        cam_sda             : inout std_logic;
        cam_scl             : inout std_logic;
        cam_pclk            : in  std_logic;
        cam_vsync           : in  std_logic;
        cam_hsync           : in  std_logic;
        cam_pix_data        : in  std_logic_vector(7 downto 0);

        -- HyperRAM physical interface.
        O_hpram_ck          : out std_logic_vector(0 downto 0);
        O_hpram_ck_n        : out std_logic_vector(0 downto 0);
        IO_hpram_dq         : inout std_logic_vector(7 downto 0);
        IO_hpram_rwds       : inout std_logic_vector(0 downto 0);
        O_hpram_cs_n        : out std_logic_vector(0 downto 0);
        O_hpram_reset_n     : out std_logic_vector(0 downto 0);

        -- Main status.
        init_calib_o        : out std_logic;
        frame_done_o        : out std_logic;
        write_done_o        : out std_logic;
        read_done_o         : out std_logic;
        done_o              : out std_logic;
        busy_o              : out std_logic;
        frame_error_o       : out std_logic;
        error_o             : out std_logic;

        -- Readback stream. One pulse per returned pixel word.
        readback_clk_o      : out std_logic;
        readback_valid_o    : out std_logic;
        readback_data_o     : out std_logic_vector(31 downto 0);
        readback_index_o    : out std_logic_vector(18 downto 0);

        -- Debug/status visibility for GAO/ILA.
        camera_line_count_o      : out std_logic_vector(9 downto 0);
        camera_line_byte_count_o : out std_logic_vector(10 downto 0);
        state_dbg_o         : out std_logic_vector(3 downto 0);
        fifo_level_o        : out std_logic_vector(G_FIFO_ADDR_BITS downto 0);
        write_count_o       : out std_logic_vector(18 downto 0);
        read_count_o        : out std_logic_vector(18 downto 0);
        write_crc_o         : out std_logic_vector(31 downto 0);
        read_crc_o          : out std_logic_vector(31 downto 0);
        camera_config_done_o: out std_logic;
        camera_config_pass_o: out std_logic
    );
end entity;

architecture rtl of Camera_HyperRAM_OneFrame is

    --------------------------------------------------------------------------
    -- Gowin clock generators and HyperRAM IP declarations.
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

    --------------------------------------------------------------------------
    -- Frame and HyperRAM geometry.
    --
    -- Each camera RGB565 pixel arrives as two bytes. They are expanded to
    -- one 32-bit 0x00RRGGBB word before entering the FIFO.
    --------------------------------------------------------------------------

    constant C_BYTES_PER_PIXEL       : positive := 2;
    constant C_PIXELS_PER_BURST      : positive := 8;
    constant C_TOTAL_PIXELS          : positive := G_FRAME_WIDTH * G_FRAME_HEIGHT;
    constant C_TOTAL_BURSTS          : positive := C_TOTAL_PIXELS / C_PIXELS_PER_BURST;
    constant C_FIFO_DEPTH            : positive := 2 ** G_FIFO_ADDR_BITS;
    constant C_ADDR_STEP             : unsigned(21 downto 0) := to_unsigned(16, 22);
    constant C_PLL_STABLE_CYCLES     : positive := 48_000; -- 2 ms at 24 MHz
    -- One additional cycle is used to prefetch beat 1 of the next burst.
    -- Reduce the inter-burst idle gap by one so command-to-command spacing
    -- remains exactly G_CMD_INTERVAL_CYCLES.
    constant C_WRITE_GAP_LAST        : natural :=
        G_CMD_INTERVAL_CYCLES - C_PIXELS_PER_BURST - 2;
    constant C_READ_INTERVAL_LAST    : natural := G_CMD_INTERVAL_CYCLES - 2;

    subtype fifo_ptr_t is unsigned(G_FIFO_ADDR_BITS downto 0);
    type fifo_mem_t is array (0 to C_FIFO_DEPTH - 1) of std_logic_vector(31 downto 0);
    signal fifo_mem : fifo_mem_t;

    function bin_to_gray(b : fifo_ptr_t) return fifo_ptr_t is
    begin
        return b xor shift_right(b, 1);
    end function;

    function gray_to_bin(g : fifo_ptr_t) return fifo_ptr_t is
        variable b : fifo_ptr_t := (others => '0');
    begin
        b(b'high) := g(g'high);
        for i in b'high - 1 downto 0 loop
            b(i) := b(i + 1) xor g(i);
        end loop;
        return b;
    end function;

    function crc32_word(
        crc_in  : std_logic_vector(31 downto 0);
        data_in : std_logic_vector(31 downto 0)
    ) return std_logic_vector is
        variable c           : unsigned(31 downto 0) := unsigned(crc_in);
        variable feedback    : std_logic;
        constant C_CRC_POLY  : unsigned(31 downto 0) := x"04C11DB7";
    begin
        -- MSB-first CRC-32, polynomial 0x04C11DB7, no final XOR.
        for i in 31 downto 0 loop
            feedback := c(31) xor data_in(i);
            c := shift_left(c, 1);
            if feedback = '1' then
                c := c xor C_CRC_POLY;
            end if;
        end loop;
        return std_logic_vector(c);
    end function;

    --------------------------------------------------------------------------
    -- Clock and HyperRAM interface signals.
    --------------------------------------------------------------------------

    signal clk24          : std_logic;
    signal clk96          : std_logic;
    signal usr_clk        : std_logic;
    signal pll_locked     : std_logic;
    signal pll_lock_meta  : std_logic := '0';
    signal pll_lock_sync  : std_logic := '0';
    signal pll_stable     : std_logic := '0';
    signal pll_lock_count : natural range 0 to C_PLL_STABLE_CYCLES := 0;
    signal ip_rst_n       : std_logic;
    signal init_calib_i   : std_logic;

    signal cmd_i          : std_logic := '0';
    signal cmd_en_i       : std_logic := '0';
    signal addr_i         : std_logic_vector(21 downto 0) := (others => '0');
    signal wr_data_i      : std_logic_vector(31 downto 0) := (others => '0');
    signal rd_data_i      : std_logic_vector(31 downto 0);
    signal rd_data_valid_i: std_logic;
    signal data_mask_i    : std_logic_vector(3 downto 0) := (others => '0');

    --------------------------------------------------------------------------
    -- Camera byte stream and RGB565 -> RGB888 converter.
    --------------------------------------------------------------------------

    signal cam_clk_i              : std_logic;
    signal cam_byte_data          : std_logic_vector(7 downto 0);
    signal cam_byte_valid         : std_logic;
    signal cam_frame_done         : std_logic;
    signal cam_frame_error        : std_logic;
    signal cam_config_done        : std_logic;
    signal cam_config_pass        : std_logic;
    signal cam_line_count         : std_logic_vector(9 downto 0);
    signal cam_line_byte_count    : std_logic_vector(10 downto 0);

    signal first_rgb565_byte      : std_logic_vector(7 downto 0) := (others => '0');
    signal byte_phase             : std_logic := '0';
    signal fifo_wr_en             : std_logic := '0';
    signal fifo_wr_data           : std_logic_vector(31 downto 0) := (others => '0');

    signal pixel_words_generated  : natural range 0 to C_TOTAL_PIXELS := 0;
    signal frame_done_cam_level   : std_logic := '0';
    signal frame_ok_cam_level     : std_logic := '0';
    signal frame_pack_error_cam   : std_logic := '0';

    --------------------------------------------------------------------------
    -- Asynchronous FIFO pointers and synchronizers.
    --------------------------------------------------------------------------

    signal wr_ptr_bin        : fifo_ptr_t := (others => '0');
    signal wr_ptr_gray       : fifo_ptr_t := (others => '0');
    signal rd_ptr_bin        : fifo_ptr_t := (others => '0');
    signal rd_ptr_gray       : fifo_ptr_t := (others => '0');

    signal rd_gray_w1        : fifo_ptr_t := (others => '0');
    signal rd_gray_w2        : fifo_ptr_t := (others => '0');
    signal wr_gray_r1        : fifo_ptr_t := (others => '0');
    signal wr_gray_r2        : fifo_ptr_t := (others => '0');

    signal fifo_full_reg     : std_logic := '0';
    signal fifo_empty        : std_logic;
    signal fifo_overflow_cam : std_logic := '0';

    signal fifo_rd_en        : std_logic := '0';
    signal fifo_rd_data      : std_logic_vector(31 downto 0) := (others => '0');
    signal fifo_level_rd     : fifo_ptr_t;
    signal wr_ptr_bin_sync   : fifo_ptr_t;

    --------------------------------------------------------------------------
    -- Status CDC into HyperRAM user-clock domain.
    --------------------------------------------------------------------------

    signal frame_done_meta_usr : std_logic := '0';
    signal frame_done_sync_usr : std_logic := '0';
    signal frame_ok_meta_usr   : std_logic := '0';
    signal frame_ok_sync_usr   : std_logic := '0';
    signal frame_err_meta_usr  : std_logic := '0';
    signal frame_err_sync_usr  : std_logic := '0';
    signal fifo_ovf_meta_usr   : std_logic := '0';
    signal fifo_ovf_sync_usr   : std_logic := '0';

    --------------------------------------------------------------------------
    -- HyperRAM controller FSM and counters.
    --------------------------------------------------------------------------

    type state_t is (
        ST_WAIT_INIT,
        ST_WAIT_FRAME,
        ST_W_PREFETCH,
        ST_WRITE_CMD,
        ST_WRITE_DATA,
        ST_WRITE_GAP,
        ST_WAIT_CAPTURE_END,
        ST_WRITE_READ_GAP,
        ST_READ_CMD,
        ST_READ_WAIT,
        ST_READ_VERIFY,
        ST_DONE,
        ST_ERROR
    );

    signal state : state_t := ST_WAIT_INIT;

    signal wr_addr          : unsigned(21 downto 0) := (others => '0');
    signal rd_addr          : unsigned(21 downto 0) := (others => '0');

    signal wr_burst_count   : natural range 0 to C_TOTAL_BURSTS := 0;
    signal wr_beat_count    : natural range 0 to C_PIXELS_PER_BURST := 0;
    signal wr_gap_count     : natural range 0 to C_WRITE_GAP_LAST := 0;
    signal wr_total_count   : natural range 0 to C_TOTAL_PIXELS := 0;

    signal rd_burst_count   : natural range 0 to C_TOTAL_BURSTS := 0;
    signal rd_beat_count    : natural range 0 to C_PIXELS_PER_BURST := 0;
    signal rd_interval_count : natural range 0 to G_CMD_INTERVAL_CYCLES - 1 := 0;
    signal rd_total_count   : natural range 0 to C_TOTAL_PIXELS := 0;

    signal write_read_gap_count : natural range 0 to G_WRITE_READ_GAP_CYCLES - 1 := 0;

    signal write_crc         : std_logic_vector(31 downto 0) := x"FFFFFFFF";
    signal read_crc          : std_logic_vector(31 downto 0) := x"FFFFFFFF";

    signal write_done_reg    : std_logic := '0';
    signal read_done_reg     : std_logic := '0';
    signal test_error_reg    : std_logic := '0';

    signal readback_valid_reg : std_logic := '0';
    signal readback_data_reg  : std_logic_vector(31 downto 0) := (others => '0');
    signal readback_index_reg : std_logic_vector(18 downto 0) := (others => '0');

    signal state_dbg          : std_logic_vector(3 downto 0);

    attribute syn_keep : integer;
    attribute syn_keep of cmd_i : signal is 1;
    attribute syn_keep of cmd_en_i : signal is 1;
    attribute syn_keep of addr_i : signal is 1;
    attribute syn_keep of wr_data_i : signal is 1;
    attribute syn_keep of rd_data_i : signal is 1;
    attribute syn_keep of rd_data_valid_i : signal is 1;
    attribute syn_keep of fifo_level_rd : signal is 1;
    attribute syn_keep of fifo_wr_en : signal is 1;
    attribute syn_keep of fifo_wr_data : signal is 1;
    attribute syn_keep of write_crc : signal is 1;
    attribute syn_keep of read_crc : signal is 1;
    attribute syn_keep of wr_total_count : signal is 1;
    attribute syn_keep of rd_total_count : signal is 1;
    attribute syn_keep of frame_done_sync_usr : signal is 1;
    attribute syn_keep of frame_ok_sync_usr : signal is 1;

begin

    --------------------------------------------------------------------------
    -- PLLs: 8 MHz -> 24 MHz -> 96 MHz; HyperRAM IP supplies usr_clk.
    --------------------------------------------------------------------------

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

    --------------------------------------------------------------------------
    -- Camera interface. The UART trigger starts the I2C configuration.
    -- The camera submodule then emits exactly one configured frame.
    --------------------------------------------------------------------------

    u_camera : camera_interface
        generic map (
            G_FRAME_WIDTH  => G_FRAME_WIDTH,
            G_FRAME_HEIGHT => G_FRAME_HEIGHT
        )
        port map (
            clk24               => clk24,
            clkcam              => cam_clk_i,
            rst_n               => rst_n,
            rst_trigger         => rst_trigger,
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
    camera_config_done_o <= cam_config_done;
    camera_config_pass_o <= cam_config_pass;

    --------------------------------------------------------------------------
    -- RGB565 -> 0x00RRGGBB packer in cam_pclk domain.
    --
    -- RGB565 byte 0: R[4:0] G[5:3]
    -- RGB565 byte 1: G[2:0] B[4:0]
    -- Each two-byte pixel becomes one 32-bit FIFO word.
    --------------------------------------------------------------------------

    process(cam_pclk, rst_n)
        variable r5 : unsigned(4 downto 0);
        variable g6 : unsigned(5 downto 0);
        variable b5 : unsigned(4 downto 0);
        variable r8 : std_logic_vector(7 downto 0);
        variable g8 : std_logic_vector(7 downto 0);
        variable b8 : std_logic_vector(7 downto 0);
    begin
        if rst_n = '0' then
            first_rgb565_byte <= (others => '0');
            byte_phase <= '0';
            fifo_wr_en <= '0';
            fifo_wr_data <= (others => '0');
            pixel_words_generated <= 0;
            frame_done_cam_level <= '0';
            frame_ok_cam_level <= '0';
            frame_pack_error_cam <= '0';

        elsif rising_edge(cam_pclk) then
            fifo_wr_en <= '0';

            if cam_byte_valid = '1' then
                if byte_phase = '0' then
                    first_rgb565_byte <= cam_byte_data;
                    byte_phase <= '1';
                else
                    r5 := unsigned(first_rgb565_byte(7 downto 3));
                    g6 := unsigned(first_rgb565_byte(2 downto 0) &
                                   cam_byte_data(7 downto 5));
                    b5 := unsigned(cam_byte_data(4 downto 0));

                    -- Bit replication expands RGB565 to RGB888.
                    r8 := std_logic_vector(r5 & r5(4 downto 2));
                    g8 := std_logic_vector(g6 & g6(5 downto 4));
                    b8 := std_logic_vector(b5 & b5(4 downto 2));

                    fifo_wr_data <= x"00" & r8 & g8 & b8;
                    fifo_wr_en <= '1';
                    byte_phase <= '0';

                    if pixel_words_generated < C_TOTAL_PIXELS then
                        pixel_words_generated <= pixel_words_generated + 1;
                    else
                        frame_pack_error_cam <= '1';
                    end if;
                end if;
            end if;

            if cam_frame_error = '1' then
                frame_pack_error_cam <= '1';
            end if;

            if cam_frame_done = '1' then
                frame_done_cam_level <= '1';

                if (pixel_words_generated = C_TOTAL_PIXELS) and
                   (byte_phase = '0') and
                   (frame_pack_error_cam = '0') and
                   (cam_frame_error = '0') then
                    frame_ok_cam_level <= '1';
                else
                    frame_pack_error_cam <= '1';
                end if;
            end if;
        end if;
    end process;

    --------------------------------------------------------------------------
    -- Asynchronous FIFO write side (cam_pclk).
    -- Gray-coded pointers cross clock domains; data itself is not synchronized
    -- bit by bit. The dual-clock memory is the CDC data path.
    --------------------------------------------------------------------------

    fifo_write_side : process(cam_pclk, rst_n)
        variable next_bin       : fifo_ptr_t;
        variable next_gray      : fifo_ptr_t;
        variable full_compare   : fifo_ptr_t;
    begin
        if rst_n = '0' then
            wr_ptr_bin <= (others => '0');
            wr_ptr_gray <= (others => '0');
            rd_gray_w1 <= (others => '0');
            rd_gray_w2 <= (others => '0');
            fifo_full_reg <= '0';
            fifo_overflow_cam <= '0';

        elsif rising_edge(cam_pclk) then
            rd_gray_w1 <= rd_ptr_gray;
            rd_gray_w2 <= rd_gray_w1;

            next_bin := wr_ptr_bin;

            if fifo_wr_en = '1' then
                if fifo_full_reg = '0' then
                    fifo_mem(to_integer(wr_ptr_bin(G_FIFO_ADDR_BITS - 1 downto 0)))
                        <= fifo_wr_data;
                    next_bin := wr_ptr_bin + 1;
                else
                    fifo_overflow_cam <= '1';
                end if;
            end if;

            next_gray := bin_to_gray(next_bin);
            wr_ptr_bin <= next_bin;
            wr_ptr_gray <= next_gray;

            -- Standard asynchronous-FIFO full comparison: invert the two
            -- most significant synchronized read-pointer Gray bits.
            full_compare := rd_gray_w2;
            full_compare(G_FIFO_ADDR_BITS downto G_FIFO_ADDR_BITS - 1) :=
                not rd_gray_w2(G_FIFO_ADDR_BITS downto G_FIFO_ADDR_BITS - 1);

            if next_gray = full_compare then
                fifo_full_reg <= '1';
            else
                fifo_full_reg <= '0';
            end if;
        end if;
    end process;

    --------------------------------------------------------------------------
    -- Asynchronous FIFO read side (HyperRAM usr_clk).
    -- Synchronous read register is used for the HyperRAM write-data pipeline.
    --------------------------------------------------------------------------

    fifo_read_side : process(usr_clk, rst_n)
    begin
        if rst_n = '0' then
            rd_ptr_bin <= (others => '0');
            rd_ptr_gray <= (others => '0');
            wr_gray_r1 <= (others => '0');
            wr_gray_r2 <= (others => '0');
            fifo_rd_data <= (others => '0');

        elsif rising_edge(usr_clk) then
            wr_gray_r1 <= wr_ptr_gray;
            wr_gray_r2 <= wr_gray_r1;

            if (fifo_rd_en = '1') and (fifo_empty = '0') then
                fifo_rd_data <=
                    fifo_mem(to_integer(rd_ptr_bin(G_FIFO_ADDR_BITS - 1 downto 0)));
                rd_ptr_bin <= rd_ptr_bin + 1;
                rd_ptr_gray <= bin_to_gray(rd_ptr_bin + 1);
            end if;
        end if;
    end process;

    fifo_empty <= '1' when rd_ptr_gray = wr_gray_r2 else '0';
    wr_ptr_bin_sync <= gray_to_bin(wr_gray_r2);
    fifo_level_rd <= wr_ptr_bin_sync - rd_ptr_bin;

    --------------------------------------------------------------------------
    -- Synchronize sticky camera/FIFO status into usr_clk domain.
    --------------------------------------------------------------------------

    process(usr_clk, rst_n)
    begin
        if rst_n = '0' then
            frame_done_meta_usr <= '0';
            frame_done_sync_usr <= '0';
            frame_ok_meta_usr <= '0';
            frame_ok_sync_usr <= '0';
            frame_err_meta_usr <= '0';
            frame_err_sync_usr <= '0';
            fifo_ovf_meta_usr <= '0';
            fifo_ovf_sync_usr <= '0';

        elsif rising_edge(usr_clk) then
            frame_done_meta_usr <= frame_done_cam_level;
            frame_done_sync_usr <= frame_done_meta_usr;

            frame_ok_meta_usr <= frame_ok_cam_level;
            frame_ok_sync_usr <= frame_ok_meta_usr;

            frame_err_meta_usr <= frame_pack_error_cam or cam_frame_error;
            frame_err_sync_usr <= frame_err_meta_usr;

            fifo_ovf_meta_usr <= fifo_overflow_cam;
            fifo_ovf_sync_usr <= fifo_ovf_meta_usr;
        end if;
    end process;

    --------------------------------------------------------------------------
    -- HyperRAM IP.
    --------------------------------------------------------------------------

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

            wr_data         => wr_data_i,
            rd_data         => rd_data_i,
            rd_data_valid   => rd_data_valid_i,

            addr            => addr_i,
            cmd             => cmd_i,
            cmd_en          => cmd_en_i,

            init_calib      => init_calib_i,
            clk_out         => usr_clk,
            data_mask       => data_mask_i
        );

    init_calib_o <= init_calib_i;

    --------------------------------------------------------------------------
    -- Combinational command/data interface.
    --
    -- In ST_W_PREFETCH, fifo_rd_en fetches the first word into the synchronous
    -- FIFO output register. ST_WRITE_CMD presents that word with the write
    -- command; each following user-clock cycle presents the next word.
    --------------------------------------------------------------------------

    process(
        state, wr_addr, rd_addr, fifo_rd_data, fifo_level_rd, wr_beat_count
    )
    begin
        cmd_i <= '0';
        cmd_en_i <= '0';
        addr_i <= (others => '0');
        wr_data_i <= (others => '0');
        data_mask_i <= (others => '0');
        fifo_rd_en <= '0';

        case state is
            when ST_W_PREFETCH =>
                if fifo_level_rd >= to_unsigned(C_PIXELS_PER_BURST,
                                                fifo_level_rd'length) then
                    fifo_rd_en <= '1';
                end if;

            when ST_WRITE_CMD =>
                cmd_i <= '1';
                cmd_en_i <= '1';
                addr_i <= std_logic_vector(wr_addr);
                wr_data_i <= fifo_rd_data;
                fifo_rd_en <= '1'; -- fetch beat 2 while beat 1 is accepted

            when ST_WRITE_DATA =>
                wr_data_i <= fifo_rd_data;
                if wr_beat_count < C_PIXELS_PER_BURST - 1 then
                    fifo_rd_en <= '1';
                end if;

            when ST_READ_CMD =>
                cmd_i <= '0';
                cmd_en_i <= '1';
                addr_i <= std_logic_vector(rd_addr);

            when others =>
                null;
        end case;
    end process;

    --------------------------------------------------------------------------
    -- Main HyperRAM write/read FSM.
    --------------------------------------------------------------------------

    process(usr_clk, ip_rst_n)
        variable burst_complete   : boolean;
        variable all_words_done   : boolean;
    begin
        if ip_rst_n = '0' then
            state <= ST_WAIT_INIT;

            wr_addr <= (others => '0');
            rd_addr <= (others => '0');
            wr_burst_count <= 0;
            wr_beat_count <= 0;
            wr_gap_count <= 0;
            wr_total_count <= 0;
            rd_burst_count <= 0;
            rd_beat_count <= 0;
            rd_interval_count <= 0;
            rd_total_count <= 0;
            write_read_gap_count <= 0;

            write_crc <= x"FFFFFFFF";
            read_crc <= x"FFFFFFFF";

            write_done_reg <= '0';
            read_done_reg <= '0';
            test_error_reg <= '0';

            readback_valid_reg <= '0';
            readback_data_reg <= (others => '0');
            readback_index_reg <= (others => '0');

        elsif rising_edge(usr_clk) then
            readback_valid_reg <= '0';

            -- Abort immediately on a camera geometry/packing error or FIFO
            -- overflow. Do not write a partial frame and call it successful.
            if (frame_err_sync_usr = '1') or (fifo_ovf_sync_usr = '1') then
                test_error_reg <= '1';
                state <= ST_ERROR;

            else
                case state is

                    when ST_WAIT_INIT =>
                        if init_calib_i = '1' then
                            state <= ST_WAIT_FRAME;
                        end if;

                    when ST_WAIT_FRAME =>
                        if frame_err_sync_usr = '1' then
                            test_error_reg <= '1';
                            state <= ST_ERROR;
                        elsif fifo_level_rd >= to_unsigned(C_PIXELS_PER_BURST,
                                                           fifo_level_rd'length) then
                            state <= ST_W_PREFETCH;
                        end if;

                    when ST_W_PREFETCH =>
                        if fifo_level_rd >= to_unsigned(C_PIXELS_PER_BURST,
                                                        fifo_level_rd'length) then
                            -- fifo_rd_en is asserted combinationally in this
                            -- state, so the first word is loaded at this edge.
                            state <= ST_WRITE_CMD;
                        end if;

                    when ST_WRITE_CMD =>
                        -- First beat accompanies the command.
                        write_crc <= crc32_word(write_crc, fifo_rd_data);
                        wr_total_count <= wr_total_count + 1;
                        wr_burst_count <= wr_burst_count + 1;
                        wr_beat_count <= 1;
                        state <= ST_WRITE_DATA;

                    when ST_WRITE_DATA =>
                        -- Remaining seven beats, one per usr_clk cycle.
                        write_crc <= crc32_word(write_crc, fifo_rd_data);
                        wr_total_count <= wr_total_count + 1;

                        if wr_beat_count = C_PIXELS_PER_BURST - 1 then
                            wr_beat_count <= C_PIXELS_PER_BURST;
                            wr_gap_count <= 0;
                            state <= ST_WRITE_GAP;
                        else
                            wr_beat_count <= wr_beat_count + 1;
                        end if;

                    when ST_WRITE_GAP =>
                        if wr_gap_count = C_WRITE_GAP_LAST then
                            wr_gap_count <= 0;

                            if wr_burst_count = C_TOTAL_BURSTS then
                                state <= ST_WAIT_CAPTURE_END;
                            else
                                wr_addr <= wr_addr + C_ADDR_STEP;
                                state <= ST_W_PREFETCH;
                            end if;
                        else
                            wr_gap_count <= wr_gap_count + 1;
                        end if;

                    when ST_WAIT_CAPTURE_END =>
                        -- The final burst has been sent. Wait until the
                        -- camera confirms exact frame geometry and the FIFO
                        -- read/write pointers show no remaining words.
                        if frame_done_sync_usr = '1' and
                           frame_ok_sync_usr = '1' and
                           wr_total_count = C_TOTAL_PIXELS and
                           fifo_level_rd = to_unsigned(0, fifo_level_rd'length) then
                            write_done_reg <= '1';
                            write_read_gap_count <= 0;
                            state <= ST_WRITE_READ_GAP;
                        end if;

                    when ST_WRITE_READ_GAP =>
                        if write_read_gap_count = G_WRITE_READ_GAP_CYCLES - 1 then
                            write_read_gap_count <= 0;
                            rd_addr <= (others => '0');
                            rd_burst_count <= 0;
                            rd_beat_count <= 0;
                            rd_interval_count <= 0;
                            rd_total_count <= 0;
                            read_crc <= x"FFFFFFFF";
                            state <= ST_READ_CMD;
                        else
                            write_read_gap_count <= write_read_gap_count + 1;
                        end if;

                    when ST_READ_CMD =>
                        if rd_burst_count < C_TOTAL_BURSTS then
                            rd_burst_count <= rd_burst_count + 1;
                            rd_beat_count <= 0;
                            rd_interval_count <= 0;
                            state <= ST_READ_WAIT;
                        else
                            test_error_reg <= '1';
                            state <= ST_ERROR;
                        end if;

                    when ST_READ_WAIT =>
                        if (rd_data_valid_i = '1') and
                           (rd_beat_count < C_PIXELS_PER_BURST) then

                            read_crc <= crc32_word(read_crc, rd_data_i);

                            readback_valid_reg <= '1';
                            readback_data_reg <= rd_data_i;
                            readback_index_reg <=
                                std_logic_vector(to_unsigned(rd_total_count, 19));

                            rd_total_count <= rd_total_count + 1;
                            rd_beat_count <= rd_beat_count + 1;
                        end if;

                        if rd_interval_count < G_CMD_INTERVAL_CYCLES - 1 then
                            rd_interval_count <= rd_interval_count + 1;
                        end if;

                        -- Account for a valid beat arriving on this same edge.
                        burst_complete :=
                            (rd_beat_count = C_PIXELS_PER_BURST) or
                            ((rd_data_valid_i = '1') and
                             (rd_beat_count = C_PIXELS_PER_BURST - 1));

                        all_words_done :=
                            (rd_total_count = C_TOTAL_PIXELS) or
                            ((rd_data_valid_i = '1') and
                             (rd_total_count = C_TOTAL_PIXELS - 1));

                        if (rd_interval_count >= C_READ_INTERVAL_LAST) and
                           burst_complete then

                            if rd_burst_count = C_TOTAL_BURSTS then
                                if all_words_done then
                                    state <= ST_READ_VERIFY;
                                else
                                    test_error_reg <= '1';
                                    state <= ST_ERROR;
                                end if;
                            else
                                rd_addr <= rd_addr + C_ADDR_STEP;
                                state <= ST_READ_CMD;
                            end if;
                        end if;

                    when ST_READ_VERIFY =>
                        -- This state is one clock after the final valid beat,
                        -- so read_crc includes that final word here.
                        if (rd_total_count = C_TOTAL_PIXELS) and
                           (read_crc = write_crc) then
                            read_done_reg <= '1';
                            state <= ST_DONE;
                        else
                            test_error_reg <= '1';
                            state <= ST_ERROR;
                        end if;

                    when ST_DONE =>
                        state <= ST_DONE;

                    when ST_ERROR =>
                        state <= ST_ERROR;

                    when others =>
                        test_error_reg <= '1';
                        state <= ST_ERROR;

                end case;
            end if;
        end if;
    end process;

    --------------------------------------------------------------------------
    -- User-visible status and debug outputs.
    --------------------------------------------------------------------------

    frame_done_o  <= frame_done_sync_usr;
    write_done_o  <= write_done_reg;
    read_done_o   <= read_done_reg;
    done_o        <= '1' when state = ST_DONE else '0';
    busy_o        <= '1' when
                     (state /= ST_WAIT_INIT) and
                     (state /= ST_WAIT_FRAME) and
                     (state /= ST_DONE) and
                     (state /= ST_ERROR)
                     else '0';
    frame_error_o <= frame_err_sync_usr or fifo_ovf_sync_usr;
    error_o       <= test_error_reg;

    readback_clk_o <= usr_clk;
    readback_valid_o <= readback_valid_reg;
    readback_data_o  <= readback_data_reg;
    readback_index_o <= readback_index_reg;

    state_dbg <= std_logic_vector(to_unsigned(state_t'pos(state), 4));
    state_dbg_o <= state_dbg;

    camera_line_count_o <= cam_line_count;
    camera_line_byte_count_o <= cam_line_byte_count;

    fifo_level_o <= std_logic_vector(fifo_level_rd);
    write_count_o <= std_logic_vector(to_unsigned(wr_total_count, 19));
    read_count_o <= std_logic_vector(to_unsigned(rd_total_count, 19));
    write_crc_o <= write_crc;
    read_crc_o <= read_crc;

    --------------------------------------------------------------------------
    -- Static configuration checks.
    --------------------------------------------------------------------------

    assert G_FIFO_ADDR_BITS >= 2
        report "G_FIFO_ADDR_BITS must be at least 2"
        severity failure;

    assert G_FRAME_WIDTH mod C_PIXELS_PER_BURST = 0
        report "Frame width must be divisible by 8 so bursts never cross lines"
        severity failure;

    assert C_TOTAL_PIXELS mod C_PIXELS_PER_BURST = 0
        report "Total pixel count must be divisible by 8"
        severity failure;

    assert G_CMD_INTERVAL_CYCLES > C_PIXELS_PER_BURST + 1
        report "G_CMD_INTERVAL_CYCLES must be greater than 9"
        severity failure;

    assert G_WRITE_READ_GAP_CYCLES > 0
        report "G_WRITE_READ_GAP_CYCLES must be greater than 0"
        severity failure;

    assert C_TOTAL_PIXELS <= 524287
        report "This implementation's debug counters support up to 524287 pixels"
        severity failure;

end architecture rtl;