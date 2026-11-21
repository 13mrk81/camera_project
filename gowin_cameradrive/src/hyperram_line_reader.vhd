library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Reads one complete image line per transaction and writes each returned
-- 32-bit word into the output FIFO.
--
-- IMPORTANT: This block uses an abstract read-command valid/ready interface.
-- A small adapter must translate that handshake to the actual Gowin
-- HyperRAM_Memory_Interface_Top interface after its command acceptance,
-- address-unit, response-latency and burst-cadence rules are verified.
-- One accepted command is required to return exactly G_BURST_WORDS words.
entity hyperram_line_reader is
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
        clk                    : in  std_logic;
        rst_n                  : in  std_logic;
        frame_written_i        : in  std_logic;

        -- Abstract HyperRAM read-command channel.
        rd_cmd_valid_o         : out std_logic;
        rd_cmd_ready_i         : in  std_logic;
        rd_cmd_addr_o          : out std_logic_vector(G_ADDR_WIDTH - 1 downto 0);
        rd_data_i              : in  std_logic_vector(31 downto 0);
        rd_data_valid_i        : in  std_logic;

        -- Output-FIFO write interface. One accepted write per read-data beat.
        fifo_wr_en_o           : out std_logic;
        fifo_wr_data_o         : out std_logic_vector(31 downto 0);
        fifo_wr_full_i         : in  std_logic;
        fifo_wr_level_i        : in  unsigned(G_FIFO_ADDR_BITS downto 0);

        -- Local line-complete acknowledgement is synchronized into this memory-clock
        -- domain. Retry is disabled by the one-way top-level protocol.
        line_ack_i             : in  std_logic;
        line_retry_i           : in  std_logic;

        -- Flag A: one-cycle pulse at the start of every line read.
        line_read_req_o        : out std_logic;
        -- Flag B: sticky until the local completed-line pulse is received.
        line_ready_o           : out std_logic;
        line_complete_o        : out std_logic;
        frame_stream_done_o    : out std_logic;
        error_o                : out std_logic;
        addr_check_error_o     : out std_logic;
        line_index_o           : out unsigned(15 downto 0);
        line_word_count_o      : out unsigned(15 downto 0);
        read_ingress_crc_o     : out std_logic_vector(31 downto 0);
        read_ingress_word_count_o : out unsigned(31 downto 0);
        burst_index_o          : out unsigned(15 downto 0)
    );
end entity;

architecture rtl of hyperram_line_reader is
    constant C_WORDS_PER_LINE   : positive := G_FRAME_WIDTH / 2;
    constant C_BURSTS_PER_LINE  : positive := C_WORDS_PER_LINE / G_BURST_WORDS;

    type state_t is (
        ST_WAIT_FRAME,
        ST_WAIT_FIFO_EMPTY,
        ST_ISSUE_COMMAND,
        ST_WAIT_BURST_DATA,
        ST_WAIT_LINE_ACK,
        ST_DONE,
        ST_ERROR
    );
    signal state : state_t := ST_WAIT_FRAME;

    signal rd_addr_reg          : unsigned(G_ADDR_WIDTH - 1 downto 0) := (others => '0');
    signal rd_addr_ref_reg      : unsigned(G_ADDR_WIDTH - 1 downto 0) := unsigned(G_BASE_ADDR);
    signal ref_beat_count_reg   : natural range 0 to G_BURST_WORDS - 1 := 0;
    signal addr_check_error_reg : std_logic := '0';
    signal line_index_reg       : natural range 0 to G_FRAME_HEIGHT - 1 := 0;
    signal line_word_count_reg  : natural range 0 to C_WORDS_PER_LINE := 0;
    signal burst_index_reg      : natural range 0 to C_BURSTS_PER_LINE - 1 := 0;
    signal beat_count_reg       : natural range 0 to G_BURST_WORDS - 1 := 0;
    signal timeout_count_reg    : natural range 0 to G_READ_TIMEOUT_CYCLES := 0;

    signal line_req_reg         : std_logic := '0';
    signal line_ready_reg       : std_logic := '0';
    signal line_complete_reg    : std_logic := '0';
    signal frame_done_reg       : std_logic := '0';
    signal error_reg            : std_logic := '0';
    signal ingress_crc_reg      : std_logic_vector(31 downto 0) := x"FFFFFFFF";
    signal ingress_word_count_reg : unsigned(31 downto 0) := (others => '0');

    function crc32_byte(crc_in : std_logic_vector(31 downto 0); data_in : std_logic_vector(7 downto 0)) return std_logic_vector is
        variable c : unsigned(31 downto 0) := unsigned(crc_in);
        variable feedback : std_logic;
        constant POLY : unsigned(31 downto 0) := x"04C11DB7";
    begin
        for i in 7 downto 0 loop
            feedback := c(31) xor data_in(i);
            c := shift_left(c, 1);
            if feedback = '1' then c := c xor POLY; end if;
        end loop;
        return std_logic_vector(c);
    end function;

    function crc32_word(crc_in : std_logic_vector(31 downto 0); data_in : std_logic_vector(31 downto 0)) return std_logic_vector is
        variable c : std_logic_vector(31 downto 0) := crc_in;
    begin
        c := crc32_byte(c, data_in(31 downto 24));
        c := crc32_byte(c, data_in(23 downto 16));
        c := crc32_byte(c, data_in(15 downto 8));
        c := crc32_byte(c, data_in(7 downto 0));
        return c;
    end function;

