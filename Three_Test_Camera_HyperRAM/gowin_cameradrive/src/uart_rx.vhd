library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- UART receiver: 8 data bits, no parity, 1 stop bit (8N1).
-- rst_n is active-low. data_valid is a one-clock pulse after a valid byte.
entity uart_rx is
    generic (
        G_CLK_FREQ_HZ : positive := 8_000_000;
        G_BAUD_RATE   : positive := 115_200
    );
    port (
        clk           : in  std_logic;
        rst_n         : in  std_logic;
        serial_rx_i   : in  std_logic;
        data_o        : out std_logic_vector(7 downto 0);
        data_valid_o  : out std_logic;
        framing_error_o : out std_logic
    );
end entity;

architecture rtl of uart_rx is
    constant C_CLKS_PER_BIT : positive :=
        (G_CLK_FREQ_HZ + (G_BAUD_RATE / 2)) / G_BAUD_RATE;
    constant C_HALF_BIT : positive := C_CLKS_PER_BIT / 2;

    type state_t is (IDLE, START_BIT, DATA_BITS, STOP_BIT);
    signal state       : state_t := IDLE;
    signal rx_meta     : std_logic := '1';
    signal rx_sync     : std_logic := '1';
    signal rx_shift    : std_logic_vector(7 downto 0) := (others => '0');
    signal bit_count   : natural range 0 to 7 := 0;
    signal clk_count   : natural range 0 to C_CLKS_PER_BIT - 1 := 0;
    signal data_reg    : std_logic_vector(7 downto 0) := (others => '0');
    signal valid_reg   : std_logic := '0';
    signal framing_reg : std_logic := '0';
begin
    assert C_CLKS_PER_BIT >= 8
        report "UART RX: clock/baud ratio is too small" severity failure;

    data_o          <= data_reg;
    data_valid_o    <= valid_reg;
    framing_error_o <= framing_reg;

    process(clk)
    begin
        if rising_edge(clk) then
            -- Two-flop synchronizer for the asynchronous UART input.
            rx_meta <= serial_rx_i;
            rx_sync <= rx_meta;

            if rst_n = '0' then
                rx_meta     <= '1';
                rx_sync     <= '1';
                rx_shift    <= (others => '0');
                bit_count   <= 0;
                clk_count   <= 0;
                data_reg    <= (others => '0');
                valid_reg   <= '0';
                framing_reg <= '0';
                state       <= IDLE;
            else
                valid_reg   <= '0';
                framing_reg <= '0';

                case state is
                    when IDLE =>
                        clk_count <= 0;
                        bit_count <= 0;
                        if rx_sync = '0' then
                            state <= START_BIT;
                            clk_count <= 0;
                        end if;

                    when START_BIT =>
                        if clk_count = C_HALF_BIT - 1 then
                            clk_count <= 0;
                            if rx_sync = '0' then
                                state <= DATA_BITS;
                                bit_count <= 0;
                            else
                                -- It was a short glitch, not a start bit.
                                state <= IDLE;
                            end if;
                        else
                            clk_count <= clk_count + 1;
                        end if;

                    when DATA_BITS =>
                        if clk_count = C_CLKS_PER_BIT - 1 then
                            clk_count <= 0;
                            rx_shift(bit_count) <= rx_sync; -- LSB first
                            if bit_count = 7 then
                                state <= STOP_BIT;
                            else
                                bit_count <= bit_count + 1;
                            end if;
                        else
                            clk_count <= clk_count + 1;
                        end if;

                    when STOP_BIT =>
                        if clk_count = C_CLKS_PER_BIT - 1 then
                            clk_count <= 0;
                            state <= IDLE;
                            if rx_sync = '1' then
                                data_reg  <= rx_shift;
                                valid_reg <= '1';
                            else
                                framing_reg <= '1';
                            end if;
                        else
                            clk_count <= clk_count + 1;
                        end if;
                end case;
            end if;
        end if;
    end process;
end architecture;
