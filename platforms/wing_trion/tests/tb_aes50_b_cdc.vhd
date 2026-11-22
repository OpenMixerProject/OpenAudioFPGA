-- SPDX-License-Identifier: GPL-3.0-only
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_aes50_b_cdc is
    generic (G_RMII_PHASE_NS : natural := 3);
end entity;

architecture test of tb_aes50_b_cdc is
    constant AUDIO_HALF : time := 10.172526 ns;
    signal clk_audio, clk_rmii : std_logic := '0';
    signal audio_stopped, bclk_stopped : boolean := false;
    signal phy_reset_n, link_ok, dropped : std_logic;
    -- Waveform checkpoints: bit 3 toggles, bits 2:0 expect core/audio/BCLK reset.
    signal reset_check : std_logic_vector(3 downto 0) := "0XXX";
    signal rst : std_logic := '1';
    signal phase : unsigned(9 downto 0) := (others => '0');
    signal bclk, fs : std_logic;
    signal stim_a, stim_b : std_logic := '0';
    signal txen, wire_dv, rx_dv : std_logic;
    signal txd, wire_dibits, rx_dibits : std_logic_vector(1 downto 0);
    signal tdm_in, tdm_out : std_logic_vector(6 downto 0) := (others => '0');
    signal received, source_frame : natural := 0;

    function pattern(frame, channel : natural) return std_logic_vector is
    begin
        return std_logic_vector(to_unsigned(16#800000# + (frame mod 16384) * 64 + channel, 24));
    end function;
begin
    clk_audio <= not clk_audio after AUDIO_HALF when not audio_stopped else '0';
    process
    begin
        wait for G_RMII_PHASE_NS * 1 ns;
        loop
            wait for 10 ns;
            clk_rmii <= not clk_rmii;
        end loop;
    end process;
    stim_a <= not stim_a after 161 ns;
    stim_b <= not stim_b after 169 ns;

    process (clk_audio)
    begin
        if rising_edge(clk_audio) then phase <= phase + 1; end if;
        if falling_edge(clk_audio) then
            if phase >= 1018 and phase <= 1021 then fs <= '1';
            else fs <= '0'; end if;
        end if;
    end process;
    bclk <= not phase(1) when not bclk_stopped else '0';

    -- Model the WING pad stages and a wire with non-zero delay. Use the
    -- actual framer, deframer and dual-clock sample RAMs, not a toggle mock.
    process (clk_rmii)
    begin
        if falling_edge(clk_rmii) then
            wire_dv <= txen after 2 ns;
            wire_dibits <= txd after 2 ns;
        end if;
        if rising_edge(clk_rmii) then
            rx_dv <= wire_dv;
            rx_dibits <= wire_dibits;
            if rst = '0' then assert dropped /= '1' report "unexpected bad block/FCS" severity failure; end if;
        end if;
    end process;

    dut : entity work.aes50_core
        generic map (G_SUPPORT_44K1 => false, G_UART_AUX => false, G_TDM_AUX => false,
                     G_FSYNC_DELAY => 1, G_SIM_ASSM_SAMPLES => 24)
        port map (
            clk50_i => clk_rmii, rst_i => rst, fs_mode_i => "01", sys_mode_i => "11",
            tdm8_i2s_mode_i => '0', aux_tx_tdm_uart_select_i => '0',
            rmii_crs_dv_i => rx_dv, rmii_rxd_i => rx_dibits, rmii_tx_en_o => txen, rmii_txd_o => txd,
            phy_rst_n_o => phy_reset_n,
            aes50_clk_a_rx_i => stim_a, aes50_clk_a_tx_o => open, aes50_clk_a_tx_en_o => open,
            aes50_clk_b_rx_i => stim_b, aes50_clk_b_tx_o => open, aes50_clk_b_tx_en_o => open,
            clk_1024xfs_from_pll_i => clk_audio, pll_lock_n_i => '0', clk_to_pll_o => open,
            pll_mult_value_o => open, pll_init_busy_i => '0',
            mclk_o => open, wclk_o => open, bclk_o => open, wclk_readback_i => fs, bclk_readback_i => bclk,
            wclk_out_en_o => open, bclk_out_en_o => open,
            tdm_i => tdm_in, tdm_o => tdm_out, i2s_i => '0', i2s_o => open,
            aes_ok_o => link_ok, rx_blk_drop_o => dropped, dbg_o => open, uart_o => open, uart_i => '1',
            debug_out_signal_pulse_len_i => 0, first_transmit_start_counter_48k_i => 0,
            first_transmit_start_counter_44k1_i => 0, wd_aes_clk_timeout_i => 25,
            wd_aes_rx_dv_timeout_i => 7500, mdix_timer_1ms_reference_i => 50000,
            aes_clk_ok_counter_reference_i => 500, mult_clk625_48k_i => 8246337,
            mult_clk625_44k1_i => 7576322, uart_clks_per_bit_i => 434, uart_timeout_clks_i => 500000);

    -- Independent serial source: every channel and every sample frame has
    -- different bits; prepare data on the falling edge before BCLK capture.
    process (bclk)
        variable frame : natural := 0;
        variable pos, slot, bitpos : natural;
        variable word : std_logic_vector(23 downto 0);
    begin
        if falling_edge(bclk) then
            pos := (to_integer(phase) / 4 + 1) mod 256;
            if pos = 0 then frame := frame + 1; source_frame <= frame; end if;
            slot := pos / 32;
            bitpos := pos mod 32;
            for lane in 0 to 5 loop
                word := pattern(frame, lane * 8 + slot);
                if bitpos < 24 then tdm_in(lane) <= word(23 - bitpos);
                else tdm_in(lane) <= '0'; end if;
            end loop;
        end if;
    end process;

    process (bclk)
        type words is array (0 to 5) of std_logic_vector(23 downto 0);
        variable shift : words;
        variable pos, slot, bitpos, frame, previous, reset_frame : natural := 0;
        variable playing, framed : boolean := false;
    begin
        if rising_edge(bclk) then
            if rst = '1' or phy_reset_n /= '1' then
                received <= 0;
                playing := false;
                framed := false;
                reset_frame := source_frame;
            else
                pos := to_integer(phase) / 4;
                slot := pos / 32;
                bitpos := pos mod 32;
                if pos = 0 then framed := true; end if;
                if bitpos < 24 then
                    for lane in 0 to 5 loop shift(lane) := shift(lane)(22 downto 0) & tdm_out(lane); end loop;
                end if;
                if framed and bitpos = 23 then
                    if slot = 0 and (playing or shift(0) /= x"000000") then
                        assert not is_x(shift(0)) severity failure;
                        frame := to_integer(unsigned(shift(0)(19 downto 6)));
                        if playing then
                            assert frame = previous + 1 report "missing, repeated or stale sample" severity failure;
                        else
                            assert frame > reset_frame and frame < source_frame
                                report "first block is stale or did not come from this reset epoch" severity failure;
                        end if;
                        previous := frame;
                        playing := true;
                    end if;
                    for lane in 0 to 5 loop
                        if playing then
                            assert shift(lane) = pattern(frame, lane * 8 + slot)
                                report "corrupt or misaddressed sample on lane " & integer'image(lane) &
                                    ", slot " & integer'image(slot) severity failure;
                        else
                            assert shift(lane) = x"000000" report "non-silent incomplete frame" severity failure;
                        end if;
                    end loop;
                    if slot = 7 and playing then received <= received + 1; end if;
                end if;
            end if;
        end if;
    end process;

    process
        procedure expect_reset(expected : std_logic_vector(2 downto 0)) is
        begin
            reset_check <= not reset_check(3) & expected;
        end procedure;

        procedure check_release(signal clk : in std_logic; held, released : std_logic_vector(2 downto 0)) is
        begin
            wait until rising_edge(clk);
            wait for 1 ns;
            expect_reset(held);
            wait until falling_edge(clk);
            wait for 1 ns;
            expect_reset(held);
            wait until rising_edge(clk);
            wait for 1 ns;
            expect_reset(released);
        end procedure;
    begin
        wait for 163 ns;
        for round in 0 to 1 loop
            rst <= '0';
            wait until received = 72 for 28 ms;
            assert received = 72 and link_ok = '1' report "no sustained full-frame traffic" severity failure;
            if round = 0 then
                wait until rising_edge(txen) for 150 us;
                assert txen = '1' severity failure;
                wait for 3057 ns; -- reset during a frame, off both clocks
                rst <= '1';
                wait for 713 ns;
                assert phy_reset_n = '0' and txen = '0' report "PHY/traffic not reset" severity failure;
            end if;
        end loop;
        report "PASS 144 consecutive sample frames, 48 changing channels each, RMII loop and in-flight reset";

        -- Stop BCLK and its source low after the link has carried traffic.
        wait until falling_edge(bclk);
        wait until falling_edge(clk_audio);
        audio_stopped <= true;
        bclk_stopped <= true;
        expect_reset("000");
        wait for 37 ns;
        rst <= '1';
        wait until falling_edge(phy_reset_n) for 100 ns;
        assert phy_reset_n = '0' report "PHY reset did not assert" severity failure;
        wait for 1 ns;
        expect_reset("111");

        rst <= '0';
        wait until rising_edge(phy_reset_n) for 2 ms;
        assert phy_reset_n = '1' report "PHY reset did not release" severity failure;
        wait for 113 ns;
        assert clk_audio = '0' and bclk = '0' severity failure;
        expect_reset("011");
        audio_stopped <= false;
        check_release(clk_audio, "011", "001");
        wait until rising_edge(phase(1)); -- ungate BCLK only while its source is low
        expect_reset("001");
        bclk_stopped <= false;
        check_release(bclk, "001", "000");
        wait for 1 ns; -- let the last checkpoint reach the waveform before stopping
        std.env.stop;
        wait;
    end process;
end architecture;
