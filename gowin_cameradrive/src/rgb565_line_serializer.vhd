library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Convert two RGB565 pixels read from one HyperRAM FIFO word into two Gray8
-- samples. Luma uses BT.601 integer coefficients after channel expansion.
entity rgb565_line_serializer is
    generic (
        G_FRAME_WIDTH          : positive := 640;
        G_FRAME_HEIGHT         : positive := 480;
        G_FIFO_TIMEOUT_CYCLES  : positive := 100000
    );
    port (
        uart_clk             : in  std_logic;
        rst_n                : in  std_logic;
        line_ready_i         : in  std_logic;
        line_ack_i           : in  std_logic;
        line_retry_i         : in  std_logic;
        line_consumed_o      : out std_logic;
        frame_stream_done_o  : out std_logic;
        error_o              : out std_logic;
        fifo_rd_en_o         : out std_logic;
        fifo_rd_data_i       : in  std_logic_vector(31 downto 0);
        fifo_rd_valid_i      : in  std_logic;
        fifo_rd_empty_i      : in  std_logic;
        uart_data_o          : out std_logic_vector(7 downto 0);
        uart_valid_o         : out std_logic;
        uart_ready_i         : in  std_logic;
        r_valid_o            : out std_logic;
        g_valid_o            : out std_logic;
        b_valid_o            : out std_logic;
        r_value_o            : out std_logic_vector(7 downto 0);
        g_value_o            : out std_logic_vector(7 downto 0);
        b_value_o            : out std_logic_vector(7 downto 0);
        readback_crc_o       : out std_logic_vector(31 downto 0);
        raw_byte_count_o     : out unsigned(31 downto 0);
        word_count_o         : out unsigned(31 downto 0);
        pixel_count_o        : out unsigned(31 downto 0);
        uart_byte_count_o    : out unsigned(31 downto 0);
        line_count_o         : out unsigned(15 downto 0)
    );
end entity;

architecture rtl of rgb565_line_serializer is
    constant C_WORDS_PER_LINE : positive := G_FRAME_WIDTH / 2;
    type state_t is (
        ST_WAIT_LINE_READY, ST_REQUEST_WORD, ST_WAIT_WORD,
        ST_SEND_PIXEL_0, ST_SEND_PIXEL_1,
        ST_WAIT_LINE_COMMIT, ST_WAIT_LINE_DROP, ST_WAIT_RETRY_DROP,
        ST_FRAME_DONE, ST_ERROR
    );
    signal state : state_t := ST_WAIT_LINE_READY;
    signal line_ready_meta : std_logic := '0';
    signal line_ready_sync : std_logic := '0';
    attribute async_reg : string;
    attribute async_reg of line_ready_meta : signal is "true";
    attribute async_reg of line_ready_sync : signal is "true";

    signal gray_pair_reg : std_logic_vector(15 downto 0) := (others => '0');
    signal words_this_line : natural range 0 to C_WORDS_PER_LINE := 0;
    signal lines_completed : natural range 0 to G_FRAME_HEIGHT := 0;
    signal wait_count : natural range 0 to G_FIFO_TIMEOUT_CYCLES := 0;
    signal line_consumed_reg : std_logic := '0';
    signal frame_done_reg : std_logic := '0';
    signal error_reg : std_logic := '0';
    signal crc_reg : std_logic_vector(31 downto 0) := x"FFFFFFFF";
    signal raw_byte_count_reg : unsigned(31 downto 0) := (others => '0');
    signal word_count_reg : unsigned(31 downto 0) := (others => '0');
    signal pixel_count_reg : unsigned(31 downto 0) := (others => '0');
    signal uart_byte_count_reg : unsigned(31 downto 0) := (others => '0');
    signal crc_checkpoint : std_logic_vector(31 downto 0) := x"FFFFFFFF";
    signal raw_byte_checkpoint : unsigned(31 downto 0) := (others => '0');
    signal word_count_checkpoint : unsigned(31 downto 0) := (others => '0');
    signal pixel_count_checkpoint : unsigned(31 downto 0) := (others => '0');
    signal uart_byte_checkpoint : unsigned(31 downto 0) := (others => '0');

    function rgb565_to_gray(pixel : std_logic_vector(15 downto 0))
        return std_logic_vector is
        variable r5, b5 : integer range 0 to 31;
        variable g6 : integer range 0 to 63;
        variable r8, g8, b8 : integer range 0 to 255;
        variable y : integer range 0 to 255;
    begin
        r5 := to_integer(unsigned(pixel(15 downto 11)));
        g6 := to_integer(unsigned(pixel(10 downto 5)));
        b5 := to_integer(unsigned(pixel(4 downto 0)));
        r8 := (r5 * 255 + 15) / 31;
        g8 := (g6 * 255 + 31) / 63;
        b8 := (b5 * 255 + 15) / 31;
        y := (77 * r8 + 150 * g8 + 29 * b8 + 128) / 256;
        return std_logic_vector(to_unsigned(y, 8));
    end function;

    function crc32_byte(
        crc_in : std_logic_vector(31 downto 0);
        data_in : std_logic_vector(7 downto 0)
    ) return std_logic_vector is
        variable c : unsigned(31 downto 0) := unsigned(crc_in);
        variable feedback : std_logic;
        constant POLY : unsigned(31 downto 0) := x"04C11DB7";
    begin
        for i in 7 downto 0 loop
            feedback := c(31) xor data_in(i);
            c := shift_left(c, 1);
            if feedback = '1' then c := c xor POLY; end if;
        end loop;
        return std_logic_vector(c);
    end function;
