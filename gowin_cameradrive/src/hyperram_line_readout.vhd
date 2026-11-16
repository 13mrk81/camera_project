library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Integration wrapper for the readout half of the architecture:
-- HyperRAM read-command adapter -> line reader -> FIFO #2 -> RGB serializer.
--
-- mem_clk is the HyperRAM user clock (usr_clk in the original design).
-- uart_clk may equal mem_clk for the first implementation; if not, the FIFO
-- and line_ready/line_consumed CDC paths are handled explicitly.
--
-- This wrapper deliberately does NOT directly drive the generated Gowin
-- HyperRAM IP pins. Its abstract valid/ready read-command interface must be
-- connected through an adapter verified against the actual IP documentation.
entity hyperram_line_readout is
    generic (
        G_FRAME_WIDTH          : positive := 640;
        G_FRAME_HEIGHT         : positive := 480;
        G_ADDR_WIDTH : positive := 22;
        G_BASE_ADDR  : std_logic_vector(21 downto 0) := (others => '0');
        G_BURST_WORDS          : positive := 8;
        G_BURST_ADDR_STRIDE    : positive := 16;
        G_FIFO_ADDR_BITS       : positive := 9;
        G_READ_TIMEOUT_CYCLES  : positive := 100000
    );
    port (
        mem_clk                : in  std_logic;
        uart_clk               : in  std_logic;
        rst_n                  : in  std_logic;
        frame_written_i        : in  std_logic;
        line_ack_i             : in  std_logic;
        line_retry_i           : in  std_logic;

        -- Connect these to a verified HyperRAM read adapter.
        mem_rd_cmd_valid_o     : out std_logic;
        mem_rd_cmd_ready_i     : in  std_logic;
        mem_rd_addr_o          : out std_logic_vector(G_ADDR_WIDTH - 1 downto 0);
        mem_rd_data_i          : in  std_logic_vector(31 downto 0);
        mem_rd_data_valid_i    : in  std_logic;

        -- UART transmitter byte channel.
        uart_tx_data_o         : out std_logic_vector(7 downto 0);
        uart_tx_valid_o        : out std_logic;
        uart_tx_ready_i        : in  std_logic;
        uart_r_valid_o         : out std_logic;
        uart_g_valid_o         : out std_logic;
        uart_b_valid_o         : out std_logic;
        rgb_r_o                : out std_logic_vector(7 downto 0);
        rgb_g_o                : out std_logic_vector(7 downto 0);
        rgb_b_o                : out std_logic_vector(7 downto 0);

        -- Debug/status outputs.
        line_read_req_o        : out std_logic;
        line_ready_o           : out std_logic;
        line_consumed_o        : out std_logic;
        line_complete_o        : out std_logic;
        frame_stream_done_o    : out std_logic;
        serializer_done_o      : out std_logic;
        reader_error_o         : out std_logic;
        serializer_error_o     : out std_logic;
        line_index_o           : out unsigned(15 downto 0);
        line_word_count_o      : out unsigned(15 downto 0);
        fifo_write_level_o     : out unsigned(G_FIFO_ADDR_BITS downto 0);
        readback_crc_o         : out std_logic_vector(31 downto 0);
        raw_byte_count_o       : out unsigned(31 downto 0);
        read_word_count_o      : out unsigned(31 downto 0);
        pixel_count_o          : out unsigned(31 downto 0);
        uart_byte_count_o      : out unsigned(31 downto 0);
        lines_sent_o           : out unsigned(15 downto 0)
    );
end entity;

architecture rtl of hyperram_line_readout is
    signal fifo_wr_en       : std_logic;
    signal fifo_wr_data     : std_logic_vector(31 downto 0);
    signal fifo_full        : std_logic;
    signal fifo_wr_level    : unsigned(G_FIFO_ADDR_BITS downto 0);
    signal fifo_rd_en       : std_logic;
    signal fifo_rd_data     : std_logic_vector(31 downto 0);
    signal fifo_rd_valid    : std_logic;
    signal fifo_rd_empty    : std_logic;
    signal line_consumed    : std_logic;
    signal line_ready      : std_logic;
    signal reader_error    : std_logic;
    signal serializer_error: std_logic;
    signal stream_done     : std_logic;
    signal serializer_done : std_logic;
