library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- One-way FPGA -> MATLAB camera stream. The passive host never transmits.
-- Packet: A5 5A TYPE SEQ_LO SEQ_HI LEN_LO LEN_HI PAYLOAD CRC_HI CRC_LO.
-- CRC-16/CCITT-FALSE covers TYPE through the last PAYLOAD byte, not the SOF.
-- Sequence, length and payload integers are little-endian.
-- Types: 10 STAGE [stage,detail]; 11 READY [width(2),height(2),03,01];
-- 20 LINE [RGB888 R,G,B triplets, sequence=row]; 30 DONE [46-byte
-- stream + capture/write/read CRCs, byte/word counts, and status flags];
-- 7F ERROR [error_code,detail,camera/SCCB diagnostic snapshot (14 bytes)].
--
-- A line is internally acknowledged only after CRC_LO's stop bit completes.
-- This is local flow control, not an ACK from MATLAB; no retransmission exists.
entity camera_uart_frame_protocol is
    generic (
        G_FRAME_WIDTH           : positive := 640;
        G_FRAME_HEIGHT          : positive := 480;
        G_PACKET_GAP_CYCLES     : positive := 160_000;
        G_SOURCE_TIMEOUT_CYCLES : positive := 32_000_000;
        G_FRAME_TIMEOUT_CYCLES  : positive := 120_000_000
    );
    port (
        clk                   : in  std_logic;
        rst_n                 : in  std_logic;
        trigger_i             : in  std_logic;
        camera_config_done_i  : in  std_logic;
        camera_config_pass_i  : in  std_logic;
        frame_available_i     : in  std_logic;
        frame_error_i         : in  std_logic;
        readout_error_i       : in  std_logic;
        serializer_done_i     : in  std_logic;
        telemetry_ready_i     : in  std_logic;
        camera_cfg_state_i    : in  std_logic_vector(4 downto 0);
        camera_cfg_error_i    : in  std_logic_vector(3 downto 0);
        camera_cfg_reg_addr_i : in  std_logic_vector(7 downto 0);
        camera_cfg_reg_data_i : in  std_logic_vector(7 downto 0);
        camera_cfg_device_i   : in  std_logic_vector(6 downto 0);
        camera_cfg_chip_id_i  : in  std_logic_vector(7 downto 0);
        camera_cfg_ack_count_i: in  std_logic_vector(1 downto 0);
        camera_cfg_nack_i     : in  std_logic;
        camera_cfg_init_index_i : in std_logic_vector(7 downto 0);
        camera_cfg_verify_index_i : in std_logic_vector(3 downto 0);
        camera_i2c_sequence_i : in  std_logic_vector(1 downto 0);
        camera_i2c_state_i    : in  std_logic_vector(3 downto 0);
        camera_cfg_last_read_i: in  std_logic_vector(7 downto 0);
        camera_cfg_rw_i       : in  std_logic;
        capture_crc_i         : in  std_logic_vector(31 downto 0);
        write_crc_i           : in  std_logic_vector(31 downto 0);
        read_ingress_crc_i    : in  std_logic_vector(31 downto 0);
        source_byte_count_i   : in  unsigned(31 downto 0);
        capture_byte_count_i  : in  unsigned(31 downto 0);
        write_word_count_i    : in  unsigned(31 downto 0);
        read_ingress_word_count_i : in unsigned(31 downto 0);
        status_flags_i        : in  std_logic_vector(15 downto 0);
        readback_crc_i        : in  std_logic_vector(31 downto 0);
        pixel_count_i         : in  unsigned(31 downto 0);
        uart_byte_count_i     : in  unsigned(31 downto 0);
        lines_sent_i          : in  unsigned(15 downto 0);
        tx_data_o             : out std_logic_vector(7 downto 0);
        tx_valid_o            : out std_logic;
        tx_ready_i            : in  std_logic;
        line_start_o          : out std_logic;
        line_index_o          : out std_logic_vector(15 downto 0);
        src_data_i            : in  std_logic_vector(7 downto 0);
        src_valid_i           : in  std_logic;
        src_ready_o           : out std_logic;
        transfer_start_o      : out std_logic;
        line_ack_o            : out std_logic;
        busy_o                : out std_logic;
        done_o                : out std_logic;
        error_o               : out std_logic
    );
end entity;

