library ieee;
use ieee.std_logic_1164.all;

-- Transfers a sparse one-cycle event between unrelated clock domains.
-- The source toggles a bit; the destination synchronizes and edge-detects it.
-- Events must be separated enough that the destination can observe each toggle.
entity pulse_toggle_cdc is
    port (
        src_clk      : in  std_logic;
        src_rst_n    : in  std_logic;
        src_pulse_i  : in  std_logic;
        dst_clk      : in  std_logic;
        dst_rst_n    : in  std_logic;
        dst_pulse_o  : out std_logic
    );
end entity;

architecture rtl of pulse_toggle_cdc is
    signal src_toggle : std_logic := '0';
    signal dst_meta   : std_logic := '0';
    signal dst_sync   : std_logic := '0';
    signal dst_last   : std_logic := '0';
    signal dst_pulse  : std_logic := '0';
    attribute async_reg : string;
    attribute async_reg of dst_meta : signal is "true";
    attribute async_reg of dst_sync : signal is "true";
begin
    process(src_clk, src_rst_n)
    begin
        if src_rst_n = '0' then
            src_toggle <= '0';
        elsif rising_edge(src_clk) then
            if src_pulse_i = '1' then
                src_toggle <= not src_toggle;
            end if;
        end if;
    end process;

    process(dst_clk, dst_rst_n)
    begin
        if dst_rst_n = '0' then
            dst_meta  <= '0';
            dst_sync  <= '0';
            dst_last  <= '0';
            dst_pulse <= '0';
        elsif rising_edge(dst_clk) then
            dst_meta  <= src_toggle;
            dst_sync  <= dst_meta;
            dst_last  <= dst_sync;
            dst_pulse <= dst_sync xor dst_last;
        end if;
    end process;

    dst_pulse_o <= dst_pulse;
end architecture;