begin
    u_output_fifo : entity work.async_fifo_32
        generic map (
            G_ADDR_BITS => G_FIFO_ADDR_BITS
        )
        port map (
            rst_n      => rst_n,
            wr_clk     => mem_clk,
            wr_en_i    => fifo_wr_en,
            wr_data_i  => fifo_wr_data,
            wr_full_o  => fifo_full,
            wr_level_o => fifo_wr_level,
            rd_clk     => uart_clk,
            rd_en_i    => fifo_rd_en,
            rd_data_o  => fifo_rd_data,
            rd_valid_o => fifo_rd_valid,
            rd_empty_o => fifo_rd_empty,
            rd_level_o => open
        );

    u_line_reader : entity work.hyperram_line_reader
        generic map (
            G_FRAME_WIDTH         => G_FRAME_WIDTH,
            G_FRAME_HEIGHT        => G_FRAME_HEIGHT,
            G_ADDR_WIDTH          => G_ADDR_WIDTH,
            G_BASE_ADDR           => G_BASE_ADDR,
            G_BURST_WORDS         => G_BURST_WORDS,
            G_BURST_ADDR_STRIDE   => G_BURST_ADDR_STRIDE,
            G_FIFO_ADDR_BITS      => G_FIFO_ADDR_BITS,
            G_READ_TIMEOUT_CYCLES => G_READ_TIMEOUT_CYCLES
        )
        port map (
            clk                 => mem_clk,
            rst_n               => rst_n,
            frame_written_i     => frame_written_i,
            rd_cmd_valid_o      => mem_rd_cmd_valid_o,
            rd_cmd_ready_i      => mem_rd_cmd_ready_i,
            rd_cmd_addr_o       => mem_rd_addr_o,
            rd_data_i           => mem_rd_data_i,
            rd_data_valid_i     => mem_rd_data_valid_i,
            fifo_wr_en_o        => fifo_wr_en,
            fifo_wr_data_o      => fifo_wr_data,
            fifo_wr_full_i      => fifo_full,
            fifo_wr_level_i     => fifo_wr_level,
            line_ack_i          => line_ack_i,
            line_retry_i        => line_retry_i,
            line_read_req_o     => line_read_req_o,
            line_ready_o        => line_ready,
            line_complete_o     => line_complete_o,
            frame_stream_done_o => stream_done,
            error_o             => reader_error,
            line_index_o        => line_index_o,
            line_word_count_o   => line_word_count_o,
            burst_index_o       => open
        );

    u_serializer : entity work.rgb565_line_serializer
        generic map (
            G_FRAME_WIDTH         => G_FRAME_WIDTH,
            G_FRAME_HEIGHT        => G_FRAME_HEIGHT,
            G_FIFO_TIMEOUT_CYCLES => G_READ_TIMEOUT_CYCLES
        )
        port map (
            uart_clk            => uart_clk,
            rst_n               => rst_n,
            line_ready_i        => line_ready,
            line_ack_i          => line_ack_i,
            line_retry_i        => line_retry_i,
            line_consumed_o     => line_consumed,
            frame_stream_done_o => serializer_done,
            error_o             => serializer_error,
            fifo_rd_en_o        => fifo_rd_en,
            fifo_rd_data_i      => fifo_rd_data,
            fifo_rd_valid_i     => fifo_rd_valid,
            fifo_rd_empty_i     => fifo_rd_empty,
            uart_data_o         => uart_tx_data_o,
            uart_valid_o        => uart_tx_valid_o,
            uart_ready_i        => uart_tx_ready_i,
            r_valid_o           => uart_r_valid_o,
            g_valid_o           => uart_g_valid_o,
            b_valid_o           => uart_b_valid_o,
            r_value_o           => rgb_r_o,
            g_value_o           => rgb_g_o,
            b_value_o           => rgb_b_o,
            readback_crc_o      => readback_crc_o,
            raw_byte_count_o    => raw_byte_count_o,
            word_count_o        => read_word_count_o,
            pixel_count_o       => pixel_count_o,
            uart_byte_count_o   => uart_byte_count_o,
            line_count_o        => lines_sent_o
        );

    line_ready_o        <= line_ready;
    line_consumed_o     <= line_consumed;
    frame_stream_done_o <= stream_done;
    serializer_done_o   <= serializer_done;
    reader_error_o      <= reader_error;
    serializer_error_o  <= serializer_error;
    fifo_write_level_o  <= fifo_wr_level;
end architecture;
