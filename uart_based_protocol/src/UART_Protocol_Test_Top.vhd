library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Standalone Tang Nano 4K UART protocol test.
-- Board clock: 8 MHz on clk8. UART: 115200 baud, 8N1.
-- The test source emits 256 bytes (00..FF) for every row. Each LINE packet
-- also carries its zero-based 16-bit row index, so the wire sequence begins:
--   row 0: 00 | 00 01 02 ... FE FF
--   row 1: 01 | 00 01 02 ... FE FF
-- where the byte before the payload is the row index in the packet header.
entity UART_Protocol_Test_Top is
    port (
        clk8        : in  std_logic;
        uart_rx_i   : in  std_logic;
        uart_tx_o   : out std_logic;
        led_status  : out std_logic
    );
end entity;

architecture rtl of UART_Protocol_Test_Top is
    constant C_CLK_FREQ_HZ : positive := 8_000_000;
    constant C_BAUD_RATE   : positive := 115_200;
    constant C_TEST_WIDTH  : positive := 256;
    constant C_TEST_HEIGHT : positive := 4;
    constant C_POR_CYCLES  : positive := 80_000; -- 10 ms at 8 MHz

    signal por_count       : natural range 0 to C_POR_CYCLES := 0;
    signal rst_n           : std_logic := '0';

    signal rx_data         : std_logic_vector(7 downto 0);
    signal rx_valid        : std_logic;
    signal rx_framing_err  : std_logic;

    signal tx_data         : std_logic_vector(7 downto 0);
    signal tx_valid        : std_logic;
    signal tx_ready        : std_logic;

    signal line_start      : std_logic;
    signal line_index      : std_logic_vector(15 downto 0);
    signal src_data        : std_logic_vector(7 downto 0);
    signal src_valid       : std_logic := '0';
    signal src_ready       : std_logic;
    signal src_active      : std_logic := '0';
    signal src_x           : natural range 0 to C_TEST_WIDTH - 1 := 0;

    signal transfer_start  : std_logic;
    signal protocol_busy  : std_logic;
    signal protocol_done  : std_logic;
    signal protocol_error : std_logic;
    signal rx_framing_sticky : std_logic := '0';
begin
    -- Power-on reset. Gowin FPGA register initialization is used to start
    -- rst_n low; the reset is released after 10 ms of stable input clock.
    process(clk8)
    begin
        if rising_edge(clk8) then
            if por_count < C_POR_CYCLES then
                por_count <= por_count + 1;
                rst_n <= '0';
            else
                rst_n <= '1';
            end if;
        end if;
    end process;

    u_uart_rx : entity work.uart_rx
        generic map (
            G_CLK_FREQ_HZ => C_CLK_FREQ_HZ,
            G_BAUD_RATE   => C_BAUD_RATE
        )
        port map (
            clk             => clk8,
            rst_n           => rst_n,
            serial_rx_i     => uart_rx_i,
            data_o          => rx_data,
            data_valid_o    => rx_valid,
            framing_error_o => rx_framing_err
        );

    u_uart_tx : entity work.uart_tx
        generic map (
            G_CLK_FREQ_HZ => C_CLK_FREQ_HZ,
            G_BAUD_RATE   => C_BAUD_RATE
        )
        port map (
            clk           => clk8,
            rst_n         => rst_n,
            data_i        => tx_data,
            data_valid_i  => tx_valid,
            data_ready_o  => tx_ready,
            serial_tx_o   => uart_tx_o
        );

    u_protocol : entity work.uart_frame_protocol
        generic map (
            G_FRAME_WIDTH           => C_TEST_WIDTH,
            G_FRAME_HEIGHT          => C_TEST_HEIGHT,
            G_BYTES_PER_PIXEL       => 1,
            G_PIXEL_FORMAT          => x"00", -- 8-bit grayscale test image
            G_ACK_TIMEOUT_CYCLES    => 16_000_000, -- 2 s at 8 MHz
            G_SOURCE_TIMEOUT_CYCLES => 8_000_000,  -- 1 s at 8 MHz
            G_MAX_RETRIES           => 3
        )
        port map (
            clk               => clk8,
            rst_n             => rst_n,
            rx_data_i         => rx_data,
            rx_valid_i        => rx_valid,
            tx_data_o         => tx_data,
            tx_valid_o        => tx_valid,
            tx_ready_i        => tx_ready,
            frame_available_i => '1',
            line_start_o      => line_start,
            line_index_o      => line_index,
            src_data_i        => src_data,
            src_valid_i       => src_valid,
            src_ready_o       => src_ready,
            transfer_start_o  => transfer_start,
            busy_o            => protocol_busy,
            done_o            => protocol_done,
            error_o           => protocol_error
        );

    -- Synthetic grayscale line source. Each row is the same 0..255 ramp.
    -- line_start resets the x counter for both new lines and retransmissions.
    src_valid <= src_active;
    src_data  <= std_logic_vector(to_unsigned(src_x, 8));

    process(clk8)
    begin
        if rising_edge(clk8) then
            if rst_n = '0' then
                src_active <= '0';
                src_x      <= 0;
            elsif transfer_start = '1' then
                src_active <= '0';
                src_x      <= 0;
            elsif line_start = '1' then
                src_active <= '1';
                src_x      <= 0;
            elsif src_active = '1' and src_valid = '1' and src_ready = '1' then
                if src_x = C_TEST_WIDTH - 1 then
                    src_active <= '0';
                    src_x      <= 0;
                else
                    src_x <= src_x + 1;
                end if;
            end if;
        end if;
    end process;

    -- Retain a framing-error indication for troubleshooting. A framing error
    -- drops that UART byte; the protocol then recovers through its ACK timeout.
    process(clk8)
    begin
        if rising_edge(clk8) then
            if rst_n = '0' then
                rx_framing_sticky <= '0';
            elsif rx_framing_err = '1' then
                rx_framing_sticky <= '1';
            end if;
        end if;
    end process;

    -- LED is on while transferring, after success/error, or after any UART
    -- framing error. MATLAB reports the precise transfer result.
    led_status <= protocol_busy or protocol_done or protocol_error or rx_framing_sticky;

end architecture;
