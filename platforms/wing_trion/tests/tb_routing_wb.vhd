library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_routing_wb is end;
architecture test of tb_routing_wb is
    signal clk : std_logic := '0';
    signal rst : std_logic := '1';
    signal scan, cyc, wr, ack, err, ready : std_logic := '0';
    signal addr : std_logic_vector(29 downto 0) := (others => '0');
    signal di, dout : std_logic_vector(31 downto 0) := (others => '0');
    signal sel : std_logic_vector(3 downto 0) := "1111";
    signal dest, src : std_logic_vector(9 downto 0) := (others => '0');
begin
    clk <= not clk after 5 ns;
    dut : entity work.routing_wb
        generic map (10, 14, 768)
        port map (clk, addr, di, dout, sel, cyc, cyc, wr, ack, err,
                  clk, dest, src, rst, scan, ready);

    process
        procedure tick is
        begin
            wait until rising_edge(clk);
            wait for 1 ns;
        end;
        procedure request(d, s : natural; write_bit : std_logic) is
        begin
            addr <= std_logic_vector(to_unsigned(16#20000000# + d, 30));
            di <= std_logic_vector(to_unsigned(s, 32));
            wr <= write_bit;
            cyc <= '1';
            tick;
        end;
        procedure finish is
        begin
            cyc <= '0';
            tick;
        end;
    begin
        tick;
        rst <= '0';
        for i in 1 to 767 loop
            tick;
            assert ready = '0' severity failure;
        end loop;
        tick;
        assert ready = '1' severity failure;
        request(255, 256, '1'); assert ack = '1' severity failure; finish;
        request(256, 511, '1'); assert ack = '1' severity failure; finish;
        request(767, 768, '1'); assert ack = '1' severity failure; finish;
        request(768, 1, '1'); assert err = '1' and ack = '0' severity failure; finish;
        request(767, 769, '1'); assert err = '1' and ack = '0' severity failure; finish;
        sel <= "0001";
        request(767, 1, '1'); assert err = '1' and ack = '0' severity failure; finish;
        sel <= "1111";
        request(767, 0, '0'); assert ack = '1' and unsigned(dout) = 768 severity failure; finish;

        -- Queue a live B route update during a scan. It must affect the
        -- following scan only, never the current snapshot.
        request(419, 373, '1'); assert ack = '1' severity failure; finish;
        scan <= '1'; dest <= std_logic_vector(to_unsigned(419, 10));
        request(419, 420, '1');
        assert ack = '0' and unsigned(src) = 373 severity failure;
        tick;
        assert ack = '0' and unsigned(src) = 373 severity failure;
        scan <= '0';
        tick;
        assert ack = '1' severity failure; finish;
        scan <= '1'; tick;
        assert unsigned(src) = 420 severity failure;
        dest <= std_logic_vector(to_unsigned(255, 10)); tick;
        assert unsigned(src) = 256 severity failure;
        dest <= std_logic_vector(to_unsigned(256, 10)); tick;
        assert unsigned(src) = 511 severity failure;

        rst <= '1'; scan <= '0'; tick; rst <= '0';
        wait until ready = '1';
        request(419, 0, '0'); assert ack = '1' and unsigned(dout) = 0 severity failure; finish;
        report "route bounds, full 10-bit selectors, B scan interlock and reset OK";
        std.env.stop;
    end process;
end architecture;
