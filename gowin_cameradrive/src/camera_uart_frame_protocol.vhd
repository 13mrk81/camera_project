library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Stop-and-wait UART frame protocol.
--
-- Host -> FPGA:
--   0xC1 : START_TRANSFER
--   0x06 : ACK
--   0x15 : NACK
--
-- FPGA -> host (all multibyte integers are little-endian):
--   READY:  A5 01 width[15:0] height[15:0] bytes_per_pixel pixel_format
--   LINE:  A5 02 line_index[15:0] payload_length[15:0] payload crc16_hi crc16_lo
--   DONE:  A5 03 height[15:0]
--
-- CRC is CRC-16/CCITT-FALSE: poly=0x1021, init=0xFFFF, no reflection,
-- xorout=0. For LINE packets CRC covers TYPE through the final payload byte;
-- the SOF byte 0xA5 and the two CRC bytes are not included.
--
-- The data-source interface is a conventional ready/valid byte stream. A
-- line_start_o pulse starts/restarts the current line source. The source must
-- provide exactly G_FRAME_WIDTH*G_BYTES_PER_PIXEL bytes for that line.
-- A line is retransmitted from its beginning after NACK or ACK timeout.
entity camera_uart_frame_protocol is
    generic (
        G_FRAME_WIDTH             : positive := 256;
        G_FRAME_HEIGHT            : positive := 4;
        G_BYTES_PER_PIXEL         : positive := 1;
        G_PIXEL_FORMAT            : std_logic_vector(7 downto 0) := x"00";
        G_ACK_TIMEOUT_CYCLES      : positive := 16_000_000; -- 2 s at 8 MHz
        G_SOURCE_TIMEOUT_CYCLES   : positive := 8_000_000; -- 1 s at 8 MHz
        G_FRAME_TIMEOUT_CYCLES    : positive := 120_000_000; -- 15 s at 8 MHz
        G_MAX_RETRIES             : natural  := 3
    );
    port (
        clk                 : in  std_logic;
        rst_n               : in  std_logic;

        -- UART RX byte stream.
        rx_data_i           : in  std_logic_vector(7 downto 0);
        rx_valid_i          : in  std_logic;

        -- UART TX ready/valid byte stream.
        tx_data_o           : out std_logic_vector(7 downto 0);
        tx_valid_o          : out std_logic;
        tx_ready_i          : in  std_logic;

        -- Assert after the complete camera frame has been committed to HyperRAM.
        frame_available_i   : in  std_logic;
        frame_error_i       : in  std_logic;

        -- One pulse before each line payload, including retransmissions.
        line_start_o        : out std_logic;
        line_index_o        : out std_logic_vector(15 downto 0);

        -- Source supplies one byte at a time; data is consumed on
        -- src_valid_i AND src_ready_o.
        src_data_i          : in  std_logic_vector(7 downto 0);
        src_valid_i         : in  std_logic;
        src_ready_o         : out std_logic;

        transfer_start_o    : out std_logic;
        line_ack_o          : out std_logic;
        line_retry_o        : out std_logic;
        busy_o              : out std_logic;
        done_o              : out std_logic;
        error_o             : out std_logic
    );
end entity;

