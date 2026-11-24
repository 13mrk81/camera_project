library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Test 3 deterministic frame source, clocked exclusively by the PLL 24 MHz clock.
entity test3_synthetic_frame_source is
    generic (
        G_FRAME_WIDTH  : positive := 640;
        G_FRAME_HEIGHT : positive := 480
    );
    port (
        clk24             : in  std_logic;
        rst_n             : in  std_logic;
        start_i           : in  std_logic;
        synthetic_byte_o  : out std_logic_vector(7 downto 0);
        synthetic_valid_o : out std_logic;
        frame_done_o      : out std_logic;
        frame_error_o     : out std_logic
    );
end entity;

architecture rtl of test3_synthetic_frame_source is
    constant C_TOTAL_BYTES : positive := G_FRAME_WIDTH * G_FRAME_HEIGHT * 2;
    signal active_reg       : std_logic := '0';
    signal started_reg      : std_logic := '0';
    signal byte_index       : natural range 0 to C_TOTAL_BYTES - 1 := 0;
    signal byte_reg         : std_logic_vector(7 downto 0) := (others => '0');
    signal valid_reg        : std_logic := '0';
    signal done_reg         : std_logic := '0';

    function pattern_byte(index : natural) return std_logic_vector is
        variable value : unsigned(31 downto 0);
        variable result_byte : unsigned(7 downto 0);
    begin
        value := to_unsigned(index, 32);
        result_byte := value(7 downto 0) xor
                       value(15 downto 8) xor
                       value(23 downto 16) xor
                       value(31 downto 24) xor
                       to_unsigned(16#A5#, 8);
        return std_logic_vector(result_byte);
    end function;
begin
    assert (G_FRAME_WIDTH mod 2) = 0
        report "Test 3 requires an even frame width"
        severity failure;
    assert (C_TOTAL_BYTES mod 4) = 0
        report "Test 3 byte count must be divisible by four"
        severity failure;

    process(clk24, rst_n)
    begin
        if rst_n = '0' then
            active_reg <= '0';
            started_reg <= '0';
            byte_index <= 0;
            byte_reg <= (others => '0');
            valid_reg <= '0';
            done_reg <= '0';
        elsif rising_edge(clk24) then
            valid_reg <= '0';
            done_reg <= '0';

            if (start_i = '1') and (started_reg = '0') then
                active_reg <= '1';
                started_reg <= '1';
                byte_index <= 0;
            elsif active_reg = '1' then
                byte_reg <= pattern_byte(byte_index);
                valid_reg <= '1';

                if byte_index = C_TOTAL_BYTES - 1 then
                    active_reg <= '0';
                    done_reg <= '1';
                else
                    byte_index <= byte_index + 1;
                end if;
            end if;
        end if;
    end process;

    synthetic_byte_o  <= byte_reg;
    synthetic_valid_o <= valid_reg;
    frame_done_o      <= done_reg;
    frame_error_o     <= '0';
end architecture;
