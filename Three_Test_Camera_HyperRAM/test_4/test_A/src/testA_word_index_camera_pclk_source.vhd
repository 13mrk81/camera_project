
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- ============================================================================
-- Module : test3_pattern_camera_pclk_source
-- Purpose:
--   Generate a deterministic 32-bit word-index pattern using real GC0308
--   PCLK timing.
--
-- Pattern:
--   word[n] = 0xA5000000 XOR n
--
-- Each 32-bit word is serialized MSB first into four consecutive bytes.
--
-- Example:
--   word[0] = 0xA5000000
--   word[1] = 0xA5000001
--   word[2] = 0xA5000002
--
-- The pattern allows MATLAB to identify the expected logical word index
-- after HyperRAM readback.
--
-- Timing:
--   Input byte-valid, frame-done and frame-error signals are delayed by
--   G_DELAY_CYCLES PCLK cycles.
--
-- Notes:
--   - The byte index advances only on source_byte_valid_i.
--   - Frame timing is inherited from the real camera interface.
--   - The module does not generate or modify camera timing.
-- ============================================================================

entity test3_pattern_camera_pclk_source is
    generic (
        G_DELAY_CYCLES : natural := 2
    );
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
end entity test3_pattern_camera_pclk_source;


architecture rtl of test3_pattern_camera_pclk_source is

    --------------------------------------------------------------------------
    -- Pipeline declarations
    --------------------------------------------------------------------------

    type byte_pipe_t is array (natural range <>) of
        std_logic_vector(7 downto 0);

    signal data_pipe  : byte_pipe_t(0 to G_DELAY_CYCLES) :=
                        (others => (others => '0'));

    signal valid_pipe : std_logic_vector(0 to G_DELAY_CYCLES) :=
                         (others => '0');

    signal done_pipe  : std_logic_vector(0 to G_DELAY_CYCLES) :=
                         (others => '0');

    signal error_pipe : std_logic_vector(0 to G_DELAY_CYCLES) :=
                         (others => '0');


    --------------------------------------------------------------------------
    -- Logical byte index within the frame
    --------------------------------------------------------------------------

    signal byte_index : unsigned(31 downto 0) := (others => '0');


    --------------------------------------------------------------------------
    -- Deterministic word-index pattern generator
    --
    -- Four consecutive bytes form one 32-bit word:
    --
    --   word_index = byte_index / 4
    --   word_value = 0xA5000000 XOR word_index
    --
    -- Byte order: MSB first.
    --------------------------------------------------------------------------

    function pattern_byte(
        index : unsigned(31 downto 0)
    ) return std_logic_vector is

        variable word_index : unsigned(31 downto 0);
        variable word_value : std_logic_vector(31 downto 0);

    begin

        word_index := shift_right(index, 2);

        word_value :=
            x"A5000000" xor std_logic_vector(word_index);

        case index(1 downto 0) is

            when "00" =>
                return word_value(31 downto 24);

            when "01" =>
                return word_value(23 downto 16);

            when "10" =>
                return word_value(15 downto 8);

            when others =>
                return word_value(7 downto 0);

        end case;

    end function;

begin

    --------------------------------------------------------------------------
    -- Configuration check
    --------------------------------------------------------------------------

    assert G_DELAY_CYCLES >= 1
        report "Test A pattern source requires at least one PCLK delay cycle."
        severity failure;


    --------------------------------------------------------------------------
    -- Pattern generation and timing pipeline
    --------------------------------------------------------------------------

    process(cam_pclk, rst_n)
    begin

        if rst_n = '0' then

            data_pipe  <= (others => (others => '0'));
            valid_pipe <= (others => '0');
            done_pipe  <= (others => '0');
            error_pipe <= (others => '0');

            byte_index <= (others => '0');

        elsif rising_edge(cam_pclk) then

            --------------------------------------------------------------
            -- Input timing capture
            --------------------------------------------------------------

            valid_pipe(0) <= source_byte_valid_i;
            done_pipe(0)  <= source_frame_done_i;
            error_pipe(0) <= source_frame_error_i;

            --------------------------------------------------------------
            -- Generate one pattern byte for each valid camera byte
            --------------------------------------------------------------

            if source_byte_valid_i = '1' then

                data_pipe(0) <= pattern_byte(byte_index);
                byte_index   <= byte_index + 1;

            end if;

            --------------------------------------------------------------
            -- Delay data and control signals together
            --------------------------------------------------------------

            for i in 1 to G_DELAY_CYCLES loop

                data_pipe(i)  <= data_pipe(i - 1);
                valid_pipe(i) <= valid_pipe(i - 1);
                done_pipe(i)  <= done_pipe(i - 1);
                error_pipe(i) <= error_pipe(i - 1);

            end loop;

        end if;

    end process;


    --------------------------------------------------------------------------
    -- Output assignments
    --------------------------------------------------------------------------

    synthetic_byte_o  <= data_pipe(G_DELAY_CYCLES);
    synthetic_valid_o <= valid_pipe(G_DELAY_CYCLES);

    frame_done_o  <= done_pipe(G_DELAY_CYCLES);
    frame_error_o <= error_pipe(G_DELAY_CYCLES);

end architecture rtl;