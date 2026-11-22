library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_sport_frame is end;
architecture test of tb_sport_frame is
    constant LAST : std_logic_vector(31 downto 0) := x"812458A7";
    constant FIRST : std_logic_vector(31 downto 0) := x"A90D7252";
    constant DESC : std_logic_vector(14 downto 0) := std_logic_vector(to_unsigned(204*64+16, 15));
    signal clk : std_logic := '0';
    signal rst : std_logic := '1';
    signal phase : unsigned(9 downto 0) := (others => '0');
    signal incoming, outgoing : std_logic_vector(0 downto 0) := "0";
    signal sending : std_logic_vector(0 downto 0) := "1";
    signal rw, req : std_logic;
    signal ra, ta : unsigned(8 downto 0);
    signal rx_word, tx_word : std_logic_vector(31 downto 0) := (others => '0');
    signal bclk : std_logic;
begin
    clk <= not clk after 10 ns;
    bclk <= phase(0);
    dut : entity work.tdm_frame_io
        generic map (1, 16, 0, 0, 32, DESC, DESC)
        port map (clk, rst, phase, incoming, "1", outgoing, rw, req, ra, ta,
                  rx_word, tx_word, '1', sending);
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '0' then phase <= phase + 1; end if;
            tx_word <= (others => '0');
            if req = '1' and ta = 204 then tx_word <= FIRST; end if;
            if req = '1' and ta = 219 then tx_word <= LAST; end if;
            if rw = '1' and ra = 219 and phase = 0 and now > 10 us then
                assert rx_word = LAST report "last slot capture: wrong bit or ID" severity failure;
            end if;
        end if;
    end process;
    -- Model the far end independently: drive on the SPORT rising edge,
    -- with a nonzero turnaround delay, then read on the falling edge.
    process(bclk)
        variable bit_in_frame : natural;
    begin
        if rising_edge(bclk) then
            bit_in_frame := to_integer(phase) / 2;
            if bit_in_frame >= 480 then incoming(0) <= LAST(511 - bit_in_frame) after 8 ns;
            else incoming(0) <= '0' after 8 ns; end if;
        end if;
    end process;
    process
        variable shift : std_logic_vector(31 downto 0);
    begin
        wait for 35 ns;
        rst <= '0';
        wait until phase = 1023;
        wait until falling_edge(bclk); -- last bit before the next slot 0
        for i in 31 downto 0 loop
            wait until falling_edge(bclk);
            shift(i) := outgoing(0);
        end loop;
        assert shift = FIRST report "first slot playback: wrong bit or ID" severity failure;
        wait until phase = 961; -- last slot has loaded
        for i in 31 downto 0 loop
            if i = 2 then sending <= "0"; end if;
            wait until falling_edge(bclk);
            shift(i) := outgoing(0);
        end loop;
        assert shift = LAST report "disarming truncated the last slot" severity failure;
        for i in 31 downto 0 loop
            wait until falling_edge(bclk);
            shift(i) := outgoing(0);
        end loop;
        assert shift = x"00000000" report "disarmed frame leaked data" severity failure;
        report "SPORT drive/sample edges, Q4.28 bit order, DSP3 boundary and frame mute OK";
        std.env.stop;
    end process;
end architecture;
