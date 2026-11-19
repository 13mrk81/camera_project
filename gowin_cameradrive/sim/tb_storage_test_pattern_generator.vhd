library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_storage_test_pattern_generator is
end entity;

architecture sim of tb_storage_test_pattern_generator is
    constant C_WIDTH       : positive := 8;
    constant C_HEIGHT      : positive := 3;
    constant C_HBLANK      : positive := 3;
    constant C_VBLANK      : positive := 12;
    constant C_FRAME_CYCLES: positive := C_HEIGHT * (C_WIDTH * 2 + C_HBLANK) + C_VBLANK;

    signal clk        : std_logic := '0';
    signal rst_n      : std_logic := '0';
    signal start      : std_logic := '0';
    signal data       : std_logic_vector(7 downto 0);
    signal valid      : std_logic;
    signal frame_done : std_logic;
    signal busy       : std_logic;
    signal error      : std_logic;
    signal byte_count : unsigned(31 downto 0);
    signal line_count : unsigned(15 downto 0);
begin
    clk <= not clk after 5 ns;

    dut : entity work.storage_test_pattern_generator
        generic map (
            G_FRAME_WIDTH => C_WIDTH,
            G_FRAME_HEIGHT => C_HEIGHT,
            G_LINE_BLANK_CYCLES => C_HBLANK,
            G_FRAME_BLANK_CYCLES => C_VBLANK
        )
        port map (
            clk_i => clk,
            rst_n_i => rst_n,
            start_i => start,
            byte_data_o => data,
            byte_valid_o => valid,
            frame_done_o => frame_done,
            busy_o => busy,
            error_o => error,
            byte_count_o => byte_count,
            line_count_o => line_count
        );

    stimulus : process
        variable accepted_bytes : natural := 0;
        variable pixel_x        : natural;
        variable pixel_y        : natural;
        variable pixel_value    : natural;
        variable expected_byte  : std_logic_vector(7 downto 0);
        variable frame_done_seen: boolean := false;
    begin
        wait for 30 ns;
        wait until rising_edge(clk);
        rst_n <= '1';
        wait until rising_edge(clk);
        start <= '1';
        wait until rising_edge(clk);
        start <= '0';

        -- First valid byte is expected on the next clock. Count every clock
        -- until the frame_done pulse and verify both active data and blanking.
        for cycle in 0 to C_FRAME_CYCLES + 4 loop
            wait until rising_edge(clk);
            wait for 1 ns;

            if cycle < C_HEIGHT * (C_WIDTH * 2 + C_HBLANK) then
                if (cycle mod (C_WIDTH * 2 + C_HBLANK)) < (C_WIDTH * 2) then
                    assert valid = '1'
                        report "Missing active byte in a line" severity failure;
                else
                    assert valid = '0'
                        report "byte_valid asserted during horizontal blanking" severity failure;
                end if;
            else
                assert valid = '0'
                    report "byte_valid asserted during vertical blanking" severity failure;
            end if;

            if valid = '1' then

                pixel_x := (accepted_bytes mod (C_WIDTH * 2)) / 2;
                pixel_y := accepted_bytes / (C_WIDTH * 2);
                pixel_value := (251 * pixel_x) + (911 * pixel_y) +
                               (13 * pixel_x * pixel_y) + 16#A65C#;
                pixel_value := pixel_value mod 65536;

                if (accepted_bytes mod 2) = 0 then
                    expected_byte := std_logic_vector(to_unsigned(pixel_value / 256, 8));
                else
                    expected_byte := std_logic_vector(to_unsigned(pixel_value mod 256, 8));
                end if;

                assert data = expected_byte
                    report "Pattern byte mismatch at byte index " &
                           integer'image(accepted_bytes) severity failure;
                accepted_bytes := accepted_bytes + 1;
            end if;

            if frame_done = '1' then
                frame_done_seen := true;
                assert cycle = C_FRAME_CYCLES - 1
                    report "Frame period does not match configured active/blanking timing" severity failure;
                assert accepted_bytes = C_WIDTH * C_HEIGHT * 2
                    report "Incorrect total number of active bytes" severity failure;
                assert byte_count = to_unsigned(C_WIDTH * C_HEIGHT * 2, 32)
                    report "byte_count_o does not match active byte count" severity failure;
                assert error = '0'
                    report "Generator asserted error during a legal test" severity failure;
                exit;
            end if;
        end loop;

        assert frame_done_seen
            report "Timed out waiting for frame_done_o" severity failure;
        report "PASS: generator byte pattern, byte count and frame completion verified."
            severity note;
        wait;
    end process;
end architecture;
