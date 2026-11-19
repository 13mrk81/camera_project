library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_rgb565_frame_packer is
end entity;

architecture sim of tb_rgb565_frame_packer is
    signal cam_pclk          : std_logic := '0';
    signal rst_n             : std_logic := '0';
    signal cam_byte_i        : std_logic_vector(7 downto 0) := (others => '0');
    signal cam_byte_valid_i  : std_logic := '0';
    signal cam_frame_done_i  : std_logic := '0';
    signal cam_frame_error_i : std_logic := '0';
    signal packed_word_o     : std_logic_vector(31 downto 0);
    signal packed_valid_o    : std_logic;
    signal capture_done_o    : std_logic;
    signal capture_error_o   : std_logic;
    signal capture_crc_o     : std_logic_vector(31 downto 0);
    signal byte_count_o      : unsigned(31 downto 0);
    signal word_count_o      : unsigned(31 downto 0);
begin
    cam_pclk <= not cam_pclk after 5 ns;

    dut : entity work.rgb565_frame_packer
        generic map (
            G_FRAME_WIDTH  => 2,
            G_FRAME_HEIGHT => 2
        )
        port map (
            cam_pclk          => cam_pclk,
            rst_n             => rst_n,
            cam_byte_i        => cam_byte_i,
            cam_byte_valid_i  => cam_byte_valid_i,
            cam_frame_done_i  => cam_frame_done_i,
            cam_frame_error_i => cam_frame_error_i,
            packed_word_o     => packed_word_o,
            packed_valid_o    => packed_valid_o,
            capture_done_o    => capture_done_o,
            capture_error_o   => capture_error_o,
            capture_crc_o     => capture_crc_o,
            byte_count_o      => byte_count_o,
            word_count_o      => word_count_o
        );

    stimulus : process
        procedure send_byte(constant value : std_logic_vector(7 downto 0)) is
        begin
            wait until falling_edge(cam_pclk);
            cam_byte_i <= value;
            cam_byte_valid_i <= '1';
            wait until rising_edge(cam_pclk);
            wait for 1 ns;
            wait until falling_edge(cam_pclk);
            cam_byte_valid_i <= '0';
        end procedure;
    begin
        rst_n <= '0';
        wait for 30 ns;
        wait until falling_edge(cam_pclk);
        rst_n <= '1';

        -- RGB565 reference colors, sent in GC0308 DVP big-endian order:
        -- Red   = F800 -> F8 00
        -- Green = 07E0 -> 07 E0
        -- Blue  = 001F -> 00 1F
        -- White = FFFF -> FF FF
        send_byte(x"F8");
        send_byte(x"00");
        send_byte(x"07");
        send_byte(x"E0");

        assert packed_valid_o = '1'
            report "First 32-bit word was not produced after four bytes"
            severity failure;
        assert packed_word_o = x"F80007E0"
            report "RGB565 BE mapping failed for red/green pixels"
            severity failure;

        wait until rising_edge(cam_pclk);
        wait for 1 ns;
        assert packed_valid_o = '0'
            report "packed_valid_o must be a one-clock pulse"
            severity failure;

        send_byte(x"00");
        send_byte(x"1F");
        send_byte(x"FF");
        send_byte(x"FF");

        assert packed_valid_o = '1'
            report "Second 32-bit word was not produced after four bytes"
            severity failure;
        assert packed_word_o = x"001FFFFF"
            report "RGB565 BE mapping failed for blue/white pixels"
            severity failure;

        cam_frame_done_i <= '1';
        wait until rising_edge(cam_pclk);
        wait for 1 ns;
        cam_frame_done_i <= '0';

        assert capture_done_o = '1'
            report "Frame-done indication was not asserted"
            severity failure;
        assert capture_error_o = '0'
            report "Valid two-line RGB565 test frame raised capture_error"
            severity failure;
        assert byte_count_o = to_unsigned(8, 32)
            report "Unexpected captured byte count"
            severity failure;
        assert word_count_o = to_unsigned(2, 32)
            report "Unexpected packed word count"
            severity failure;

        report "PASS: GC0308 RGB565 big-endian byte packing verified"
            severity note;
        wait;
    end process;
end architecture;