architecture rtl of camera_uart_frame_protocol is
    constant C_LINE_BYTES       : positive := G_FRAME_WIDTH * 3;
    constant C_WIDTH_U16        : unsigned(15 downto 0) := to_unsigned(G_FRAME_WIDTH, 16);
    constant C_HEIGHT_U16       : unsigned(15 downto 0) := to_unsigned(G_FRAME_HEIGHT, 16);
    constant C_LINE_BYTES_U16   : unsigned(15 downto 0) := to_unsigned(C_LINE_BYTES, 16);
    constant C_DONE_BYTES_U16   : unsigned(15 downto 0) := to_unsigned(46, 16);

    constant C_TYPE_STAGE : std_logic_vector(7 downto 0) := x"10";
    constant C_TYPE_READY : std_logic_vector(7 downto 0) := x"11";
    constant C_TYPE_LINE  : std_logic_vector(7 downto 0) := x"20";
    constant C_TYPE_DONE  : std_logic_vector(7 downto 0) := x"30";
    constant C_TYPE_ERROR : std_logic_vector(7 downto 0) := x"7F";

    type packet_kind_t is (PKT_STAGE, PKT_READY, PKT_LINE, PKT_DONE, PKT_ERROR);
    type tx_state_t is (
        TX_IDLE, TX_SOF_0, TX_SOF_1, TX_TYPE, TX_SEQ_LO, TX_SEQ_HI,
        TX_LEN_LO, TX_LEN_HI, TX_PAYLOAD, TX_CRC_HI, TX_CRC_LO,
        TX_WAIT_UART_IDLE
    );
    type ctrl_state_t is (
        C_IDLE, C_TRIGGER_PACKET, C_GAP_TO_CONFIG, C_CONFIG_START_PACKET,
        C_WAIT_CAMERA_CONFIG, C_CONFIG_PACKET, C_GAP_TO_FRAME, C_FRAME_START_PACKET,
        C_WAIT_FRAME, C_FRAME_STORED_PACKET,
        C_GAP_TO_READY, C_READY_PACKET, C_GAP_TO_FIRST_LINE, C_LINE_PACKET,
        C_GAP_TO_NEXT_LINE, C_GAP_TO_DONE, C_WAIT_SERIALIZER_DONE, C_DONE_PACKET,
        C_ERROR_GAP, C_ERROR_PACKET, C_DONE, C_ERROR
    );

    signal ctrl_state          : ctrl_state_t := C_IDLE;
    signal line_index_reg      : natural range 0 to G_FRAME_HEIGHT - 1 := 0;
    signal gap_count           : natural range 0 to G_PACKET_GAP_CYCLES := 0;
    signal stage_timer         : natural range 0 to G_FRAME_TIMEOUT_CYCLES := 0;
    signal done_reg            : std_logic := '0';
    signal error_reg           : std_logic := '0';

    signal packet_start_reg    : std_logic := '0';
    signal packet_kind_desc    : packet_kind_t := PKT_STAGE;
    signal packet_seq_desc     : unsigned(15 downto 0) := (others => '0');
    signal packet_len_desc     : unsigned(15 downto 0) := (others => '0');
    signal stage_code_desc     : std_logic_vector(7 downto 0) := (others => '0');
    signal stage_detail_desc   : std_logic_vector(7 downto 0) := (others => '0');
    signal error_code_desc     : std_logic_vector(7 downto 0) := (others => '0');
    signal error_detail_desc   : std_logic_vector(7 downto 0) := (others => '0');

    signal tx_state            : tx_state_t := TX_IDLE;
    signal tx_kind             : packet_kind_t := PKT_STAGE;
    signal tx_seq              : unsigned(15 downto 0) := (others => '0');
    signal tx_length           : unsigned(15 downto 0) := (others => '0');
    signal tx_payload_index    : natural range 0 to C_LINE_BYTES := 0;
    signal tx_stage_code       : std_logic_vector(7 downto 0) := (others => '0');
    signal tx_stage_detail     : std_logic_vector(7 downto 0) := (others => '0');
    signal tx_error_code       : std_logic_vector(7 downto 0) := (others => '0');
    signal tx_error_detail     : std_logic_vector(7 downto 0) := (others => '0');
    signal crc_reg             : unsigned(15 downto 0) := x"FFFF";
    signal tx_data_reg         : std_logic_vector(7 downto 0) := (others => '0');
    signal tx_valid_reg        : std_logic := '0';
    signal packet_done_reg     : std_logic := '0';
    signal source_fault_reg    : std_logic := '0';
    signal source_fault_code   : std_logic_vector(7 downto 0) := x"05";
    signal source_timer        : natural range 0 to G_SOURCE_TIMEOUT_CYCLES := 0;
    signal src_ready_int       : std_logic;

    signal transfer_start_reg  : std_logic := '0';
    signal line_start_reg      : std_logic := '0';
    signal line_ack_reg        : std_logic := '0';

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
    assert C_LINE_BYTES <= 65535
        report "UART protocol: RGB888 line length must fit in 16 bits" severity failure;
    assert G_PACKET_GAP_CYCLES > 0
        report "UART protocol: packet gap must be greater than zero" severity failure;
    assert G_SOURCE_TIMEOUT_CYCLES > 0
        report "UART protocol: source timeout must be greater than zero" severity failure;

    tx_data_o        <= tx_data_reg;
    tx_valid_o       <= tx_valid_reg;
    src_ready_o      <= src_ready_int;
    src_ready_int    <= '1' when
        (tx_state = TX_PAYLOAD) and (tx_kind = PKT_LINE) and
        (tx_valid_reg = '0') and (tx_ready_i = '1') and
        (readout_error_i = '0') else '0';
    line_start_o     <= line_start_reg;
    line_index_o     <= std_logic_vector(to_unsigned(line_index_reg, 16));
    transfer_start_o <= transfer_start_reg;
    line_ack_o       <= line_ack_reg;
    busy_o           <= '0' when (ctrl_state = C_IDLE or ctrl_state = C_DONE or ctrl_state = C_ERROR) else '1';
    done_o           <= done_reg;
    error_o          <= error_reg;

    -- Camera and capture sequencer.
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            ctrl_state          <= C_IDLE;
            line_index_reg      <= 0;
            gap_count           <= 0;
            stage_timer         <= 0;
            packet_start_reg    <= '0';
            packet_kind_desc    <= PKT_STAGE;
            packet_seq_desc     <= (others => '0');
            packet_len_desc     <= (others => '0');
            stage_code_desc     <= (others => '0');
            stage_detail_desc   <= (others => '0');
            error_code_desc     <= (others => '0');
            error_detail_desc   <= (others => '0');
            transfer_start_reg  <= '0';
            line_start_reg      <= '0';
            line_ack_reg        <= '0';
            done_reg            <= '0';
            error_reg           <= '0';
        elsif rising_edge(clk) then
            packet_start_reg   <= '0';
            transfer_start_reg <= '0';
            line_start_reg     <= '0';
            line_ack_reg       <= '0';

            case ctrl_state is
                when C_IDLE =>
                    if trigger_i = '1' then
                        transfer_start_reg <= '1';
                        line_index_reg <= 0;
                        packet_kind_desc <= PKT_STAGE;
                        packet_seq_desc <= (others => '0');
                        packet_len_desc <= to_unsigned(2, 16);
                        stage_code_desc <= x"01"; -- TRIGGER_ACCEPTED
                        stage_detail_desc <= x"00";
                        packet_start_reg <= '1';
                        ctrl_state <= C_TRIGGER_PACKET;
                    end if;

                when C_TRIGGER_PACKET =>
                    if packet_done_reg = '1' then
                        gap_count <= 0;
                        ctrl_state <= C_GAP_TO_CONFIG;
                    end if;

                when C_GAP_TO_CONFIG =>
                    if gap_count = G_PACKET_GAP_CYCLES - 1 then
                        gap_count <= 0;
                        packet_kind_desc <= PKT_STAGE;
                        packet_seq_desc <= (others => '0');
                        packet_len_desc <= to_unsigned(2, 16);
                        stage_code_desc <= x"04"; -- CAMERA_CONFIG_RUNNING
                        stage_detail_desc <= x"00";
                        packet_start_reg <= '1';
                        ctrl_state <= C_CONFIG_START_PACKET;
                    else
                        gap_count <= gap_count + 1;
                    end if;

                when C_CONFIG_START_PACKET =>
                    if packet_done_reg = '1' then
                        stage_timer <= 0;
                        ctrl_state <= C_WAIT_CAMERA_CONFIG;
                    end if;

                when C_WAIT_CAMERA_CONFIG =>
                    if camera_config_done_i = '1' then
                        if camera_config_pass_i = '1' then
                            packet_kind_desc <= PKT_STAGE;
                            packet_seq_desc <= (others => '0');
                            packet_len_desc <= to_unsigned(2, 16);
                            stage_code_desc <= x"02"; -- CAMERA_CONFIG_PASS
                            stage_detail_desc <= x"00";
                            packet_start_reg <= '1';
                            ctrl_state <= C_CONFIG_PACKET;
                        else
                            packet_kind_desc <= PKT_ERROR;
                            packet_seq_desc <= (others => '0');
                            packet_len_desc <= to_unsigned(16, 16);
                            error_code_desc <= x"01"; -- CAMERA_CONFIG
                            error_detail_desc <= x"01";
                            gap_count <= 0;
                            error_reg <= '1';
                            ctrl_state <= C_ERROR_GAP;
                        end if;
                    elsif stage_timer = G_FRAME_TIMEOUT_CYCLES - 1 then
                        packet_kind_desc <= PKT_ERROR;
                        packet_seq_desc <= (others => '0');
                        packet_len_desc <= to_unsigned(16, 16);
                        error_code_desc <= x"03"; -- STAGE_TIMEOUT
                        error_detail_desc <= x"01"; -- camera configuration
                        gap_count <= 0;
                        error_reg <= '1';
                        ctrl_state <= C_ERROR_GAP;
                    else
                        stage_timer <= stage_timer + 1;
                    end if;

                when C_CONFIG_PACKET =>
                    if packet_done_reg = '1' then
                        gap_count <= 0;
                        ctrl_state <= C_GAP_TO_FRAME;
                    end if;

                when C_GAP_TO_FRAME =>
                    if gap_count = G_PACKET_GAP_CYCLES - 1 then
                        gap_count <= 0;
                        packet_kind_desc <= PKT_STAGE;
                        packet_seq_desc <= (others => '0');
                        packet_len_desc <= to_unsigned(2, 16);
                        stage_code_desc <= x"05"; -- FRAME_CAPTURE_AND_HYPERRAM_WRITE_RUNNING
                        stage_detail_desc <= x"00";
                        packet_start_reg <= '1';
                        ctrl_state <= C_FRAME_START_PACKET;
                    else
                        gap_count <= gap_count + 1;
                    end if;

                when C_FRAME_START_PACKET =>
                    if packet_done_reg = '1' then
                        stage_timer <= 0;
                        ctrl_state <= C_WAIT_FRAME;
                    end if;

                when C_WAIT_FRAME =>
                    if frame_error_i = '1' then
                        packet_kind_desc <= PKT_ERROR;
                        packet_seq_desc <= (others => '0');
                        packet_len_desc <= to_unsigned(16, 16);
                        error_code_desc <= x"02"; -- CAPTURE_OR_HYPERRAM_WRITE
                        error_detail_desc <= x"00";
                        gap_count <= 0;
                        error_reg <= '1';
                        ctrl_state <= C_ERROR_GAP;
                    elsif frame_available_i = '1' then
                        packet_kind_desc <= PKT_STAGE;
                        packet_seq_desc <= (others => '0');
                        packet_len_desc <= to_unsigned(2, 16);
                        stage_code_desc <= x"03"; -- FRAME_STORED
                        stage_detail_desc <= x"00";
                        packet_start_reg <= '1';
                        ctrl_state <= C_FRAME_STORED_PACKET;
                    elsif stage_timer = G_FRAME_TIMEOUT_CYCLES - 1 then
                        packet_kind_desc <= PKT_ERROR;
                        packet_seq_desc <= (others => '0');
                        packet_len_desc <= to_unsigned(16, 16);
                        error_code_desc <= x"03"; -- STAGE_TIMEOUT
                        error_detail_desc <= x"02"; -- frame capture/write
                        gap_count <= 0;
                        error_reg <= '1';
                        ctrl_state <= C_ERROR_GAP;
                    else
                        stage_timer <= stage_timer + 1;
                    end if;

                when C_FRAME_STORED_PACKET =>
                    if packet_done_reg = '1' then
                        gap_count <= 0;
                        ctrl_state <= C_GAP_TO_READY;
                    end if;

                when C_GAP_TO_READY =>
                    if gap_count = G_PACKET_GAP_CYCLES - 1 then
                        gap_count <= 0;
                        packet_kind_desc <= PKT_READY;
                        packet_seq_desc <= (others => '0');
                        packet_len_desc <= to_unsigned(6, 16);
                        packet_start_reg <= '1';
                        ctrl_state <= C_READY_PACKET;
                    else
                        gap_count <= gap_count + 1;
                    end if;

                when C_READY_PACKET =>
                    if packet_done_reg = '1' then
                        gap_count <= 0;
                        ctrl_state <= C_GAP_TO_FIRST_LINE;
                    end if;

                when C_GAP_TO_FIRST_LINE =>
                    if readout_error_i = '1' then
                        packet_kind_desc <= PKT_ERROR;
                        packet_seq_desc <= to_unsigned(line_index_reg, 16);
                        packet_len_desc <= to_unsigned(16, 16);
                        error_code_desc <= x"04"; -- HYPERRAM_READ_OR_SERIALIZER
                        error_detail_desc <= x"00";
                        gap_count <= 0;
                        error_reg <= '1';
                        ctrl_state <= C_ERROR_GAP;
                    elsif gap_count = G_PACKET_GAP_CYCLES - 1 then
                        gap_count <= 0;
                        packet_kind_desc <= PKT_LINE;
                        packet_seq_desc <= to_unsigned(line_index_reg, 16);
                        packet_len_desc <= C_LINE_BYTES_U16;
                        packet_start_reg <= '1';
                        line_start_reg <= '1';
                        ctrl_state <= C_LINE_PACKET;
                    else
                        gap_count <= gap_count + 1;
                    end if;

                when C_LINE_PACKET =>
                    if source_fault_reg = '1' then
                        packet_kind_desc <= PKT_ERROR;
                        packet_seq_desc <= to_unsigned(line_index_reg, 16);
                        packet_len_desc <= to_unsigned(16, 16);
                        error_code_desc <= source_fault_code;
                        error_detail_desc <= std_logic_vector(to_unsigned(line_index_reg mod 256, 8));
                        gap_count <= 0;
                        error_reg <= '1';
                        ctrl_state <= C_ERROR_GAP;
                    elsif packet_done_reg = '1' then
                        -- Local ACK only: the physical UART stop bit is complete.
                        line_ack_reg <= '1';
                        if line_index_reg = G_FRAME_HEIGHT - 1 then
                            gap_count <= 0;
                            ctrl_state <= C_GAP_TO_DONE;
                        else
                            line_index_reg <= line_index_reg + 1;
                            gap_count <= 0;
                            ctrl_state <= C_GAP_TO_NEXT_LINE;
                        end if;
                    end if;

                when C_GAP_TO_NEXT_LINE =>
                    if readout_error_i = '1' then
                        packet_kind_desc <= PKT_ERROR;
                        packet_seq_desc <= to_unsigned(line_index_reg, 16);
                        packet_len_desc <= to_unsigned(16, 16);
                        error_code_desc <= x"04";
                        error_detail_desc <= std_logic_vector(to_unsigned(line_index_reg mod 256, 8));
                        gap_count <= 0;
                        error_reg <= '1';
                        ctrl_state <= C_ERROR_GAP;
                    elsif gap_count = G_PACKET_GAP_CYCLES - 1 then
                        gap_count <= 0;
                        packet_kind_desc <= PKT_LINE;
                        packet_seq_desc <= to_unsigned(line_index_reg, 16);
                        packet_len_desc <= C_LINE_BYTES_U16;
                        packet_start_reg <= '1';
                        line_start_reg <= '1';
                        ctrl_state <= C_LINE_PACKET;
                    else
                        gap_count <= gap_count + 1;
                    end if;

                when C_GAP_TO_DONE =>
                    if readout_error_i = '1' then
                        packet_kind_desc <= PKT_ERROR;
                        packet_seq_desc <= to_unsigned(line_index_reg, 16);
                        packet_len_desc <= to_unsigned(16, 16);
                        error_code_desc <= x"04";
                        error_detail_desc <= x"FF";
                        gap_count <= 0;
                        error_reg <= '1';
                        ctrl_state <= C_ERROR_GAP;
                    elsif gap_count = G_PACKET_GAP_CYCLES - 1 then
                        gap_count <= 0;
                        if (serializer_done_i = '1') and (telemetry_ready_i = '1') then
                            packet_kind_desc <= PKT_DONE;
                            packet_seq_desc <= C_HEIGHT_U16;
                            packet_len_desc <= C_DONE_BYTES_U16;
                            packet_start_reg <= '1';
                            ctrl_state <= C_DONE_PACKET;
                        else
                            stage_timer <= 0;
                            ctrl_state <= C_WAIT_SERIALIZER_DONE;
                        end if;
                    else
                        gap_count <= gap_count + 1;
                    end if;

                when C_ERROR_GAP =>
                    -- Start counting only after the UART is physically idle.
                    -- This also gives a truncated LINE packet a quiet interval.
                    if tx_ready_i = '1' then
                        if gap_count = G_PACKET_GAP_CYCLES - 1 then
                            gap_count <= 0;
                            packet_start_reg <= '1';
                            ctrl_state <= C_ERROR_PACKET;
                        else
                            gap_count <= gap_count + 1;
                        end if;
                    else
                        gap_count <= 0;
                    end if;

                when C_WAIT_SERIALIZER_DONE =>
                    if readout_error_i = '1' then
                        packet_kind_desc <= PKT_ERROR;
                        packet_seq_desc <= to_unsigned(line_index_reg, 16);
                        packet_len_desc <= to_unsigned(16, 16);
                        error_code_desc <= x"04";
                        error_detail_desc <= x"FF"; -- serializer completion timeout/error
                        gap_count <= 0;
                        error_reg <= '1';
                        ctrl_state <= C_ERROR_GAP;
                    elsif (serializer_done_i = '1') and (telemetry_ready_i = '1') then
                        packet_kind_desc <= PKT_DONE;
                        packet_seq_desc <= C_HEIGHT_U16;
                        packet_len_desc <= C_DONE_BYTES_U16;
                        packet_start_reg <= '1';
                        ctrl_state <= C_DONE_PACKET;
                    elsif stage_timer = G_SOURCE_TIMEOUT_CYCLES - 1 then
                        packet_kind_desc <= PKT_ERROR;
                        packet_seq_desc <= to_unsigned(line_index_reg, 16);
                        packet_len_desc <= to_unsigned(16, 16);
                        error_code_desc <= x"04";
                        error_detail_desc <= x"FE"; -- serializer completion timeout
                        gap_count <= 0;
                        error_reg <= '1';
                        ctrl_state <= C_ERROR_GAP;
                    else
                        stage_timer <= stage_timer + 1;
                    end if;

                when C_DONE_PACKET =>
                    if packet_done_reg = '1' then
                        done_reg <= '1';
                        ctrl_state <= C_DONE;
                    end if;

                when C_ERROR_PACKET =>
                    if packet_done_reg = '1' then
                        ctrl_state <= C_ERROR;
                    end if;

                when C_DONE =>
                    ctrl_state <= C_DONE;

                when C_ERROR =>
                    ctrl_state <= C_ERROR;

                when others =>
                    error_reg <= '1';
                    ctrl_state <= C_ERROR;
            end case;
        end if;
    end process;

    -- Byte transmitter. In TX_WAIT_UART_IDLE, wait for the final UART stop bit
    -- before signaling packet completion or starting the 20 ms quiet interval.
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            tx_state          <= TX_IDLE;
            tx_kind           <= PKT_STAGE;
            tx_seq            <= (others => '0');
            tx_length         <= (others => '0');
            tx_payload_index  <= 0;
            tx_stage_code     <= (others => '0');
            tx_stage_detail   <= (others => '0');
            tx_error_code     <= (others => '0');
            tx_error_detail   <= (others => '0');
            crc_reg           <= x"FFFF";
            tx_data_reg       <= (others => '0');
            tx_valid_reg      <= '0';
            packet_done_reg   <= '0';
            source_fault_reg  <= '0';
            source_fault_code <= x"05";
            source_timer      <= 0;
        elsif rising_edge(clk) then
            packet_done_reg  <= '0';
            source_fault_reg <= '0';

            if (tx_state = TX_IDLE) and (packet_start_reg = '1') then
                tx_kind           <= packet_kind_desc;
                tx_seq            <= packet_seq_desc;
                tx_length         <= packet_len_desc;
                tx_stage_code     <= stage_code_desc;
                tx_stage_detail   <= stage_detail_desc;
                tx_error_code     <= error_code_desc;
                tx_error_detail   <= error_detail_desc;
                tx_payload_index  <= 0;
                crc_reg           <= x"FFFF";
                source_timer      <= 0;
                tx_state          <= TX_SOF_0;

            elsif tx_valid_reg = '1' then
                if tx_ready_i = '1' then
                    tx_valid_reg <= '0';
                    case tx_state is
                        when TX_SOF_0 =>
                            tx_state <= TX_SOF_1;
                        when TX_SOF_1 =>
                            tx_state <= TX_TYPE;
                        when TX_TYPE =>
                            crc_reg <= crc16_update(crc_reg, tx_data_reg);
                            tx_state <= TX_SEQ_LO;
                        when TX_SEQ_LO =>
                            crc_reg <= crc16_update(crc_reg, tx_data_reg);
                            tx_state <= TX_SEQ_HI;
                        when TX_SEQ_HI =>
                            crc_reg <= crc16_update(crc_reg, tx_data_reg);
                            tx_state <= TX_LEN_LO;
                        when TX_LEN_LO =>
                            crc_reg <= crc16_update(crc_reg, tx_data_reg);
                            tx_state <= TX_LEN_HI;
                        when TX_LEN_HI =>
                            crc_reg <= crc16_update(crc_reg, tx_data_reg);
                            tx_payload_index <= 0;
                            tx_state <= TX_PAYLOAD;
                        when TX_PAYLOAD =>
                            crc_reg <= crc16_update(crc_reg, tx_data_reg);
                            if tx_payload_index = (to_integer(tx_length) - 1) then
                                tx_state <= TX_CRC_HI;
                            else
                                tx_payload_index <= tx_payload_index + 1;
                            end if;
                        when TX_CRC_HI =>
                            tx_state <= TX_CRC_LO;
                        when TX_CRC_LO =>
                            tx_state <= TX_WAIT_UART_IDLE;
                        when others =>
                            null;
                    end case;
                end if;

            else
                case tx_state is
                    when TX_IDLE =>
                        null;
                    when TX_SOF_0 =>
                        tx_data_reg <= x"A5";
                        tx_valid_reg <= '1';
                    when TX_SOF_1 =>
                        tx_data_reg <= x"5A";
                        tx_valid_reg <= '1';
                    when TX_TYPE =>
                        case tx_kind is
                            when PKT_STAGE => tx_data_reg <= C_TYPE_STAGE;
                            when PKT_READY => tx_data_reg <= C_TYPE_READY;
                            when PKT_LINE  => tx_data_reg <= C_TYPE_LINE;
                            when PKT_DONE  => tx_data_reg <= C_TYPE_DONE;
                            when PKT_ERROR => tx_data_reg <= C_TYPE_ERROR;
                        end case;
                        tx_valid_reg <= '1';
                    when TX_SEQ_LO =>
                        tx_data_reg <= std_logic_vector(tx_seq(7 downto 0));
                        tx_valid_reg <= '1';
                    when TX_SEQ_HI =>
                        tx_data_reg <= std_logic_vector(tx_seq(15 downto 8));
                        tx_valid_reg <= '1';
                    when TX_LEN_LO =>
                        tx_data_reg <= std_logic_vector(tx_length(7 downto 0));
                        tx_valid_reg <= '1';
                    when TX_LEN_HI =>
                        tx_data_reg <= std_logic_vector(tx_length(15 downto 8));
                        tx_valid_reg <= '1';
                    when TX_PAYLOAD =>
                        if tx_kind = PKT_LINE then
                            if readout_error_i = '1' then
                                source_fault_reg <= '1';
                                source_fault_code <= x"04";
                                source_timer <= 0;
                                tx_state <= TX_IDLE;
                            elsif (src_valid_i = '1') and (src_ready_int = '1') then
                                tx_data_reg <= src_data_i;
                                tx_valid_reg <= '1';
                                source_timer <= 0;
                            elsif tx_ready_i = '1' then
                                if source_timer = G_SOURCE_TIMEOUT_CYCLES - 1 then
                                    source_fault_reg <= '1';
                                    source_fault_code <= x"05";
                                    source_timer <= 0;
                                    tx_state <= TX_IDLE;
                                else
                                    source_timer <= source_timer + 1;
                                end if;
                            else
                                source_timer <= 0;
                            end if;
                        else
                            source_timer <= 0;
                            case tx_kind is
                                when PKT_STAGE =>
                                    if tx_payload_index = 0 then
                                        tx_data_reg <= tx_stage_code;
                                    else
                                        tx_data_reg <= tx_stage_detail;
                                    end if;
                                when PKT_READY =>
                                    case tx_payload_index is
                                        when 0 => tx_data_reg <= std_logic_vector(C_WIDTH_U16(7 downto 0));
                                        when 1 => tx_data_reg <= std_logic_vector(C_WIDTH_U16(15 downto 8));
                                        when 2 => tx_data_reg <= std_logic_vector(C_HEIGHT_U16(7 downto 0));
                                        when 3 => tx_data_reg <= std_logic_vector(C_HEIGHT_U16(15 downto 8));
                                        when 4 => tx_data_reg <= x"03";
                                        when others => tx_data_reg <= x"01";
                                    end case;
                                when PKT_DONE =>
                                    case tx_payload_index is
                                        when 0  => tx_data_reg <= std_logic_vector(C_HEIGHT_U16(7 downto 0));
                                        when 1  => tx_data_reg <= std_logic_vector(C_HEIGHT_U16(15 downto 8));
                                        when 2  => tx_data_reg <= std_logic_vector(lines_sent_i(7 downto 0));
                                        when 3  => tx_data_reg <= std_logic_vector(lines_sent_i(15 downto 8));
                                        when 4  => tx_data_reg <= std_logic_vector(pixel_count_i(7 downto 0));
                                        when 5  => tx_data_reg <= std_logic_vector(pixel_count_i(15 downto 8));
                                        when 6  => tx_data_reg <= std_logic_vector(pixel_count_i(23 downto 16));
                                        when 7  => tx_data_reg <= std_logic_vector(pixel_count_i(31 downto 24));
                                        when 8  => tx_data_reg <= std_logic_vector(uart_byte_count_i(7 downto 0));
                                        when 9  => tx_data_reg <= std_logic_vector(uart_byte_count_i(15 downto 8));
                                        when 10 => tx_data_reg <= std_logic_vector(uart_byte_count_i(23 downto 16));
                                        when 11 => tx_data_reg <= std_logic_vector(uart_byte_count_i(31 downto 24));
                                        when 12 => tx_data_reg <= readback_crc_i(7 downto 0);
                                        when 13 => tx_data_reg <= readback_crc_i(15 downto 8);
                                        when 14 => tx_data_reg <= readback_crc_i(23 downto 16);
                                        when 15 => tx_data_reg <= readback_crc_i(31 downto 24);
                                        when 16 => tx_data_reg <= capture_crc_i(7 downto 0);
                                        when 17 => tx_data_reg <= capture_crc_i(15 downto 8);
                                        when 18 => tx_data_reg <= capture_crc_i(23 downto 16);
                                        when 19 => tx_data_reg <= capture_crc_i(31 downto 24);
                                        when 20 => tx_data_reg <= write_crc_i(7 downto 0);
                                        when 21 => tx_data_reg <= write_crc_i(15 downto 8);
                                        when 22 => tx_data_reg <= write_crc_i(23 downto 16);
                                        when 23 => tx_data_reg <= write_crc_i(31 downto 24);
                                        when 24 => tx_data_reg <= read_ingress_crc_i(7 downto 0);
                                        when 25 => tx_data_reg <= read_ingress_crc_i(15 downto 8);
                                        when 26 => tx_data_reg <= read_ingress_crc_i(23 downto 16);
                                        when 27 => tx_data_reg <= read_ingress_crc_i(31 downto 24);
                                        when 28 => tx_data_reg <= std_logic_vector(source_byte_count_i(7 downto 0));
                                        when 29 => tx_data_reg <= std_logic_vector(source_byte_count_i(15 downto 8));
                                        when 30 => tx_data_reg <= std_logic_vector(source_byte_count_i(23 downto 16));
                                        when 31 => tx_data_reg <= std_logic_vector(source_byte_count_i(31 downto 24));
                                        when 32 => tx_data_reg <= std_logic_vector(capture_byte_count_i(7 downto 0));
                                        when 33 => tx_data_reg <= std_logic_vector(capture_byte_count_i(15 downto 8));
                                        when 34 => tx_data_reg <= std_logic_vector(capture_byte_count_i(23 downto 16));
                                        when 35 => tx_data_reg <= std_logic_vector(capture_byte_count_i(31 downto 24));
                                        when 36 => tx_data_reg <= std_logic_vector(write_word_count_i(7 downto 0));
                                        when 37 => tx_data_reg <= std_logic_vector(write_word_count_i(15 downto 8));
                                        when 38 => tx_data_reg <= std_logic_vector(write_word_count_i(23 downto 16));
                                        when 39 => tx_data_reg <= std_logic_vector(write_word_count_i(31 downto 24));
                                        when 40 => tx_data_reg <= std_logic_vector(read_ingress_word_count_i(7 downto 0));
                                        when 41 => tx_data_reg <= std_logic_vector(read_ingress_word_count_i(15 downto 8));
                                        when 42 => tx_data_reg <= std_logic_vector(read_ingress_word_count_i(23 downto 16));
                                        when 43 => tx_data_reg <= std_logic_vector(read_ingress_word_count_i(31 downto 24));
                                        when 44 => tx_data_reg <= status_flags_i(7 downto 0);
                                        when others => tx_data_reg <= status_flags_i(15 downto 8);
                                    end case;
                                when PKT_ERROR =>
                                    case tx_payload_index is
                                        when 0  => tx_data_reg <= tx_error_code;
                                        when 1  => tx_data_reg <= tx_error_detail;
                                        when 2  => tx_data_reg <= "000" & camera_cfg_state_i;
                                        when 3  => tx_data_reg <= "0000" & camera_cfg_error_i;
                                        when 4  => tx_data_reg <= camera_cfg_reg_addr_i;
                                        when 5  => tx_data_reg <= camera_cfg_reg_data_i;
                                        when 6  => tx_data_reg <= '0' & camera_cfg_device_i;
                                        when 7  => tx_data_reg <= camera_cfg_chip_id_i;
                                        when 8  => tx_data_reg <= "000000" & camera_cfg_ack_count_i;
                                        when 9  => tx_data_reg <= "0000000" & camera_cfg_nack_i;
                                        when 10 => tx_data_reg <= camera_cfg_init_index_i;
                                        when 11 => tx_data_reg <= "0000" & camera_cfg_verify_index_i;
                                        when 12 => tx_data_reg <= "000000" & camera_i2c_sequence_i;
                                        when 13 => tx_data_reg <= "0000" & camera_i2c_state_i;
                                        when 14 => tx_data_reg <= camera_cfg_last_read_i;
                                        when others => tx_data_reg <= "0000000" & camera_cfg_rw_i;
                                    end case;
                                when PKT_LINE =>
                                    tx_data_reg <= (others => '0');
                            end case;
                            tx_valid_reg <= '1';
                        end if;
                    when TX_CRC_HI =>
                        tx_data_reg <= std_logic_vector(crc_reg(15 downto 8));
                        tx_valid_reg <= '1';
                    when TX_CRC_LO =>
                        tx_data_reg <= std_logic_vector(crc_reg(7 downto 0));
                        tx_valid_reg <= '1';
                    when TX_WAIT_UART_IDLE =>
                        if tx_ready_i = '1' then
                            packet_done_reg <= '1';
                            tx_state <= TX_IDLE;
                        end if;
                end case;
            end if;
        end if;
    end process;
end architecture;