architecture rtl of camera_uart_frame_protocol is
    constant C_SOF        : std_logic_vector(7 downto 0) := x"A5";
    constant C_TYPE_READY : std_logic_vector(7 downto 0) := x"01";
    constant C_TYPE_LINE  : std_logic_vector(7 downto 0) := x"02";
    constant C_TYPE_DONE  : std_logic_vector(7 downto 0) := x"03";
    constant C_TYPE_ERROR : std_logic_vector(7 downto 0) := x"7F";
    constant C_CMD_START  : std_logic_vector(7 downto 0) := x"C1";
    constant C_ACK        : std_logic_vector(7 downto 0) := x"06";
    constant C_NACK       : std_logic_vector(7 downto 0) := x"15";

    constant C_PAYLOAD_BYTES : positive := G_FRAME_WIDTH * G_BYTES_PER_PIXEL;
    constant C_WIDTH_U16     : unsigned(15 downto 0) := to_unsigned(G_FRAME_WIDTH, 16);
    constant C_HEIGHT_U16    : unsigned(15 downto 0) := to_unsigned(G_FRAME_HEIGHT, 16);
    constant C_LENGTH_U16    : unsigned(15 downto 0) := to_unsigned(C_PAYLOAD_BYTES, 16);

    type state_t is (
        ST_IDLE,
        ST_WAIT_FRAME,
        ST_SEND_READY,
        ST_WAIT_READY_ACK,
        ST_SEND_LINE_HEADER,
        ST_SEND_LINE_DATA,
        ST_SEND_CRC_HI,
        ST_SEND_CRC_LO,
        ST_WAIT_LINE_ACK,
        ST_SEND_DONE,
        ST_WAIT_DONE_ACK,
        ST_SEND_ERROR,
        ST_DONE,
        ST_ERROR
    );

    signal state                  : state_t := ST_IDLE;
    signal tx_data_reg            : std_logic_vector(7 downto 0) := (others => '0');
    signal tx_valid_reg           : std_logic := '0';
    signal line_start_reg         : std_logic := '0';
    signal transfer_start_reg     : std_logic := '0';
    signal line_ack_reg            : std_logic := '0';
    signal line_retry_reg          : std_logic := '0';
    signal frame_timer             : natural range 0 to G_FRAME_TIMEOUT_CYCLES := 0;
    signal error_reg              : std_logic := '0';

    signal ready_index            : natural range 0 to 7 := 0;
    signal line_header_index      : natural range 0 to 5 := 0;
    signal done_index             : natural range 0 to 3 := 0;
    signal error_index            : natural range 0 to 2 := 0;
    signal error_code_reg         : std_logic_vector(7 downto 0) := x"01";
    signal line_index             : natural range 0 to G_FRAME_HEIGHT - 1 := 0;
    signal payload_count          : natural range 0 to C_PAYLOAD_BYTES - 1 := 0;
    signal last_payload_pending   : std_logic := '0';

    signal crc_reg                : unsigned(15 downto 0) := x"FFFF";
    signal ack_timer              : natural range 0 to G_ACK_TIMEOUT_CYCLES := 0;
    signal source_timer           : natural range 0 to G_SOURCE_TIMEOUT_CYCLES := 0;
    signal retry_count            : natural range 0 to G_MAX_RETRIES := 0;
    signal line_index_u16         : unsigned(15 downto 0);
    signal src_ready_int          : std_logic;

    function crc16_update(
        crc_in  : unsigned(15 downto 0);
        data_in : std_logic_vector(7 downto 0)
    ) return unsigned is
        variable c : unsigned(15 downto 0) := crc_in xor
            shift_left(resize(unsigned(data_in), 16), 8);
    begin
        for i in 0 to 7 loop
            if c(15) = '1' then
                c := shift_left(c, 1) xor to_unsigned(16#1021#, 16);
            else
                c := shift_left(c, 1);
            end if;
        end loop;
        return c;
    end function;
begin
    assert G_FRAME_WIDTH <= 65535
        report "UART protocol: frame width must fit in 16 bits" severity failure;
    assert G_FRAME_HEIGHT <= 65535
        report "UART protocol: frame height must fit in 16 bits" severity failure;
    assert C_PAYLOAD_BYTES <= 65535
        report "UART protocol: bytes per line must fit in 16 bits" severity failure;
    assert G_BYTES_PER_PIXEL <= 255
        report "UART protocol: bytes per pixel must fit in 8 bits" severity failure;

    tx_data_o       <= tx_data_reg;
    tx_valid_o      <= tx_valid_reg;
    line_start_o    <= line_start_reg;
    line_index_o    <= std_logic_vector(line_index_u16);
    transfer_start_o <= transfer_start_reg;
    line_ack_o       <= line_ack_reg;
    line_retry_o     <= line_retry_reg;
    busy_o          <= '0' when (state = ST_IDLE or state = ST_DONE or state = ST_ERROR) else '1';
    done_o          <= '1' when state = ST_DONE else '0';
    error_o         <= error_reg;

    src_ready_int <= '1' when
        (state = ST_SEND_LINE_DATA) and
        (tx_valid_reg = '0') and
        (tx_ready_i = '1')
        else '0';
    src_ready_o <= src_ready_int;

    line_index_u16 <= to_unsigned(line_index, 16);

    process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                state                <= ST_IDLE;
                tx_data_reg          <= (others => '0');
                tx_valid_reg         <= '0';
                line_start_reg       <= '0';
                transfer_start_reg   <= '0';
                line_ack_reg          <= '0';
                line_retry_reg        <= '0';
                frame_timer           <= 0;
                error_reg            <= '0';
                ready_index          <= 0;
                line_header_index    <= 0;
                done_index           <= 0;
                error_index          <= 0;
                error_code_reg       <= x"01";
                line_index           <= 0;
                payload_count        <= 0;
                last_payload_pending <= '0';
                crc_reg              <= x"FFFF";
                ack_timer            <= 0;
                source_timer         <= 0;
                retry_count          <= 0;
            else
                line_start_reg     <= '0';
                transfer_start_reg <= '0';
                line_ack_reg        <= '0';
                line_retry_reg      <= '0';

                -- A pending byte is removed from the protocol engine only
                -- when the UART TX accepts it (valid AND ready).
                if tx_valid_reg = '1' then
                    if tx_ready_i = '1' then
                        tx_valid_reg <= '0';
                        case state is
                            when ST_SEND_READY =>
                                if ready_index = 7 then
                                    state <= ST_WAIT_READY_ACK;
                                    ack_timer <= 0;
                                else
                                    ready_index <= ready_index + 1;
                                end if;

                            when ST_SEND_LINE_HEADER =>
                                if line_header_index >= 1 then
                                    crc_reg <= crc16_update(crc_reg, tx_data_reg);
                                end if;
                                if line_header_index = 5 then
                                    state <= ST_SEND_LINE_DATA;
                                    line_start_reg <= '1';
                                    payload_count <= 0;
                                    source_timer <= 0;
                                    last_payload_pending <= '0';
                                else
                                    line_header_index <= line_header_index + 1;
                                end if;

                            when ST_SEND_LINE_DATA =>
                                if last_payload_pending = '1' then
                                    last_payload_pending <= '0';
                                    state <= ST_SEND_CRC_HI;
                                end if;

                            when ST_SEND_CRC_HI =>
                                state <= ST_SEND_CRC_LO;

                            when ST_SEND_CRC_LO =>
                                state <= ST_WAIT_LINE_ACK;
                                ack_timer <= 0;

                            when ST_SEND_DONE =>
                                if done_index = 3 then
                                    state <= ST_WAIT_DONE_ACK;
                                    ack_timer <= 0;
                                else
                                    done_index <= done_index + 1;
                                end if;

                            when ST_SEND_ERROR =>
                                if error_index = 2 then
                                    state <= ST_ERROR;
                                else
                                    error_index <= error_index + 1;
                                end if;

                            when others => null;
                        end case;
                    end if;

                else
                    case state is
                        when ST_IDLE =>
                            if (rx_valid_i = '1') and (rx_data_i = C_CMD_START) then
                                transfer_start_reg <= '1';
                                ready_index <= 0;
                                retry_count <= 0;
                                frame_timer <= 0;
                                state <= ST_WAIT_FRAME;
                            end if;

                        when ST_WAIT_FRAME =>
                            if frame_error_i = '1' then
                                error_reg <= '1';
                                error_code_reg <= x"02";
                                error_index <= 0;
                                state <= ST_SEND_ERROR;
                            elsif frame_available_i = '1' then
                                ready_index <= 0;
                                state <= ST_SEND_READY;
                            elsif frame_timer = G_FRAME_TIMEOUT_CYCLES - 1 then
                                error_reg <= '1';
                                error_code_reg <= x"03";
                                error_index <= 0;
                                state <= ST_SEND_ERROR;
                            else
                                frame_timer <= frame_timer + 1;
                            end if;

                        when ST_SEND_READY =>
                            case ready_index is
                                when 0 => tx_data_reg <= C_SOF;
                                when 1 => tx_data_reg <= C_TYPE_READY;
                                when 2 => tx_data_reg <= std_logic_vector(C_WIDTH_U16(7 downto 0));
                                when 3 => tx_data_reg <= std_logic_vector(C_WIDTH_U16(15 downto 8));
                                when 4 => tx_data_reg <= std_logic_vector(C_HEIGHT_U16(7 downto 0));
                                when 5 => tx_data_reg <= std_logic_vector(C_HEIGHT_U16(15 downto 8));
                                when 6 => tx_data_reg <= std_logic_vector(to_unsigned(G_BYTES_PER_PIXEL, 8));
                                when others => tx_data_reg <= G_PIXEL_FORMAT;
                            end case;
                            tx_valid_reg <= '1';

                        when ST_WAIT_READY_ACK =>
                            if rx_valid_i = '1' and rx_data_i = C_ACK then
                                line_index <= 0;
                                line_header_index <= 0;
                                payload_count <= 0;
                                crc_reg <= x"FFFF";
                                retry_count <= 0;
                                state <= ST_SEND_LINE_HEADER;
                            elsif rx_valid_i = '1' and rx_data_i = C_NACK then
                                if retry_count < G_MAX_RETRIES then
                                    retry_count <= retry_count + 1;
                                    ready_index <= 0;
                                    state <= ST_SEND_READY;
                                else
                                    error_reg <= '1';
                                    error_index <= 0;
                                    state <= ST_SEND_ERROR;
                                end if;
                                ack_timer <= 0;
                            elsif ack_timer < G_ACK_TIMEOUT_CYCLES then
                                ack_timer <= ack_timer + 1;
                            else
                                if retry_count < G_MAX_RETRIES then
                                    retry_count <= retry_count + 1;
                                    ready_index <= 0;
                                    state <= ST_SEND_READY;
                                else
                                    error_reg <= '1';
                                    error_index <= 0;
                                    state <= ST_SEND_ERROR;
                                end if;
                                ack_timer <= 0;
                            end if;

                        when ST_SEND_LINE_HEADER =>
                            case line_header_index is
                                when 0 => tx_data_reg <= C_SOF;
                                when 1 => tx_data_reg <= C_TYPE_LINE;
                                when 2 => tx_data_reg <= std_logic_vector(line_index_u16(7 downto 0));
                                when 3 => tx_data_reg <= std_logic_vector(line_index_u16(15 downto 8));
                                when 4 => tx_data_reg <= std_logic_vector(C_LENGTH_U16(7 downto 0));
                                when others => tx_data_reg <= std_logic_vector(C_LENGTH_U16(15 downto 8));
                            end case;
                            tx_valid_reg <= '1';

                        when ST_SEND_LINE_DATA =>
                            if src_valid_i = '1' and src_ready_int = '1' then
                                tx_data_reg <= src_data_i;
                                tx_valid_reg <= '1';
                                crc_reg <= crc16_update(crc_reg, src_data_i);
                                source_timer <= 0;
                                if payload_count = C_PAYLOAD_BYTES - 1 then
                                    last_payload_pending <= '1';
                                else
                                    payload_count <= payload_count + 1;
                                end if;
                            elsif source_timer < G_SOURCE_TIMEOUT_CYCLES then
                                source_timer <= source_timer + 1;
                            else
                                error_reg <= '1';
                                    error_index <= 0;
                                    state <= ST_SEND_ERROR;
                            end if;

                        when ST_SEND_CRC_HI =>
                            tx_data_reg <= std_logic_vector(crc_reg(15 downto 8));
                            tx_valid_reg <= '1';

                        when ST_SEND_CRC_LO =>
                            tx_data_reg <= std_logic_vector(crc_reg(7 downto 0));
                            tx_valid_reg <= '1';

                        when ST_WAIT_LINE_ACK =>
                            if rx_valid_i = '1' and rx_data_i = C_ACK then
                                line_ack_reg <= '1';
                                retry_count <= 0;
                                if line_index = G_FRAME_HEIGHT - 1 then
                                    done_index <= 0;
                                    state <= ST_SEND_DONE;
                                else
                                    line_index <= line_index + 1;
                                    line_header_index <= 0;
                                    payload_count <= 0;
                                    crc_reg <= x"FFFF";
                                    state <= ST_SEND_LINE_HEADER;
                                end if;
                                ack_timer <= 0;
                            elsif rx_valid_i = '1' and rx_data_i = C_NACK then
                                if retry_count < G_MAX_RETRIES then
                                    line_retry_reg <= '1';
                                    retry_count <= retry_count + 1;
                                    line_header_index <= 0;
                                    payload_count <= 0;
                                    crc_reg <= x"FFFF";
                                    state <= ST_SEND_LINE_HEADER;
                                else
                                    error_reg <= '1';
                                    error_index <= 0;
                                    state <= ST_SEND_ERROR;
                                end if;
                                ack_timer <= 0;
                            elsif ack_timer < G_ACK_TIMEOUT_CYCLES then
                                ack_timer <= ack_timer + 1;
                            else
                                if retry_count < G_MAX_RETRIES then
                                    line_retry_reg <= '1';
                                    retry_count <= retry_count + 1;
                                    line_header_index <= 0;
                                    payload_count <= 0;
                                    crc_reg <= x"FFFF";
                                    state <= ST_SEND_LINE_HEADER;
                                else
                                    error_reg <= '1';
                                    error_index <= 0;
                                    state <= ST_SEND_ERROR;
                                end if;
                                ack_timer <= 0;
                            end if;

                        when ST_SEND_DONE =>
                            case done_index is
                                when 0 => tx_data_reg <= C_SOF;
                                when 1 => tx_data_reg <= C_TYPE_DONE;
                                when 2 => tx_data_reg <= std_logic_vector(C_HEIGHT_U16(7 downto 0));
                                when others => tx_data_reg <= std_logic_vector(C_HEIGHT_U16(15 downto 8));
                            end case;
                            tx_valid_reg <= '1';

                        when ST_WAIT_DONE_ACK =>
                            if rx_valid_i = '1' and rx_data_i = C_ACK then
                                state <= ST_DONE;
                            elsif rx_valid_i = '1' and rx_data_i = C_NACK then
                                if retry_count < G_MAX_RETRIES then
                                    retry_count <= retry_count + 1;
                                    done_index <= 0;
                                    state <= ST_SEND_DONE;
                                else
                                    error_reg <= '1';
                                    error_index <= 0;
                                    state <= ST_SEND_ERROR;
                                end if;
                                ack_timer <= 0;
                            elsif ack_timer < G_ACK_TIMEOUT_CYCLES then
                                ack_timer <= ack_timer + 1;
                            else
                                if retry_count < G_MAX_RETRIES then
                                    retry_count <= retry_count + 1;
                                    done_index <= 0;
                                    state <= ST_SEND_DONE;
                                else
                                    error_reg <= '1';
                                    error_index <= 0;
                                    state <= ST_SEND_ERROR;
                                end if;
                                ack_timer <= 0;
                            end if;

                        when ST_SEND_ERROR =>
                            case error_index is
                                when 0 => tx_data_reg <= C_SOF;
                                when 1 => tx_data_reg <= C_TYPE_ERROR;
                                when others => tx_data_reg <= error_code_reg;
                            end case;
                            tx_valid_reg <= '1';

                        when ST_DONE => null;
                        when ST_ERROR => null;
                    end case;
                end if;
            end if;
        end if;
    end process;

end architecture;
