library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Final one-shot consistency check. All inputs MUST already be synchronous
-- to clk. Use stable_bus_event_cdc (or an equivalent handshake) for the
-- camera-domain and UART-domain multi-bit snapshots before this block.
entity frame_integrity_checker is
    generic (
        G_FRAME_WIDTH  : positive := 640;
        G_FRAME_HEIGHT : positive := 480
    );
    port (
        clk                    : in  std_logic;
        rst_n                  : in  std_logic;
        capture_done_i         : in  std_logic;
        write_done_i           : in  std_logic;
        stream_done_i          : in  std_logic;
        uart_idle_i            : in  std_logic;
        capture_error_i        : in  std_logic;
        write_error_i          : in  std_logic;
        stream_error_i         : in  std_logic;
        capture_crc_i          : in  std_logic_vector(31 downto 0);
        write_crc_i            : in  std_logic_vector(31 downto 0);
        readback_crc_i         : in  std_logic_vector(31 downto 0);
        capture_byte_count_i   : in  unsigned(31 downto 0);
        write_word_count_i     : in  unsigned(31 downto 0);
        readback_raw_bytes_i   : in  unsigned(31 downto 0);
        readback_word_count_i  : in  unsigned(31 downto 0);
        pixel_count_i          : in  unsigned(31 downto 0);
        uart_byte_count_i      : in  unsigned(31 downto 0);
        line_count_i           : in  unsigned(15 downto 0);
        system_ok_o            : out std_logic;
        integrity_done_o       : out std_logic;
        error_o                : out std_logic
    );
end entity;

architecture rtl of frame_integrity_checker is
    constant C_EXPECTED_PIXELS : natural := G_FRAME_WIDTH * G_FRAME_HEIGHT;
    constant C_EXPECTED_RAW_BYTES : natural := C_EXPECTED_PIXELS * 2;
    constant C_EXPECTED_WORDS : natural := C_EXPECTED_RAW_BYTES / 4;
    -- UART transports the original RGB565 stream: exactly two bytes per pixel.
    constant C_EXPECTED_UART_BYTES : natural := C_EXPECTED_RAW_BYTES;

    signal system_ok_reg      : std_logic := '0';
    signal integrity_done_reg : std_logic := '0';
    signal error_reg          : std_logic := '0';
begin
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            system_ok_reg      <= '0';
            integrity_done_reg <= '0';
            error_reg          <= '0';
        elsif rising_edge(clk) then
            if (capture_error_i = '1') or (write_error_i = '1') or
               (stream_error_i = '1') then
                error_reg <= '1';
            end if;

            if (integrity_done_reg = '0') and
               (capture_done_i = '1') and
               (write_done_i = '1') and
               (stream_done_i = '1') and
               (uart_idle_i = '1') then
                integrity_done_reg <= '1';
                if (error_reg = '0') and
                   (capture_error_i = '0') and
                   (write_error_i = '0') and
                   (stream_error_i = '0') and
                   (capture_crc_i = write_crc_i) and
                   (capture_crc_i = readback_crc_i) and
                   (capture_byte_count_i = to_unsigned(C_EXPECTED_RAW_BYTES, 32)) and
                   (write_word_count_i = to_unsigned(C_EXPECTED_WORDS, 32)) and
                   (readback_raw_bytes_i = to_unsigned(C_EXPECTED_RAW_BYTES, 32)) and
                   (readback_word_count_i = to_unsigned(C_EXPECTED_WORDS, 32)) and
                   (pixel_count_i = to_unsigned(C_EXPECTED_PIXELS, 32)) and
                   (uart_byte_count_i = to_unsigned(C_EXPECTED_UART_BYTES, 32)) and
                   (line_count_i = to_unsigned(G_FRAME_HEIGHT, 16)) then
                    system_ok_reg <= '1';
                else
                    error_reg <= '1';
                end if;
            end if;
        end if;
    end process;

    system_ok_o      <= system_ok_reg;
    integrity_done_o <= integrity_done_reg;
    error_o          <= error_reg;
end architecture;
