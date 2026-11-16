library ieee;
use ieee.std_logic_1164.all;

-- Synchronizes an asynchronous input and emits one pulse on its first
-- observed high-to-low transition after reset. It never rearms before reset.
-- The output pulse is suitable for a downstream module expecting a rising-edge
-- command (for example camera_interface.rst_trigger).
entity falling_edge_one_shot is
    port (
        clk             : in  std_logic;
        rst_n           : in  std_logic;
        async_start_i   : in  std_logic;
        start_pulse_o   : out std_logic;
        armed_o         : out std_logic;
        triggered_o     : out std_logic
    );
end entity;

architecture rtl of falling_edge_one_shot is
    signal sync_meta   : std_logic := '0';
    signal sync_level  : std_logic := '0';
    signal previous   : std_logic := '0';
    signal armed_reg  : std_logic := '0';
    signal triggered_reg : std_logic := '0';
    signal pulse_reg  : std_logic := '0';
    attribute async_reg : string;
    attribute async_reg of sync_meta  : signal is "true";
    attribute async_reg of sync_level : signal is "true";
begin
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            sync_meta      <= '0';
            sync_level     <= '0';
            previous       <= '0';
            armed_reg      <= '0';
            triggered_reg  <= '0';
            pulse_reg      <= '0';
        elsif rising_edge(clk) then
            sync_meta  <= async_start_i;
            sync_level <= sync_meta;
            pulse_reg  <= '0';

            if triggered_reg = '0' then
                if (armed_reg = '0') and (sync_level = '1') then
                    armed_reg <= '1';
                elsif (armed_reg = '1') and
                      (previous = '1') and (sync_level = '0') then
                    pulse_reg     <= '1';
                    triggered_reg <= '1';
                    armed_reg     <= '0';
                end if;
            end if;
            previous <= sync_level;
        end if;
    end process;

    start_pulse_o <= pulse_reg;
    armed_o       <= armed_reg;
    triggered_o   <= triggered_reg;
end architecture;
