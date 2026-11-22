-- SPDX-License-Identifier: GPL-3.0-only
library ieee;
use ieee.std_logic_1164.all;

entity tb_aes50_sync_pins is
    generic (G_SLAVE : boolean := false);
end entity;

architecture test of tb_aes50_sync_pins is
    constant MDIX_PERIOD : time := 260 ns; -- 12 + 1 RMII cycles
    signal clk_audio, clk_rmii : std_logic := '0';
    signal audio_started : boolean := false;
    signal stopped : boolean := false;
    signal rst : std_logic := '1';
    signal phy_reset_n : std_logic;
    signal mode : std_logic_vector(1 downto 0);
    signal rx_a : std_logic := '0';
    signal rx_b : std_logic := '1';
    signal tx, de : std_logic_vector(1 downto 0); -- A, B
begin
    audio_started <= true after 4 ns; -- place both pair changes between audio edges
    clk_audio <= not clk_audio after 11 ns when audio_started and not stopped else '0';
    clk_rmii <= not clk_rmii after 10 ns;
    mode <= "00" when G_SLAVE else "11";

    dut : entity work.aes50_core
        generic map (G_SUPPORT_44K1 => false, G_UART_AUX => false, G_TDM_AUX => false)
        port map (
            clk50_i => clk_rmii, rst_i => rst, fs_mode_i => "01", sys_mode_i => mode,
            tdm8_i2s_mode_i => '0', aux_tx_tdm_uart_select_i => '0',
            rmii_crs_dv_i => '0', rmii_rxd_i => "00", rmii_tx_en_o => open, rmii_txd_o => open,
            phy_rst_n_o => phy_reset_n,
            aes50_clk_a_rx_i => rx_a, aes50_clk_a_tx_o => tx(1), aes50_clk_a_tx_en_o => de(1),
            aes50_clk_b_rx_i => rx_b, aes50_clk_b_tx_o => tx(0), aes50_clk_b_tx_en_o => de(0),
            clk_1024xfs_from_pll_i => clk_audio, pll_lock_n_i => '0', clk_to_pll_o => open,
            pll_mult_value_o => open, pll_init_busy_i => '0',
            mclk_o => open, wclk_o => open, bclk_o => open, wclk_readback_i => '0', bclk_readback_i => '0',
            wclk_out_en_o => open, bclk_out_en_o => open,
            tdm_i => (others => '0'), tdm_o => open, i2s_i => '0', i2s_o => open,
            aes_ok_o => open, rx_blk_drop_o => open, dbg_o => open, uart_o => open, uart_i => '1',
            debug_out_signal_pulse_len_i => 0, first_transmit_start_counter_48k_i => 0,
            first_transmit_start_counter_44k1_i => 0, wd_aes_clk_timeout_i => 0,
            wd_aes_rx_dv_timeout_i => 0, mdix_timer_1ms_reference_i => 12,
            aes_clk_ok_counter_reference_i => 0, mult_clk625_48k_i => 8246337,
            mult_clk625_44k1_i => 7576322, uart_clks_per_bit_i => 434, uart_timeout_clks_i => 500000);

    process
    begin
        wait for 45 ns;
        rst <= '0';
        wait until rising_edge(phy_reset_n) for 2 ms;
        assert phy_reset_n = '1' severity failure;
        wait for 1 ns;
        assert de = "10" and ((G_SLAVE and tx = "10") or (not G_SLAVE and tx = "00"))
            report "pins did not follow core reset release" severity failure;

        -- The first two timer expiries select MDI-X then MDI. The 1 ns
        -- observations straddle each RMII edge, with no audio edge between.
        wait for MDIX_PERIOD - 2 ns;
        assert de = "10" severity failure;
        wait for 2 ns;
        assert clk_audio'last_event > 2 ns and de = "01" and de'last_event = 1 ns
            report "MDI-X did not take effect on the RMII edge" severity failure;
        if G_SLAVE then
            assert tx = "00" severity failure; -- A RX is low, B RX is high
            wait for 2 ns;
            rx_a <= '1';
            wait for 1 ns;
            assert tx = "01" severity failure;
            rx_a <= '0';
            wait for 1 ns;
            assert tx = "00" severity failure;
            wait for MDIX_PERIOD - 6 ns;
        else
            wait for MDIX_PERIOD - 2 ns;
        end if;
        assert de = "01" severity failure;
        wait for 2 ns;
        assert clk_audio'last_event > 2 ns and de = "10" and de'last_event = 1 ns
            report "MDI did not take effect on the RMII edge" severity failure;

        if not G_SLAVE and tx(1) /= '1' then wait until tx(1) = '1' for 200 ns; end if;
        assert tx = "10" severity failure;
        stopped <= true;
        wait for 3 ns;
        assert tx = "10" and de = "10" severity failure;
        rst <= '1';
        wait until falling_edge(phy_reset_n) for 100 ns;
        assert phy_reset_n = '0' severity failure;
        wait for 1 ns;
        assert clk_audio = '0' and clk_audio'last_event > 2 ns and tx = "00" and de = "00"
            and tx'last_event = 1 ns and de'last_event = 1 ns
            report "active pins did not shut off with audio clock stopped" severity failure;
        rst <= '0';
        wait until rising_edge(phy_reset_n) for 2 ms;
        assert phy_reset_n = '1' severity failure;
        wait for 1 ns;
        assert clk_audio = '0' and de = "10" and de'last_event = 1 ns
            report "enables waited for audio clock after reset" severity failure;
        if G_SLAVE then
            assert tx = "10" severity failure;
            rx_b <= '0';
            wait for 1 ns;
            assert tx = "00" severity failure;
            rx_b <= '1';
            wait for 1 ns;
            assert tx = "10" severity failure;
        else
            assert tx = "00" severity failure; -- generator is still in local reset
        end if;
        wait for MDIX_PERIOD + 1 ns - phy_reset_n'last_event;
        assert clk_audio = '0' and de = "01" and de'last_event = 1 ns and tx = "00"
            report "MDI-X must still switch without audio edges" severity failure;
        report "PASS AES50 sync pins, slave=" & boolean'image(G_SLAVE);
        std.env.stop;
        wait;
    end process;
end architecture;
