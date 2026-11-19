library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Deterministic camera-like byte source for HyperRAM storage-path testing.
-- The output is one RGB565 byte per clk_i cycle during active line periods.
-- Two consecutive bytes form one pixel: MSB first, then LSB.
--
-- Default timing assumes a 24 MHz byte clock, 1280 active bytes/line,
-- 106 blank cycles/line, and 155232 vertical blank cycles:
--   480 * (1280 + 106) + 155232 = 820512 clocks.
-- At 24 MHz this is about 29.25 frames/s, based on GC0308 default Hb=0x6A
-- and Vb=0x70 values. Verify actual PCLK/blanking on the configured sensor.
-- These blanking values are explicit generics and should be replaced by
-- measured camera timing if exact sensor cadence is required.
entity storage_test_pattern_generator is
    generic (
        G_FRAME_WIDTH          : positive := 640;
        G_FRAME_HEIGHT         : positive := 480;
        G_LINE_BLANK_CYCLES    : positive := 306;
        G_FRAME_BLANK_CYCLES   : positive := 31720
    );
    port (
        clk_i              : in  std_logic;
        rst_n_i            : in  std_logic;
        start_i            : in  std_logic;

        byte_data_o        : out std_logic_vector(7 downto 0);
        byte_valid_o       : out std_logic;
        frame_done_o       : out std_logic;
        busy_o             : out std_logic;
        error_o            : out std_logic;

        byte_count_o       : out unsigned(31 downto 0);
        line_count_o       : out unsigned(15 downto 0)
    );
end entity;

architecture rtl of storage_test_pattern_generator is
    constant C_BYTES_PER_PIXEL : positive := 2;
    constant C_BYTES_PER_LINE  : positive := G_FRAME_WIDTH * C_BYTES_PER_PIXEL;
    constant C_TOTAL_BYTES     : positive := G_FRAME_WIDTH * G_FRAME_HEIGHT *
                                             C_BYTES_PER_PIXEL;

    type state_t is (ST_IDLE, ST_ACTIVE_LINE, ST_LINE_BLANK,
                     ST_FRAME_BLANK, ST_DONE, ST_ERROR);
    signal state : state_t := ST_IDLE;

    signal line_index       : natural range 0 to G_FRAME_HEIGHT - 1 := 0;
    signal line_byte_index  : natural range 0 to C_BYTES_PER_LINE - 1 := 0;
    signal line_blank_count : natural range 0 to G_LINE_BLANK_CYCLES - 1 := 0;
    signal frame_blank_count: natural range 0 to G_FRAME_BLANK_CYCLES - 1 := 0;
    signal byte_count       : unsigned(31 downto 0) := (others => '0');

    signal byte_data_reg    : std_logic_vector(7 downto 0) := (others => '0');
    signal byte_valid_reg   : std_logic := '0';
    signal frame_done_reg   : std_logic := '0';
    signal error_reg        : std_logic := '0';

    function rgb565_pattern(x : natural; y : natural)
        return std_logic_vector is
        variable value : natural;
    begin
        -- Spatially varying, deterministic 16-bit pattern.
        -- MATLAB can reproduce this exact expression using uint64 arithmetic.
        value := (x * 251) + (y * 911) + (x * y * 13) + 16#A65C#;
        return std_logic_vector(to_unsigned(value mod 65536, 16));
    end function;

begin
    assert (G_FRAME_WIDTH mod 2) = 0
        report "Storage test requires an even frame width" severity failure;
    assert G_FRAME_WIDTH <= 65535 and G_FRAME_HEIGHT <= 65535
        report "Frame geometry must fit the exported counters" severity failure;
    assert C_TOTAL_BYTES <= 2_147_483_647
        report "Frame byte count exceeds supported natural range" severity failure;

    byte_data_o  <= byte_data_reg;
    byte_valid_o <= byte_valid_reg;
    frame_done_o <= frame_done_reg;
    busy_o       <= '1' when (state = ST_ACTIVE_LINE or
                              state = ST_LINE_BLANK or
                              state = ST_FRAME_BLANK) else '0';
    error_o      <= error_reg;
    byte_count_o <= byte_count;
    line_count_o <= to_unsigned(line_index, line_count_o'length);

    process(clk_i, rst_n_i)
        variable pixel_x : natural;
        variable pixel_y : natural;
        variable pixel   : std_logic_vector(15 downto 0);
    begin
        if rst_n_i = '0' then
            state              <= ST_IDLE;
            line_index         <= 0;
            line_byte_index    <= 0;
            line_blank_count   <= 0;
            frame_blank_count  <= 0;
            byte_count         <= (others => '0');
            byte_data_reg      <= (others => '0');
            byte_valid_reg     <= '0';
            frame_done_reg     <= '0';
            error_reg          <= '0';

        elsif rising_edge(clk_i) then
            byte_valid_reg <= '0';
            frame_done_reg <= '0';

            case state is
                when ST_IDLE =>
                    if start_i = '1' then
                        line_index        <= 0;
                        line_byte_index   <= 0;
                        line_blank_count  <= 0;
                        frame_blank_count <= 0;
                        byte_count        <= (others => '0');
                        error_reg         <= '0';
                        state             <= ST_ACTIVE_LINE;
                    end if;

                when ST_ACTIVE_LINE =>
                    pixel_x := line_byte_index / C_BYTES_PER_PIXEL;
                    pixel_y := line_index;
                    pixel := rgb565_pattern(pixel_x, pixel_y);

                    if (line_byte_index mod C_BYTES_PER_PIXEL) = 0 then
                        byte_data_reg <= pixel(15 downto 8);
                    else
                        byte_data_reg <= pixel(7 downto 0);
                    end if;
                    byte_valid_reg <= '1';
                    byte_count <= byte_count + 1;

                    if line_byte_index = C_BYTES_PER_LINE - 1 then
                        line_blank_count <= 0;
                        state <= ST_LINE_BLANK;
                    else
                        line_byte_index <= line_byte_index + 1;
                    end if;

                when ST_LINE_BLANK =>
                    if line_blank_count = G_LINE_BLANK_CYCLES - 1 then
                        line_blank_count <= 0;
                        line_byte_index <= 0;

                        if line_index = G_FRAME_HEIGHT - 1 then
                            frame_blank_count <= 0;
                            state <= ST_FRAME_BLANK;
                        else
                            line_index <= line_index + 1;
                            state <= ST_ACTIVE_LINE;
                        end if;
                    else
                        line_blank_count <= line_blank_count + 1;
                    end if;

                when ST_FRAME_BLANK =>
                    if frame_blank_count = G_FRAME_BLANK_CYCLES - 1 then
                        frame_done_reg <= '1';
                        state <= ST_DONE;
                    else
                        frame_blank_count <= frame_blank_count + 1;
                    end if;

                when ST_DONE =>
                    state <= ST_DONE;

                when ST_ERROR =>
                    state <= ST_ERROR;

                when others =>
                    error_reg <= '1';
                    state <= ST_ERROR;
            end case;
        end if;
    end process;
end architecture;
