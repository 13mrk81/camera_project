library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- GC0308 DVP RGB565 byte-order contract:
--   The sensor drives an 8-bit D[7:0] bus and clocks the RGB565 MSB byte first.
--   PCLK sample N     = pixel[15:8] = R[4:0] & G[5:3]
--   PCLK sample N + 1 = pixel[7:0]  = G[2:0] & B[4:0]
-- This is RGB565 big-endian byte order (V4L2 RGB565X / RGB565_BE).
--
-- Two consecutive pixels are packed into one 32-bit word:
--   word[31:16] = first/left pixel  = {first_byte, second_byte}
--   word[15:0]  = second/right pixel = {third_byte, fourth_byte}
--
-- This module deliberately preserves the sensor byte stream. It performs no
-- channel swap, bit reversal, or RGB-to-luma conversion.
--
-- CRC convention: CRC-32/04C11DB7, MSB-first, init FFFFFFFF, no final XOR.
entity rgb565_frame_packer is
    generic (
        G_FRAME_WIDTH  : positive := 640;
        G_FRAME_HEIGHT : positive := 480
    );
    port (
        cam_pclk          : in  std_logic;
        rst_n             : in  std_logic;
        cam_byte_i        : in  std_logic_vector(7 downto 0);
        cam_byte_valid_i  : in  std_logic;
        cam_frame_done_i  : in  std_logic;
        cam_frame_error_i : in  std_logic;

        packed_word_o     : out std_logic_vector(31 downto 0);
        packed_valid_o    : out std_logic;
        capture_done_o    : out std_logic;
        capture_error_o   : out std_logic;
        capture_crc_o     : out std_logic_vector(31 downto 0);
        byte_count_o      : out unsigned(31 downto 0);
        word_count_o      : out unsigned(31 downto 0)
    );
end entity;

architecture rtl of rgb565_frame_packer is
    constant C_TOTAL_BYTES : natural := G_FRAME_WIDTH * G_FRAME_HEIGHT * 2;
    constant C_TOTAL_WORDS : natural := C_TOTAL_BYTES / 4;

    -- Explicit phases make the sensor's MSB-first byte order unambiguous.
    type byte_phase_t is (
        PIXEL0_MSB,
        PIXEL0_LSB,
        PIXEL1_MSB,
        PIXEL1_LSB
    );

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

    signal pixel0_msb_reg   : std_logic_vector(7 downto 0) := (others => '0');
    signal pixel0_reg       : std_logic_vector(15 downto 0) := (others => '0');
    signal pixel1_msb_reg   : std_logic_vector(7 downto 0) := (others => '0');
    signal phase_reg        : byte_phase_t := PIXEL0_MSB;
    signal packed_word_reg  : std_logic_vector(31 downto 0) := (others => '0');
    signal packed_valid_reg : std_logic := '0';
    signal capture_done_reg : std_logic := '0';
    signal capture_error_reg : std_logic := '0';
    signal crc_reg          : std_logic_vector(31 downto 0) := x"FFFFFFFF";
    signal byte_count_reg   : unsigned(31 downto 0) := (others => '0');
    signal word_count_reg   : unsigned(31 downto 0) := (others => '0');
begin
    assert (G_FRAME_WIDTH mod 2) = 0
        report "RGB565 frame width must be even"
        severity failure;
    assert (C_TOTAL_BYTES mod 4) = 0
        report "Total RGB565 byte count must be divisible by four"
        severity failure;

    process(cam_pclk, rst_n)
        variable phase_v : byte_phase_t;
        variable bytes_v : unsigned(31 downto 0);
        variable words_v : unsigned(31 downto 0);
        variable crc_v   : std_logic_vector(31 downto 0);
    begin
        if rst_n = '0' then
            pixel0_msb_reg    <= (others => '0');
            pixel0_reg        <= (others => '0');
            pixel1_msb_reg    <= (others => '0');
            phase_reg         <= PIXEL0_MSB;
            packed_word_reg   <= (others => '0');
            packed_valid_reg  <= '0';
            capture_done_reg  <= '0';
            capture_error_reg <= '0';
            crc_reg           <= x"FFFFFFFF";
            byte_count_reg    <= (others => '0');
            word_count_reg    <= (others => '0');
        elsif rising_edge(cam_pclk) then
            packed_valid_reg <= '0';
            phase_v := phase_reg;
            bytes_v := byte_count_reg;
            words_v := word_count_reg;
            crc_v   := crc_reg;

            if cam_frame_error_i = '1' then
                capture_error_reg <= '1';
            end if;

            if cam_byte_valid_i = '1' then
                if capture_done_reg = '1' then
                    capture_error_reg <= '1';
                elsif bytes_v >= to_unsigned(C_TOTAL_BYTES, 32) then
                    capture_error_reg <= '1';
                else
                    crc_v := crc32_byte(crc_v, cam_byte_i);
                    bytes_v := bytes_v + 1;

                    case phase_v is
                        when PIXEL0_MSB =>
                            -- First DVP byte is RGB565[15:8].
                            pixel0_msb_reg <= cam_byte_i;
                            phase_v := PIXEL0_LSB;

                        when PIXEL0_LSB =>
                            -- Second DVP byte completes the first pixel.
                            pixel0_reg <= pixel0_msb_reg & cam_byte_i;
                            phase_v := PIXEL1_MSB;

                        when PIXEL1_MSB =>
                            -- Third DVP byte is the next pixel's [15:8].
                            pixel1_msb_reg <= cam_byte_i;
                            phase_v := PIXEL1_LSB;

                        when PIXEL1_LSB =>
                            -- Fourth byte completes pixel 1. Preserve pixel
                            -- order in the word: earlier pixel in [31:16].
                            packed_word_reg  <= pixel0_reg &
                                                pixel1_msb_reg &
                                                cam_byte_i;
                            packed_valid_reg <= '1';
                            phase_v := PIXEL0_MSB;
                            words_v := words_v + 1;
                    end case;
                end if;
            end if;

            byte_count_reg <= bytes_v;
            word_count_reg <= words_v;
            crc_reg        <= crc_v;
            phase_reg      <= phase_v;

            if cam_frame_done_i = '1' and capture_done_reg = '0' then
                capture_done_reg <= '1';
                if (bytes_v /= to_unsigned(C_TOTAL_BYTES, 32)) or
                   (words_v /= to_unsigned(C_TOTAL_WORDS, 32)) or
                   (phase_v /= PIXEL0_MSB) or
                   (cam_frame_error_i = '1') then
                    capture_error_reg <= '1';
                end if;
            end if;
        end if;
    end process;

    packed_word_o   <= packed_word_reg;
    packed_valid_o  <= packed_valid_reg;
    capture_done_o  <= capture_done_reg;
    capture_error_o <= capture_error_reg;
    capture_crc_o   <= crc_reg;
    byte_count_o    <= byte_count_reg;
    word_count_o    <= word_count_reg;
end architecture;
