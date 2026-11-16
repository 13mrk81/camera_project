library ieee;
use ieee.std_logic_1164.all;

-- Bundled-data CDC for one sticky source event and its multi-bit snapshot.
-- The source captures src_data_i when src_event_i is first observed high,
-- holds that snapshot, and toggles a request. The destination synchronizes
-- the toggle and then captures the already-stable bus.
-- One transfer per reset is supported; src_event_i is expected to be sticky.
entity stable_bus_event_cdc is
    generic (
        G_WIDTH : positive := 64
    );
    port (
        src_clk      : in  std_logic;
        src_rst_n    : in  std_logic;
        src_event_i  : in  std_logic;
        src_data_i   : in  std_logic_vector(G_WIDTH - 1 downto 0);

        dst_clk      : in  std_logic;
        dst_rst_n    : in  std_logic;
        dst_event_o  : out std_logic;
        dst_data_o   : out std_logic_vector(G_WIDTH - 1 downto 0)
    );
end entity;

architecture rtl of stable_bus_event_cdc is
    signal src_captured  : std_logic := '0';
    signal req_toggle    : std_logic := '0';
    signal src_data_reg  : std_logic_vector(G_WIDTH - 1 downto 0) := (others => '0');

    signal req_meta      : std_logic := '0';
    signal req_sync      : std_logic := '0';
    signal req_seen      : std_logic := '0';
    signal dst_event_reg : std_logic := '0';
    signal dst_data_reg  : std_logic_vector(G_WIDTH - 1 downto 0) := (others => '0');

    attribute async_reg : string;
    attribute async_reg of req_meta : signal is "true";
    attribute async_reg of req_sync : signal is "true";
begin
    process(src_clk, src_rst_n)
    begin
        if src_rst_n = '0' then
            src_captured <= '0';
            req_toggle   <= '0';
            src_data_reg <= (others => '0');
        elsif rising_edge(src_clk) then
            if (src_event_i = '1') and (src_captured = '0') then
                src_data_reg <= src_data_i;
                req_toggle   <= not req_toggle;
                src_captured <= '1';
            end if;
        end if;
    end process;

    process(dst_clk, dst_rst_n)
    begin
        if dst_rst_n = '0' then
            req_meta      <= '0';
            req_sync      <= '0';
            req_seen      <= '0';
            dst_event_reg <= '0';
            dst_data_reg  <= (others => '0');
        elsif rising_edge(dst_clk) then
            req_meta <= req_toggle;
            req_sync <= req_meta;
            if req_sync /= req_seen then
                dst_data_reg  <= src_data_reg;
                req_seen      <= req_sync;
                dst_event_reg <= '1';
            end if;
        end if;
    end process;

    dst_event_o <= dst_event_reg;
    dst_data_o  <= dst_data_reg;
end architecture;
