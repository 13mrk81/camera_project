library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- ============================================================================
-- Module : testA2_synthetic_frame_source
--
-- Purpose:
--   Generate a deterministic synthetic RGB565 byte stream using clk24.
--   The source is independent of the physical GC0308 camera interface.
--
-- Pattern:
--   word[n] = 0xA5000000 XOR n
--
--   Each 32-bit word is serialized into four consecutive bytes, MSB first.
--
-- Operation:
--   - A rising-edge pulse on start_i starts one frame.
--   - One valid byte is generated per clk24 cycle.
--   - Total frame size = G_FRAME_WIDTH * G_FRAME_HEIGHT * 2 bytes.
--   - frame_done_o is asserted after the final valid byte.
--
-- The pattern preserves the logical word index for HyperRAM readback analysis.
-- ============================================================================

entity testA2_synthetic_frame_source is
    generic (
        G_FRAME_WIDTH  : positive := 640;
        G_FRAME_HEIGHT : positive := 480
    );
    port (
        clk24             : in  std_logic;
        rst_n             : in  std_logic;
        start_i           : in  std_logic;

        synthetic_byte_o  : out std_logic_vector(7 downto 0);
        synthetic_valid_o : out std_logic;
        frame_done_o      : out std_logic;
        frame_error_o     : out std_logic
    );
end entity testA2_synthetic_frame_source;


architecture rtl of testA2_synthetic_frame_source is

    --------------------------------------------------------------------------
    -- Frame geometry
    --------------------------------------------------------------------------

    constant C_BYTES_PER_PIXEL : positive := 2;

    constant C_TOTAL_BYTES : positive :=
        G_FRAME_WIDTH * G_FRAME_HEIGHT * C_BYTES_PER_PIXEL;

    --------------------------------------------------------------------------
    -- Source control
    --------------------------------------------------------------------------

    signal source_active : std_logic := '0';

    signal byte_index : unsigned(31 downto 0) :=
        (others => '0');

    signal pending_done : std_logic := '0';

    --------------------------------------------------------------------------
    -- Registered outputs
    --------------------------------------------------------------------------

    signal synthetic_byte_reg  : std_logic_vector(7 downto 0) :=
        (others => '0');

    signal synthetic_valid_reg : std_logic := '0';
    signal frame_done_reg      : std_logic := '0';

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
    -- Configuration checks
    --------------------------------------------------------------------------

    assert C_TOTAL_BYTES <= 2**32
        report "Frame byte count exceeds the 32-bit source index range."
        severity failure;

    --------------------------------------------------------------------------
    -- Synthetic frame generator
    --------------------------------------------------------------------------

    process(clk24, rst_n)
    begin

        if rst_n = '0' then

            source_active       <= '0';
            byte_index          <= (others => '0');
            pending_done        <= '0';

            synthetic_byte_reg  <= (others => '0');
            synthetic_valid_reg <= '0';
            frame_done_reg      <= '0';

        elsif rising_edge(clk24) then

            -- Default: output control signals are pulses.
            synthetic_valid_reg <= '0';
            frame_done_reg      <= '0';

            --------------------------------------------------------------
            -- Report frame completion after the final valid byte.
            --------------------------------------------------------------

            if pending_done = '1' then

                frame_done_reg <= '1';
                pending_done   <= '0';

            --------------------------------------------------------------
            -- Generate frame data.
            --------------------------------------------------------------

            elsif source_active = '1' then

                synthetic_byte_reg  <= pattern_byte(byte_index);
                synthetic_valid_reg <= '1';

                if byte_index = to_unsigned(C_TOTAL_BYTES - 1, 32) then

                    source_active <= '0';
                    pending_done  <= '1';

                else

                    byte_index <= byte_index + 1;

                end if;

            --------------------------------------------------------------
            -- Start a new frame.
            --------------------------------------------------------------

            elsif start_i = '1' then

                byte_index    <= (others => '0');
                source_active <= '1';

            end if;

        end if;

    end process;

    --------------------------------------------------------------------------
    -- Output assignments
    --------------------------------------------------------------------------

    synthetic_byte_o  <= synthetic_byte_reg;
    synthetic_valid_o <= synthetic_valid_reg;

    frame_done_o  <= frame_done_reg;
    frame_error_o <= '0';

end architecture rtl;