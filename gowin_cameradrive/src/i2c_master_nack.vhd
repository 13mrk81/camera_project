library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity i2c_master_nack is
    generic (
        G_CLK_FREQ_HZ : positive := 24_000_000;
        G_I2C_FREQ_HZ : positive := 100_000
    );
    port (
        clk       : in  std_logic;
        rst_n     : in  std_logic; -- Active-low reset

        start     : in  std_logic; -- One-clock pulse while busy='0'
        rw        : in  std_logic; -- '0' = write, '1' = register read
        dev_addr  : in  std_logic_vector(6 downto 0);
        reg_addr  : in  std_logic_vector(7 downto 0);
        wr_data   : in  std_logic_vector(7 downto 0);

        rd_data   : out std_logic_vector(7 downto 0);
        ack_out   : out std_logic; -- At least one ACK received in this transaction
        nack_seen : out std_logic; -- At least one NACK received in this transaction
        ack_count : out std_logic_vector(1 downto 0); -- Number of ACKs, saturates at 3
        busy      : out std_logic;
        done      : out std_logic; -- One-clock pulse at transaction completion

        dbg_rx    : out std_logic_vector(7 downto 0);
        dbg_shift : out std_logic_vector(7 downto 0);
        dbg_phase : out std_logic_vector(1 downto 0);
        dbg_seq   : out std_logic_vector(1 downto 0);
        dbg_state : out std_logic_vector(3 downto 0);
        dbg_sda_in : out std_logic;
        dbg_scl_low : out std_logic;
        dbg_sda_low : out std_logic;

        scl       : inout std_logic;
        sda       : inout std_logic
    );
end entity;

architecture rtl of i2c_master_nack is

    -- Four equal phase intervals form one SCL period.
    -- At 24 MHz / 100 kHz, each phase is 60 system-clock cycles.
    constant C_PHASE_CYCLES : positive := G_CLK_FREQ_HZ / (4 * G_I2C_FREQ_HZ);

    type state_t is (
        IDLE, START_COND, SEND_BYTE, RECV_ACK,
        RESTART_COND, RECV_BYTE, SEND_NACK, STOP_COND, DONE_ST
    );

    type seq_t is (SEQ_ADDR_W, SEQ_REG, SEQ_DATA_W, SEQ_ADDR_R);

    signal state : state_t := IDLE;
    signal seq   : seq_t   := SEQ_ADDR_W;

    signal phase_cnt : natural range 0 to C_PHASE_CYCLES - 1 := 0;
    signal phase     : unsigned(1 downto 0) := (others => '0');
    signal phase_tick : std_logic;

    -- A value of '1' means actively pull the corresponding bus line low.
    -- A value of '0' means release the line (high-impedance).
    signal scl_low : std_logic := '0';
    signal sda_low : std_logic := '0';
    signal sda_in  : std_logic;

    signal bit_cnt      : natural range 0 to 7 := 7;
    signal shift        : std_logic_vector(7 downto 0) := (others => '0');
    signal rx_data      : std_logic_vector(7 downto 0) := (others => '0');
    signal rd_data_reg  : std_logic_vector(7 downto 0) := (others => '0');

    signal ack_out_reg   : std_logic := '0';
    signal nack_seen_reg : std_logic := '0';
    signal ack_count_reg : unsigned(1 downto 0) := (others => '0');

    signal busy_reg : std_logic := '0';
    signal done_reg : std_logic := '0';
    signal start_ready : std_logic := '0';