begin
    assert (G_FRAME_WIDTH mod 2) = 0
        report "Frame width must contain an integer number of RGB565 pixels per word"
        severity failure;
    assert (C_WORDS_PER_LINE mod G_BURST_WORDS) = 0
        report "Words per line must be divisible by the HyperRAM burst length"
        severity failure;
    assert (2 ** G_FIFO_ADDR_BITS) >= C_WORDS_PER_LINE
        report "Output FIFO depth must hold one complete line"
        severity failure;
    assert G_FRAME_WIDTH >= 2 * G_BURST_WORDS
        report "Frame width is too small for one complete HyperRAM burst"
        severity failure;
    assert G_FRAME_HEIGHT <= 65535
        report "G_FRAME_HEIGHT must fit the 16-bit line index outputs"
        severity failure;
    assert G_READ_TIMEOUT_CYCLES > 0
        report "G_READ_TIMEOUT_CYCLES must be greater than zero"
        severity failure;

    -- The read-data stream is not backpressured by the line FIFO. The FIFO is
    -- checked before each write; an unexpected full condition is fatal.
    rd_cmd_valid_o  <= '1' when state = ST_ISSUE_COMMAND else '0';
    rd_cmd_addr_o   <= std_logic_vector(rd_addr_reg);
    fifo_wr_en_o    <= '1' when (state = ST_WAIT_BURST_DATA) and
                                (rd_data_valid_i = '1') and
                                (fifo_wr_full_i = '0') else '0';
    fifo_wr_data_o  <= rd_data_i;
    line_read_req_o <= line_req_reg;
    line_ready_o    <= line_ready_reg;
    line_complete_o <= line_complete_reg;
    frame_stream_done_o <= frame_done_reg;
    error_o         <= error_reg;
    addr_check_error_o <= addr_check_error_reg;
    line_index_o    <= to_unsigned(line_index_reg, line_index_o'length);
    line_word_count_o <= to_unsigned(line_word_count_reg, line_word_count_o'length);
    read_ingress_crc_o <= ingress_crc_reg;
    read_ingress_word_count_o <= ingress_word_count_reg;
    burst_index_o   <= to_unsigned(burst_index_reg, burst_index_o'length);

    process(clk, rst_n)
    begin
        if rst_n = '0' then
            state                <= ST_WAIT_FRAME;
            line_index_reg       <= 0;
            line_word_count_reg  <= 0;
            burst_index_reg      <= 0;
            beat_count_reg       <= 0;
            timeout_count_reg    <= 0;
            line_req_reg         <= '0';
            line_ready_reg       <= '0';
            line_complete_reg    <= '0';
            frame_done_reg       <= '0';
            error_reg            <= '0';
            ingress_crc_reg      <= x"FFFFFFFF";
            ingress_word_count_reg <= (others => '0');
        elsif rising_edge(clk) then
            line_req_reg      <= '0';
            line_complete_reg <= '0';

            -- A response beat outside the data phase means the adapter/IP
            -- timing contract does not match this controller.
            if (rd_data_valid_i = '1') and (state /= ST_WAIT_BURST_DATA) then
                error_reg <= '1';
                state <= ST_ERROR;
            else
                case state is
                    when ST_WAIT_FRAME =>
                        if frame_written_i = '1' then
                            state <= ST_WAIT_FIFO_EMPTY;
                        end if;

                    when ST_WAIT_FIFO_EMPTY =>
                        -- FIFO write-domain occupancy includes a synchronized
                        -- read pointer. Wait for true empty before reusing it.
                        -- Bound this wait so a stalled read-side pointer or
                        -- broken CDC cannot leave the line reader stuck forever.
                        if fifo_wr_level_i = to_unsigned(0, fifo_wr_level_i'length) then
                            line_word_count_reg <= 0;
                            burst_index_reg <= 0;
                            beat_count_reg <= 0;
                            timeout_count_reg <= 0;
                            line_req_reg <= '1'; -- Flag A
                            state <= ST_ISSUE_COMMAND;
                        elsif timeout_count_reg = G_READ_TIMEOUT_CYCLES - 1 then
                            error_reg <= '1';
                            state <= ST_ERROR;
                        else
                            timeout_count_reg <= timeout_count_reg + 1;
                        end if;

                    when ST_ISSUE_COMMAND =>
                        if rd_cmd_ready_i = '1' then
                            beat_count_reg <= 0;
                            timeout_count_reg <= 0;
                            state <= ST_WAIT_BURST_DATA;
                        elsif timeout_count_reg = G_READ_TIMEOUT_CYCLES - 1 then
                            error_reg <= '1';
                            state <= ST_ERROR;
                        else
                            timeout_count_reg <= timeout_count_reg + 1;
                        end if;

                    when ST_WAIT_BURST_DATA =>
                        if rd_data_valid_i = '1' then
                            timeout_count_reg <= 0;
                            if fifo_wr_full_i = '1' then
                                error_reg <= '1';
                                state <= ST_ERROR;
                            else
                                line_word_count_reg <= line_word_count_reg + 1;
                                ingress_crc_reg <= crc32_word(ingress_crc_reg, rd_data_i);
                                ingress_word_count_reg <= ingress_word_count_reg + 1;
                                if beat_count_reg = G_BURST_WORDS - 1 then
                                    -- Advance after every burst, including the last burst
                                    -- of a line, so the next line starts at the next region.
                                    if burst_index_reg = C_BURSTS_PER_LINE - 1 then
                                        if line_word_count_reg = C_WORDS_PER_LINE - 1 then
                                            line_ready_reg <= '1'; -- Flag B
                                            state <= ST_WAIT_LINE_ACK;
                                        else
                                            error_reg <= '1';
                                            state <= ST_ERROR;
                                        end if;
                                    else
                                        burst_index_reg <= burst_index_reg + 1;
                                        state <= ST_ISSUE_COMMAND;
                                    end if;
                                else
                                    beat_count_reg <= beat_count_reg + 1;
                                end if;
                            end if;
                        elsif timeout_count_reg = G_READ_TIMEOUT_CYCLES - 1 then
                            error_reg <= '1';
                            state <= ST_ERROR;
                        else
                            timeout_count_reg <= timeout_count_reg + 1;
                        end if;

                    when ST_WAIT_LINE_ACK =>
                        if line_ack_i = '1' then -- Local packet-complete acknowledgement.
                            line_ready_reg <= '0';
                            line_complete_reg <= '1';
                            if line_index_reg = G_FRAME_HEIGHT - 1 then
                                frame_done_reg <= '1';
                                state <= ST_DONE;
                            else
                                line_index_reg <= line_index_reg + 1;
                                timeout_count_reg <= 0;
                                state <= ST_WAIT_FIFO_EMPTY;
                            end if;
                        elsif line_retry_i = '1' then -- Inactive in the one-way design.
                            line_ready_reg <= '0';
                            line_word_count_reg <= 0;
                            burst_index_reg <= 0;
                            beat_count_reg <= 0;
                            timeout_count_reg <= 0;
                            state <= ST_WAIT_FIFO_EMPTY;
                        end if;

                    when ST_DONE =>
                        state <= ST_DONE;

                    when ST_ERROR =>
                        state <= ST_ERROR;

                    when others =>
                        error_reg <= '1';
                        state <= ST_ERROR;
                end case;
            end if;
        end if;
    end process;

    process(clk, rst_n)
    begin
        if rst_n = '0' then
            rd_addr_reg <= unsigned(G_BASE_ADDR);

        elsif rising_edge(clk) then
            if (state = ST_WAIT_LINE_ACK) and (line_retry_i = '1') then
                rd_addr_reg <= unsigned(G_BASE_ADDR) +
                    to_unsigned(line_index_reg * C_BURSTS_PER_LINE * G_BURST_ADDR_STRIDE,
                                G_ADDR_WIDTH);
            elsif (state = ST_WAIT_BURST_DATA) and
               (rd_data_valid_i = '1') and
               (fifo_wr_full_i = '0') and
               (beat_count_reg = G_BURST_WORDS - 1) then

                rd_addr_reg <= rd_addr_reg +
                    to_unsigned(G_BURST_ADDR_STRIDE, G_ADDR_WIDTH);

            end if;
        end if;
    end process;

    -- Independent READ address checker. Its beat counter is separate from
    -- beat_count_reg, and the reference address is never derived from rd_addr_reg.
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            rd_addr_ref_reg      <= unsigned(G_BASE_ADDR);
            ref_beat_count_reg   <= 0;
            addr_check_error_reg <= '0';
        elsif rising_edge(clk) then
            if rd_addr_reg /= rd_addr_ref_reg then
                addr_check_error_reg <= '1';
            end if;

            if (state = ST_WAIT_LINE_ACK) and (line_retry_i = '1') then
                rd_addr_ref_reg <= unsigned(G_BASE_ADDR) +
                    to_unsigned(line_index_reg * C_BURSTS_PER_LINE * G_BURST_ADDR_STRIDE,
                                G_ADDR_WIDTH);
                ref_beat_count_reg <= 0;
            elsif (state = ST_WAIT_BURST_DATA) and
                  (rd_data_valid_i = '1') and (fifo_wr_full_i = '0') then
                if ref_beat_count_reg = G_BURST_WORDS - 1 then
                    ref_beat_count_reg <= 0;
                    rd_addr_ref_reg <= rd_addr_ref_reg +
                        to_unsigned(G_BURST_ADDR_STRIDE, G_ADDR_WIDTH);
                else
                    ref_beat_count_reg <= ref_beat_count_reg + 1;
                end if;
            end if;
        end if;
    end process;
end architecture;
