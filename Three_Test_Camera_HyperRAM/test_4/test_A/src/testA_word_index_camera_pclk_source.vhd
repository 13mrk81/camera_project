library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Test A: deterministic word-index pattern driven by real GC0308 timing.
-- Entity name intentionally matches the source entity instantiated by the
-- shared Test 4 top-level. This project includes this file instead of the
-- original test3_pattern_camera_pclk_source.vhd.
entity test3_pattern_camera_pclk_source is
    generic (G_DELAY_CYCLES : natural := 2);
    port (
        cam_pclk             : in  std_logic;
        rst_n                : in  std_logic;
        source_byte_valid_i  : in  std_logic;
        source_frame_done_i  : in  std_logic;
        source_frame_error_i : in  std_logic;
        synthetic_byte_o     : out std_logic_vector(7 downto 0);
        synthetic_valid_o    : out std_logic;
        frame_done_o         : out std_logic;
        frame_error_o        : out std_logic
    );
end entity;

architecture rtl of test3_pattern_camera_pclk_source is
    type byte_pipe_t is array (natural range <>) of std_logic_vector(7 downto 0);
    signal data_pipe  : byte_pipe_t(0 to G_DELAY_CYCLES) := (others => (others => '0'));
    signal valid_pipe : std_logic_vector(0 to G_DELAY_CYCLES) := (others => '0');
    signal done_pipe  : std_logic_vector(0 to G_DELAY_CYCLES) := (others => '0');
    signal error_pipe : std_logic_vector(0 to G_DELAY_CYCLES) := (others => '0');
    signal byte_index : unsigned(31 downto 0) := (others => '0');

    -- Each group of four valid camera bytes forms one unmistakable 32-bit
    -- word after rgb565_frame_packer:
    --   word[n] = 0xA5000000 XOR n
    -- The packer stores bytes MSB first, so MATLAB can reconstruct every
    -- expected 32-bit word directly from its linear word index.
    function pattern_byte(index : unsigned(31 downto 0)) return std_logic_vector is
        variable word_index : unsigned(31 downto 0);
        variable word_value : std_logic_vector(31 downto 0);
    begin
        word_index := shift_right(index, 2);
        word_value := x"A5000000" xor std_logic_vector(word_index);

        case index(1 downto 0) is
            when "00"   => return word_value(31 downto 24);
            when "01"   => return word_value(23 downto 16);
            when "10"   => return word_value(15 downto 8);
            when others => return word_value(7 downto 0);
        end case;
    end function;
begin
    assert G_DELAY_CYCLES >= 1
        report "Test A pattern source requires at least one PCLK delay cycle"
        severity failure;

    process(cam_pclk, rst_n)
    begin
        if rst_n = '0' then
            data_pipe  <= (others => (others => '0'));
            valid_pipe <= (others => '0');
            done_pipe  <= (others => '0');
            error_pipe <= (others => '0');
            byte_index <= (others => '0');
        elsif rising_edge(cam_pclk) then
            valid_pipe(0) <= source_byte_valid_i;
            done_pipe(0)  <= source_frame_done_i;
            error_pipe(0) <= source_frame_error_i;

            if source_byte_valid_i = '1' then
                data_pipe(0) <= pattern_byte(byte_index);
                byte_index   <= byte_index + 1;
            end if;

            for i in 1 to G_DELAY_CYCLES loop
                data_pipe(i)  <= data_pipe(i - 1);
                valid_pipe(i) <= valid_pipe(i - 1);
                done_pipe(i)  <= done_pipe(i - 1);
                error_pipe(i) <= error_pipe(i - 1);
            end loop;
        end if;
    end process;

    synthetic_byte_o  <= data_pipe(G_DELAY_CYCLES);
    synthetic_valid_o <= valid_pipe(G_DELAY_CYCLES);
    frame_done_o      <= done_pipe(G_DELAY_CYCLES);
    frame_error_o     <= error_pipe(G_DELAY_CYCLES);
end architecture;
