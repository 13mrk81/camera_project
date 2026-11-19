library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Dual-clock, 32-bit asynchronous FIFO.
-- Read interface is registered: rd_valid_o pulses one read-clock after an
-- accepted rd_en_i edge; rd_data_o is valid while rd_valid_o is high.
entity async_fifo_32 is
    generic (
        G_ADDR_BITS : positive := 9
    );
    port (
        wr_rst_n    : in  std_logic;
        rd_rst_n    : in  std_logic;
        wr_clk      : in  std_logic;
        wr_en_i     : in  std_logic;
        wr_data_i   : in  std_logic_vector(31 downto 0);
        wr_full_o   : out std_logic;
        wr_level_o  : out unsigned(G_ADDR_BITS downto 0);

        rd_clk      : in  std_logic;
        rd_en_i     : in  std_logic;
        rd_data_o   : out std_logic_vector(31 downto 0);
        rd_valid_o  : out std_logic;
        rd_empty_o  : out std_logic;
        rd_level_o  : out unsigned(G_ADDR_BITS downto 0)
    );
end entity;

architecture rtl of async_fifo_32 is
    constant C_DEPTH : positive := 2 ** G_ADDR_BITS;
    subtype ptr_t is unsigned(G_ADDR_BITS downto 0);
    type mem_t is array (0 to C_DEPTH - 1) of std_logic_vector(31 downto 0);
    signal mem : mem_t;

    function bin_to_gray(b : ptr_t) return ptr_t is
    begin
        return b xor shift_right(b, 1);
    end function;

    function gray_to_bin(g : ptr_t) return ptr_t is
        variable b : ptr_t := (others => '0');
    begin
        b(b'high) := g(g'high);
        for i in b'high - 1 downto 0 loop
            b(i) := b(i + 1) xor g(i);
        end loop;
        return b;
    end function;

    signal wr_bin       : ptr_t := (others => '0');
    signal wr_gray      : ptr_t := (others => '0');
    signal rd_bin       : ptr_t := (others => '0');
    signal rd_gray      : ptr_t := (others => '0');
    signal rd_gray_w1   : ptr_t := (others => '0');
    signal rd_gray_w2   : ptr_t := (others => '0');
    signal wr_gray_r1   : ptr_t := (others => '0');
    signal wr_gray_r2   : ptr_t := (others => '0');
    signal full_reg     : std_logic := '0';
    signal empty_int    : std_logic;
    signal wr_bin_sync  : ptr_t;
    signal rd_data_reg  : std_logic_vector(31 downto 0) := (others => '0');
    signal rd_valid_reg : std_logic := '0';
    attribute async_reg : string;
    attribute async_reg of rd_gray_w1 : signal is "true";
    attribute async_reg of rd_gray_w2 : signal is "true";
    attribute async_reg of wr_gray_r1 : signal is "true";
    attribute async_reg of wr_gray_r2 : signal is "true";
begin
    assert G_ADDR_BITS >= 2
        report "async_fifo_32 requires G_ADDR_BITS >= 2"
        severity failure;

    process(wr_clk, wr_rst_n)
        variable next_bin     : ptr_t;
        variable next_gray    : ptr_t;
        variable full_compare : ptr_t;
    begin
        if wr_rst_n = '0' then
            wr_bin     <= (others => '0');
            wr_gray    <= (others => '0');
            rd_gray_w1 <= (others => '0');
            rd_gray_w2 <= (others => '0');
            full_reg   <= '0';
        elsif rising_edge(wr_clk) then
            rd_gray_w1 <= rd_gray;
            rd_gray_w2 <= rd_gray_w1;
            next_bin := wr_bin;

            if (wr_en_i = '1') and (full_reg = '0') then
                mem(to_integer(wr_bin(G_ADDR_BITS - 1 downto 0))) <= wr_data_i;
                next_bin := wr_bin + 1;
            end if;

            next_gray := bin_to_gray(next_bin);
            wr_bin  <= next_bin;
            wr_gray <= next_gray;

            full_compare := rd_gray_w2;
            full_compare(G_ADDR_BITS downto G_ADDR_BITS - 1) :=
                not rd_gray_w2(G_ADDR_BITS downto G_ADDR_BITS - 1);
            if next_gray = full_compare then
                full_reg <= '1';
            else
                full_reg <= '0';
            end if;
        end if;
    end process;

    process(rd_clk, rd_rst_n)
    begin
        if rd_rst_n = '0' then
            rd_bin       <= (others => '0');
            rd_gray      <= (others => '0');
            wr_gray_r1   <= (others => '0');
            wr_gray_r2   <= (others => '0');
            rd_data_reg  <= (others => '0');
            rd_valid_reg <= '0';
        elsif rising_edge(rd_clk) then
            wr_gray_r1   <= wr_gray;
            wr_gray_r2   <= wr_gray_r1;
            rd_valid_reg <= '0';
            if (rd_en_i = '1') and (empty_int = '0') then
                rd_data_reg  <= mem(to_integer(rd_bin(G_ADDR_BITS - 1 downto 0)));
                rd_bin       <= rd_bin + 1;
                rd_gray      <= bin_to_gray(rd_bin + 1);
                rd_valid_reg <= '1';
            end if;
        end if;
    end process;

    empty_int   <= '1' when rd_gray = wr_gray_r2 else '0';
    wr_bin_sync <= gray_to_bin(wr_gray_r2);
    wr_full_o   <= full_reg;
    wr_level_o  <= wr_bin - gray_to_bin(rd_gray_w2);
    rd_empty_o  <= empty_int;
    rd_data_o   <= rd_data_reg;
    rd_valid_o  <= rd_valid_reg;
    rd_level_o  <= wr_bin_sync - rd_bin;
end architecture;
