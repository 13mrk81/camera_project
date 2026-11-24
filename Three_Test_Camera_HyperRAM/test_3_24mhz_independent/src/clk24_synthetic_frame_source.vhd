library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- One-shot deterministic byte source driven only by the independent 24 MHz PLL.
entity clk24_synthetic_frame_source is
    generic (G_TOTAL_BYTES : positive := 614400);
    port (
        clk24         : in  std_logic;
        rst_n         : in  std_logic;
        start_i       : in  std_logic;
        byte_data_o   : out std_logic_vector(7 downto 0);
        byte_valid_o  : out std_logic;
        frame_done_o  : out std_logic;
        frame_error_o : out std_logic
    );
end entity;

architecture rtl of clk24_synthetic_frame_source is
    type state_t is (IDLE, STREAM_BYTES, PULSE_FRAME_DONE);
    signal state          : state_t := IDLE;
    signal byte_index     : natural range 0 to G_TOTAL_BYTES := 0;
    signal byte_data_reg  : std_logic_vector(7 downto 0) := (others => '0');
    signal byte_valid_reg : std_logic := '0';
    signal frame_done_reg : std_logic := '0';

    function pattern_byte(index : natural) return std_logic_vector is
        variable v : unsigned(31 downto 0);
        variable b : unsigned(7 downto 0);
    begin
        v := to_unsigned(index, 32);
        b := v(7 downto 0) xor v(15 downto 8) xor
             v(23 downto 16) xor v(31 downto 24) xor to_unsigned(16#A5#, 8);
        return std_logic_vector(b);
    end function;
begin
    assert (G_TOTAL_BYTES mod 4) = 0
        report "G_TOTAL_BYTES must be divisible by four"
        severity failure;

    process(clk24, rst_n)
    begin
        if rst_n = '0' then
            state <= IDLE;
            byte_index <= 0;
            byte_data_reg <= (others => '0');
            byte_valid_reg <= '0';
            frame_done_reg <= '0';
        elsif rising_edge(clk24) then
            byte_valid_reg <= '0';
            frame_done_reg <= '0';
            case state is
                when IDLE =>
                    if start_i = '1' then
                        byte_index <= 0;
                        state <= STREAM_BYTES;
                    end if;
                when STREAM_BYTES =>
                    byte_data_reg <= pattern_byte(byte_index);
                    byte_valid_reg <= '1';
                    if byte_index = G_TOTAL_BYTES - 1 then
                        state <= PULSE_FRAME_DONE;
                    else
                        byte_index <= byte_index + 1;
                    end if;
                when PULSE_FRAME_DONE =>
                    -- One cycle after the last byte: packer sees final byte first.
                    frame_done_reg <= '1';
                    state <= IDLE;
            end case;
        end if;
    end process;

    byte_data_o <= byte_data_reg;
    byte_valid_o <= byte_valid_reg;
    frame_done_o <= frame_done_reg;
    frame_error_o <= '0';
end architecture;