begin
    assert (G_FRAME_WIDTH mod 2) = 0
        report "Frame width must be even for two RGB565 pixels per FIFO word"
        severity failure;
    assert G_FIFO_TIMEOUT_CYCLES > 0
        report "G_FIFO_TIMEOUT_CYCLES must be greater than zero"
        severity failure;

    fifo_rd_en_o <= '1' when state = ST_REQUEST_WORD and fifo_rd_empty_i = '0' else '0';
    uart_valid_o <= '1' when state = ST_SEND_PIXEL_0 or state = ST_SEND_PIXEL_1 else '0';
    uart_data_o <= gray_pair_reg(15 downto 8) when state = ST_SEND_PIXEL_0 else
                   gray_pair_reg(7 downto 0) when state = ST_SEND_PIXEL_1 else
                   (others => '0');

    -- Legacy RGB debug ports are retained for top-level compatibility.
    r_valid_o <= '0'; g_valid_o <= '0'; b_valid_o <= '0';
    r_value_o <= (others => '0'); g_value_o <= (others => '0'); b_value_o <= (others => '0');

    line_consumed_o <= line_consumed_reg;
    frame_stream_done_o <= frame_done_reg;
    error_o <= error_reg;
    readback_crc_o <= crc_reg;
    raw_byte_count_o <= raw_byte_count_reg;
    word_count_o <= word_count_reg;
    pixel_count_o <= pixel_count_reg;
    uart_byte_count_o <= uart_byte_count_reg;
    line_count_o <= to_unsigned(lines_completed, line_count_o'length);

    process(uart_clk, rst_n)
        variable crc_v : std_logic_vector(31 downto 0);
        variable gray0, gray1 : std_logic_vector(7 downto 0);
    begin
        if rst_n = '0' then
            state <= ST_WAIT_LINE_READY;
            line_ready_meta <= '0'; line_ready_sync <= '0';
            gray_pair_reg <= (others => '0');
            words_this_line <= 0; lines_completed <= 0; wait_count <= 0;
            line_consumed_reg <= '0'; frame_done_reg <= '0'; error_reg <= '0';
            crc_reg <= x"FFFFFFFF";
            raw_byte_count_reg <= (others => '0');
            word_count_reg <= (others => '0');
            pixel_count_reg <= (others => '0');
            uart_byte_count_reg <= (others => '0');
            crc_checkpoint <= x"FFFFFFFF";
            raw_byte_checkpoint <= (others => '0');
            word_count_checkpoint <= (others => '0');
            pixel_count_checkpoint <= (others => '0');
            uart_byte_checkpoint <= (others => '0');
        elsif rising_edge(uart_clk) then
            line_ready_meta <= line_ready_i;
            line_ready_sync <= line_ready_meta;
            case state is
                when ST_WAIT_LINE_READY =>
                    if line_ready_sync = '1' then
                        words_this_line <= 0; wait_count <= 0;
                        crc_checkpoint <= crc_reg;
                        raw_byte_checkpoint <= raw_byte_count_reg;
                        word_count_checkpoint <= word_count_reg;
                        pixel_count_checkpoint <= pixel_count_reg;
                        uart_byte_checkpoint <= uart_byte_count_reg;
                        state <= ST_REQUEST_WORD;
                    end if;

                when ST_REQUEST_WORD =>
                    if fifo_rd_empty_i = '0' then
                        wait_count <= 0; state <= ST_WAIT_WORD;
                    elsif wait_count = G_FIFO_TIMEOUT_CYCLES - 1 then
                        error_reg <= '1'; state <= ST_ERROR;
                    else
                        wait_count <= wait_count + 1;
                    end if;

                when ST_WAIT_WORD =>
                    if fifo_rd_valid_i = '1' then
                        gray0 := rgb565_to_gray(fifo_rd_data_i(31 downto 16));
                        gray1 := rgb565_to_gray(fifo_rd_data_i(15 downto 0));
                        gray_pair_reg <= gray0 & gray1;
                        words_this_line <= words_this_line + 1;
                        word_count_reg <= word_count_reg + 1;
                        raw_byte_count_reg <= raw_byte_count_reg + 2;
                        crc_v := crc_reg;
                        crc_v := crc32_byte(crc_v, gray0);
                        crc_v := crc32_byte(crc_v, gray1);
                        crc_reg <= crc_v;
                        state <= ST_SEND_PIXEL_0;
                    elsif wait_count = G_FIFO_TIMEOUT_CYCLES - 1 then
                        error_reg <= '1'; state <= ST_ERROR;
                    else
                        wait_count <= wait_count + 1;
                    end if;

                when ST_SEND_PIXEL_0 =>
                    if uart_ready_i = '1' then
                        uart_byte_count_reg <= uart_byte_count_reg + 1;
                        pixel_count_reg <= pixel_count_reg + 1;
                        state <= ST_SEND_PIXEL_1;
                    end if;
                when ST_SEND_PIXEL_1 =>
                    if uart_ready_i = '1' then
                        uart_byte_count_reg <= uart_byte_count_reg + 1;
                        pixel_count_reg <= pixel_count_reg + 1;
                        if words_this_line = C_WORDS_PER_LINE then
                            state <= ST_WAIT_LINE_COMMIT;
                        else
                            state <= ST_REQUEST_WORD;
                        end if;
                    end if;

                when ST_WAIT_LINE_COMMIT =>
                    if line_ack_i = '1' then
                        if lines_completed < G_FRAME_HEIGHT then
                            lines_completed <= lines_completed + 1;
                        end if;
                        if lines_completed = G_FRAME_HEIGHT - 1 then
                            frame_done_reg <= '1';
                        end if;
                        state <= ST_WAIT_LINE_DROP;
                    elsif line_retry_i = '1' then
                        crc_reg <= crc_checkpoint;
                        raw_byte_count_reg <= raw_byte_checkpoint;
                        word_count_reg <= word_count_checkpoint;
                        pixel_count_reg <= pixel_count_checkpoint;
                        uart_byte_count_reg <= uart_byte_checkpoint;
                        words_this_line <= 0;
                        state <= ST_WAIT_RETRY_DROP;
                    end if;

                when ST_WAIT_LINE_DROP =>
                    if line_ready_sync = '0' then
                        if frame_done_reg = '1' then state <= ST_FRAME_DONE;
                        else state <= ST_WAIT_LINE_READY; end if;
                    end if;
                when ST_WAIT_RETRY_DROP =>
                    if line_ready_sync = '0' then state <= ST_WAIT_LINE_READY; end if;
                when ST_FRAME_DONE => state <= ST_FRAME_DONE;
                when ST_ERROR => state <= ST_ERROR;
                when others => error_reg <= '1'; state <= ST_ERROR;
            end case;
        end if;
    end process;
end architecture;
