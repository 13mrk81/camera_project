library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Free-running one-frame synthetic byte source clocked only by the internal
-- 24 MHz FPGA clock. A start pulse launches exactly G_TOTAL_BYTES bytes.
entity clk24_synthetic_frame_source is
    generic (
        G_TOTAL_BYTES : positive := 614400
    );
    port (
        clk           : in  std_logic;
        rst_n         : in  std_logic;
        start_i       : in  std_logic;
        data_o        : out std_logic_vector(7 downto 0);
        valid_o       : out std_logic;
        frame_done_o  : out std_logic;
        frame_error_o : out std_logic;
        busy_o        : out std_logic
    );
end entity;

architecture rtl of clk24_synthetic_frame_source is
    signal busy_reg   : std_logic := '0';
    signal done_reg   : std_logic := '0';
    signal error_reg  : std_logic := '0';
    signal byte_index : unsigned(31 downto 0) := (others => '0');

    function pattern_byte(index : unsigned(31 downto 0)) return std_logic_vector is
        variable value : unsigned(7 downto 0);
    begin
        value := index(7 downto 0) xor
                 index(15 downto 8) xor
                 index(23 downto 16) xor
                 index(31 downto 24) xor
                 to_unsigned(16#A5#, 8);
        return std_logic_vector(value);
    end function;
begin
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            busy_reg   <= '0';
            done_reg   <= '0';
            error_reg  <= '0';
            byte_index <= (others => '0');
        elsif rising_edge(clk) then
            done_reg <= '0';

            if start_i = '1' then
                if busy_reg = '1' then
                    error_reg <= '1';
                else
                    byte_index <= (others => '0');
                    busy_reg   <= '1';
                    error_reg  <= '0';
                end if;
            elsif busy_reg = '1' then
                if byte_index = to_unsigned(G_TOTAL_BYTES - 1, byte_index'length) then
                    busy_reg <= '0';
                    done_reg <= '1';
                else
                    byte_index <= byte_index + 1;
                end if;
            end if;
        end if;
    end process;

    data_o        <= pattern_byte(byte_index) when busy_reg = '1' else (others => '0');
    valid_o       <= busy_reg;
    frame_done_o  <= done_reg;
    frame_error_o <= error_reg;
    busy_o        <= busy_reg;
end architecture;