begin

    phase_tick <= '1' when phase_cnt = C_PHASE_CYCLES - 1 else '0';

    -- Open-drain bus drivers. External pull-ups must bring released lines high.
    scl <= '0' when scl_low = '1' else 'Z';
    sda <= '0' when sda_low = '1' else 'Z';
    sda_in <= sda;

    rd_data   <= rd_data_reg;
    ack_out   <= ack_out_reg;
    nack_seen <= nack_seen_reg;
    ack_count <= std_logic_vector(ack_count_reg);
    busy      <= busy_reg;
    done      <= done_reg;

    dbg_rx    <= rx_data;
    dbg_shift <= shift;
    dbg_phase <= std_logic_vector(phase);
    dbg_seq   <= std_logic_vector(to_unsigned(seq_t'pos(seq), 2));
    dbg_state <= std_logic_vector(to_unsigned(state_t'pos(state), 4));
    dbg_sda_in <= sda_in;
    dbg_scl_low <= scl_low;
    dbg_sda_low <= sda_low;

    -- Free-running four-phase timing generator, matching the reference FSM.
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            phase_cnt <= 0;
            phase     <= (others => '0');
        elsif rising_edge(clk) then
            if phase_tick = '1' then
                phase_cnt <= 0;
                phase     <= phase + 1;
            else
                phase_cnt <= phase_cnt + 1;
            end if;
        end if;
    end process;

    process(clk, rst_n)
    begin
        if rst_n = '0' then
            state          <= IDLE;
            seq            <= SEQ_ADDR_W;
            scl_low        <= '0';
            sda_low        <= '0';
            bit_cnt        <= 7;
            shift          <= (others => '0');
            rx_data        <= (others => '0');
            rd_data_reg    <= (others => '0');
            ack_out_reg    <= '0';
            nack_seen_reg  <= '0';
            ack_count_reg  <= (others => '0');
            busy_reg       <= '0';
            done_reg       <= '0';
            start_ready    <= '0';

        elsif rising_edge(clk) then
            done_reg <= '0';

            case state is

                when IDLE =>
                    -- Bus idle: release both wires.
                    scl_low  <= '0';
                    sda_low  <= '0';
                    busy_reg <= '0';

                    if start = '1' then
                        busy_reg      <= '1';
                        shift         <= dev_addr & '0'; -- Address + write bit
                        seq           <= SEQ_ADDR_W;
                        bit_cnt       <= 7;
                        start_ready   <= '0';
                        ack_out_reg   <= '0';
                        nack_seen_reg <= '0';
                        ack_count_reg <= (others => '0');
                        state         <= START_COND;
                    end if;

                when START_COND =>
                    -- Wait for a phase-0 boundary, then generate START:
                    -- SDA falls while SCL is released high.
                    if start_ready = '0' then
                        if phase = "00" and phase_cnt = 0 then
                            start_ready <= '1';
                            scl_low     <= '0';
                            sda_low     <= '0';
                        end if;
                    else
                        case phase is
                            when "00" =>
                                scl_low <= '0';
                                sda_low <= '0';
                            when "01" =>
                                scl_low <= '0';
                                sda_low <= '1';
                            when "10" =>
                                scl_low <= '1';
                                sda_low <= '1';
                            when others =>
                                scl_low <= '1';
                                sda_low <= '1';
                        end case;

                        if phase_tick = '1' and phase = "11" then
                            start_ready <= '0';
                            state       <= SEND_BYTE;
                            bit_cnt     <= 7;
                        end if;
                    end if;

                when SEND_BYTE =>
                    case phase is
                        when "00" =>
                            -- SCL low; set up the next data bit.
                            scl_low <= '1';
                            sda_low <= not shift(7);
                        when "01" =>
                            scl_low <= '0';
                        when "10" =>
                            scl_low <= '0';
                        when others =>
                            scl_low <= '1';
                            if phase_tick = '1' then
                                shift <= shift(6 downto 0) & '0';
                            end if;
                    end case;

                    if phase_tick = '1' and phase = "11" then
                        if bit_cnt = 0 then
                            state <= RECV_ACK;
                        else
                            bit_cnt <= bit_cnt - 1;
                        end if;
                    end if;

                when RECV_ACK =>
                    case phase is
                        when "00" =>
                            scl_low <= '1';
                            sda_low <= '0'; -- Release SDA for slave ACK
                        when "01" =>
                            scl_low <= '0';
                        when "10" =>
                            scl_low <= '0';
                            if phase_cnt = C_PHASE_CYCLES / 2 then
                                if sda_in = '0' then
                                    ack_out_reg <= '1';
                                    if ack_count_reg /= "11" then
                                        ack_count_reg <= ack_count_reg + 1;
                                    end if;
                                else
                                    nack_seen_reg <= '1';
                                end if;
                            end if;
                        when others =>
                            scl_low <= '1';
                    end case;

                    if phase_tick = '1' and phase = "11" then
                        case seq is
                            when SEQ_ADDR_W =>
                                shift   <= reg_addr;
                                seq     <= SEQ_REG;
                                bit_cnt <= 7;
                                state   <= SEND_BYTE;

                            when SEQ_REG =>
                                if rw = '1' then
                                    state <= RESTART_COND;
                                else
                                    shift   <= wr_data;
                                    seq     <= SEQ_DATA_W;
                                    bit_cnt <= 7;
                                    state   <= SEND_BYTE;
                                end if;

                            when SEQ_DATA_W =>
                                state <= STOP_COND;

                            when SEQ_ADDR_R =>
                                state   <= RECV_BYTE;
                                bit_cnt <= 7;
                                rx_data <= (others => '0');

                        end case;
                    end if;

                when RESTART_COND =>
                    case phase is
                        when "00" =>
                            scl_low <= '1';
                            sda_low <= '0';
                        when "01" =>
                            scl_low <= '0';
                            sda_low <= '0';
                        when "10" =>
                            scl_low <= '0';
                            sda_low <= '1'; -- Repeated START while SCL high
                        when others =>
                            scl_low <= '1';
                            sda_low <= '1';
                    end case;

                    if phase_tick = '1' and phase = "11" then
                        shift   <= dev_addr & '1'; -- Address + read bit
                        seq     <= SEQ_ADDR_R;
                        bit_cnt <= 7;
                        state   <= SEND_BYTE;
                    end if;

                when RECV_BYTE =>
                    case phase is
                        when "00" =>
                            scl_low <= '1';
                            sda_low <= '0';
                        when "01" =>
                            scl_low <= '0';
                        when "10" =>
                            scl_low <= '0';
                            if phase_cnt = C_PHASE_CYCLES / 2 then
                                rx_data <= rx_data(6 downto 0) & sda_in;
                                if bit_cnt = 0 then
                                    -- Include the current (eighth) bit. Do not
                                    -- read the old rx_data value here.
                                    rd_data_reg <= rx_data(6 downto 0) & sda_in;
                                end if;
                            end if;
                        when others =>
                            scl_low <= '1';
                    end case;

                    if phase_tick = '1' and phase = "11" then
                        if bit_cnt = 0 then
                            state <= SEND_NACK;
                        else
                            bit_cnt <= bit_cnt - 1;
                        end if;
                    end if;

                when SEND_NACK =>
                    -- Master releases SDA during the ninth clock (NACK).
                    case phase is
                        when "00" =>
                            scl_low <= '1';
                            sda_low <= '0';
                        when "01" =>
                            scl_low <= '0';
                        when "10" =>
                            scl_low <= '0';
                        when others =>
                            scl_low <= '1';
                    end case;

                    if phase_tick = '1' and phase = "11" then
                        state <= STOP_COND;
                    end if;

                when STOP_COND =>
                    case phase is
                        when "00" =>
                            scl_low <= '1';
                            sda_low <= '1';
                        when "01" =>
                            scl_low <= '0';
                            sda_low <= '1';
                        when "10" =>
                            scl_low <= '0';
                            sda_low <= '0'; -- SDA rises while SCL high: STOP
                        when others =>
                            scl_low <= '0';
                            sda_low <= '0';
                    end case;

                    if phase_tick = '1' and phase = "11" then
                        state <= DONE_ST;
                    end if;

                when DONE_ST =>
                    done_reg <= '1';
                    busy_reg <= '0';
                    state    <= IDLE;

            end case;
        end if;
    end process;

end architecture;
