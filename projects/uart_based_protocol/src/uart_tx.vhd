library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- UART transmitter: 8 data bits, no parity, 1 stop bit (8N1).
-- A byte is accepted on a rising clk edge when data_valid_i and data_ready_o
-- are both high. data_ready_o is high only while the transmitter is idle.
entity uart_tx is
    generic (
        G_CLK_FREQ_HZ : positive := 8_000_000;
        G_BAUD_RATE   : positive := 115_200
    );
    port (
        clk           : in  std_logic;
        rst_n         : in  std_logic;
        data_i        : in  std_logic_vector(7 downto 0);
        data_valid_i  : in  std_logic;
        data_ready_o  : out std_logic;
        serial_tx_o   : out std_logic
    );
end entity;

architecture rtl of uart_tx is
    constant C_CLKS_PER_BIT : positive :=
        (G_CLK_FREQ_HZ + (G_BAUD_RATE / 2)) / G_BAUD_RATE;

    type state_t is (IDLE, START_BIT, DATA_BITS, STOP_BIT);
    signal state       : state_t := IDLE;
    signal tx_shift    : std_logic_vector(7 downto 0) := (others => '0');
    signal bit_count   : natural range 0 to 7 := 0;
    signal clk_count   : natural range 0 to C_CLKS_PER_BIT - 1 := 0;
    signal tx_reg      : std_logic := '1';
begin
    assert C_CLKS_PER_BIT >= 8
        report "UART TX: clock/baud ratio is too small" severity failure;

    data_ready_o <= '1' when state = IDLE else '0';
    serial_tx_o  <= tx_reg;

    process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                state     <= IDLE;
                tx_shift  <= (others => '0');
                bit_count <= 0;
                clk_count <= 0;
                tx_reg    <= '1';
            else
                case state is
                    when IDLE =>
                        tx_reg    <= '1';
                        clk_count <= 0;
                        bit_count <= 0;
                        if data_valid_i = '1' then
                            tx_shift <= data_i;
                            tx_reg   <= '0'; -- start bit
                            state    <= START_BIT;
                        end if;

                    when START_BIT =>
                        if clk_count = C_CLKS_PER_BIT - 1 then
                            clk_count <= 0;
                            tx_reg    <= tx_shift(0);
                            bit_count <= 0;
                            state     <= DATA_BITS;
                        else
                            clk_count <= clk_count + 1;
                        end if;

                    when DATA_BITS =>
                        if clk_count = C_CLKS_PER_BIT - 1 then
                            clk_count <= 0;
                            if bit_count = 7 then
                                tx_reg <= '1'; -- stop bit
                                state  <= STOP_BIT;
                            else
                                bit_count <= bit_count + 1;
                                tx_reg <= tx_shift(bit_count + 1);
                            end if;
                        else
                            clk_count <= clk_count + 1;
                        end if;

                    when STOP_BIT =>
                        if clk_count = C_CLKS_PER_BIT - 1 then
                            clk_count <= 0;
                            tx_reg    <= '1';
                            state     <= IDLE;
                        else
                            clk_count <= clk_count + 1;
                        end if;
                end case;
            end if;
        end if;
    end process;
end architecture;
