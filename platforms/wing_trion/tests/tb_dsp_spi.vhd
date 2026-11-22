-- SPDX-License-Identifier: GPL-3.0-only
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_dsp_spi is end;
architecture test of tb_dsp_spi is
    signal clk, sck, mosi : std_logic := '0';
    signal rst, cs : std_logic := '1';
    signal miso : std_logic;
    signal select_n, dsp_sck, dsp_mosi : std_logic_vector(3 downto 0);
begin
    clk <= not clk after 10 ns;
    dut : entity work.dsp_spi
        port map (clk, rst, cs, sck, mosi, miso, "1010", select_n, dsp_sck, dsp_mosi);

    process
        procedure send(byte : std_logic_vector(7 downto 0); target : natural := 0) is
            variable selected, clocked, data : std_logic_vector(3 downto 0);
        begin
            selected := "1111";
            if target /= 0 then selected(target-1) := '0'; end if;
            for i in byte'range loop
                mosi <= byte(i); wait for 250 ns;
                sck <= '1'; wait for 100 ns;
                clocked := not selected;
                data := clocked when byte(i) = '1' else "0000";
                assert select_n = selected and dsp_sck = clocked and dsp_mosi = data
                    report "selector leaked, wrong DSP selected or payload corrupted" severity failure;
                wait for 150 ns; sck <= '0';
            end loop;
        end procedure;
    begin
        wait for 200 ns;
        assert select_n = "1111" and dsp_sck = "0000" severity failure;
        rst <= '0';
        for target in 1 to 4 loop
            cs <= '0'; send(std_logic_vector(to_unsigned(target, 8))); send(x"A6", target);
            if target mod 2 = 0 then assert miso = '1' severity failure;
            else assert miso = '0' severity failure; end if;
            cs <= '1'; wait for 200 ns;
            assert select_n = "1111" severity failure;
        end loop;
        cs <= '0'; send(x"00"); send(x"04");
        cs <= '1'; wait for 200 ns;
        cs <= '0'; send(x"05"); send(x"01");
        report "SS0: selector stripped, four distinct DSPs, invalid selector suppressed";
        std.env.stop;
    end process;
end architecture;
