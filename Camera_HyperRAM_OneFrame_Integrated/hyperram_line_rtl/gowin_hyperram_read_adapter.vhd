library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Adapter from the abstract read-command valid/ready protocol used by
-- hyperram_line_reader to the signal-level interface present in the supplied
-- HyperRAM_Memory_Interface_Top component declaration.
--
-- This mirrors the current source's single-cycle cmd_en read-command style
-- and enforces a configurable minimum command spacing. The default 21 cycles
-- comes from the current top-level generic, but MUST be checked against the
-- generated IP/reference design before hardware use.
--
-- rd_data/rd_data_valid are pipelined by one clk so a data-valid beat that
-- coincides with the cmd_en acceptance edge is not lost by the line-reader FSM.
entity gowin_hyperram_read_adapter is
    generic (
        G_ADDR_WIDTH           : positive := 22;
        G_CMD_INTERVAL_CYCLES  : positive := 21
    );
    port (
        clk                    : in  std_logic;
        rst_n                  : in  std_logic;
        enable_i               : in  std_logic;

        rd_cmd_valid_i         : in  std_logic;
        rd_cmd_ready_o         : out std_logic;
        rd_cmd_addr_i          : in  std_logic_vector(G_ADDR_WIDTH - 1 downto 0);

        -- Connect these directly to HyperRAM_Memory_Interface_Top.
        ip_addr_o              : out std_logic_vector(G_ADDR_WIDTH - 1 downto 0);
        ip_cmd_o               : out std_logic;
        ip_cmd_en_o            : out std_logic;
        ip_rd_data_i           : in  std_logic_vector(31 downto 0);
        ip_rd_data_valid_i     : in  std_logic;

        rd_data_o              : out std_logic_vector(31 downto 0);
        rd_data_valid_o        : out std_logic
    );
end entity;

architecture rtl of gowin_hyperram_read_adapter is
    signal cooldown_count     : natural range 0 to G_CMD_INTERVAL_CYCLES - 1 := 0;
    signal slot_ready         : std_logic;
    signal ip_data_reg        : std_logic_vector(31 downto 0) := (others => '0');
    signal ip_valid_reg       : std_logic := '0';
begin
    slot_ready <= '1' when (enable_i = '1') and (cooldown_count = 0) else '0';
    rd_cmd_ready_o <= slot_ready;

    ip_addr_o    <= rd_cmd_addr_i;
    ip_cmd_o     <= '0'; -- read command in the supplied interface convention
    ip_cmd_en_o  <= rd_cmd_valid_i and slot_ready;

    process(clk, rst_n)
    begin
        if rst_n = '0' then
            cooldown_count <= 0;
            ip_data_reg    <= (others => '0');
            ip_valid_reg   <= '0';
        elsif rising_edge(clk) then
            -- One-cycle pipeline aligns responses even if the IP asserts
            -- rd_data_valid in the same cycle as command acceptance.
            ip_data_reg  <= ip_rd_data_i;
            ip_valid_reg <= ip_rd_data_valid_i;

            if (rd_cmd_valid_i = '1') and (slot_ready = '1') then
                cooldown_count <= G_CMD_INTERVAL_CYCLES - 1;
            elsif cooldown_count > 0 then
                cooldown_count <= cooldown_count - 1;
            end if;
        end if;
    end process;

    rd_data_o       <= ip_data_reg;
    rd_data_valid_o <= ip_valid_reg;
end architecture;
