--
-- OpenAudioFPGA - Modular Testbench:
--   1. aes50_wb (instantiated with G_PORTS => 3 to verify X32 & WING multi-port stride)
--   2. cs2000cp_wb (standalone CS2000-CP clock/PLL Wishbone peripheral)
--   3. src_96k_48k (47-tap Q1.17 half-band FIR SRC DC unity gain)
--
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_modules_wb is
end entity tb_modules_wb;

architecture sim of tb_modules_wb is
	constant CLK50_PERIOD : time := 20 ns;
	constant CLK16_PERIOD : time := 62.5 ns;

	signal clk50    : std_logic := '0';
	signal clk16    : std_logic := '0';
	signal rst      : std_logic := '1';
	signal sim_done : boolean := false;

	-- SRC signals
	signal rx_we, rx_phase, rx_run, rx_out_valid : std_logic := '0';
	signal rx_ch, rx_out_ch : unsigned(4 downto 0) := (others => '0');
	signal rx_sample, rx_out_sample : std_logic_vector(23 downto 0) := (others => '0');
	signal tx_we, tx_run, tx_out_valid, tx_out_phase : std_logic := '0';
	signal tx_ch, tx_out_ch : unsigned(4 downto 0) := (others => '0');
	signal tx_sample, tx_out_sample : std_logic_vector(23 downto 0) := (others => '0');
	signal rx_last_ch0, tx_last_p0, tx_last_p1 : integer := 0;

	-- Wishbone for aes50_wb (3 ports)
	signal a_adr   : std_logic_vector(29 downto 0) := (others => '0');
	signal a_dat_w : std_logic_vector(31 downto 0) := (others => '0');
	signal a_dat_r : std_logic_vector(31 downto 0);
	signal a_cyc, a_stb, a_we, a_ack, a_err : std_logic := '0';

	-- Wishbone for cs2000cp_wb
	signal c_adr   : std_logic_vector(29 downto 0) := (others => '0');
	signal c_dat_w : std_logic_vector(31 downto 0) := (others => '0');
	signal c_dat_r : std_logic_vector(31 downto 0);
	signal c_cyc, c_stb, c_we, c_ack, c_err : std_logic := '0';
	signal clk_src : std_logic_vector(2 downto 0);
	signal pll_rst : std_logic := '0';
begin
	clk50 <= not clk50 after CLK50_PERIOD / 2 when not sim_done else '0';
	clk16 <= not clk16 after CLK16_PERIOD / 2 when not sim_done else '0';

	u_aes50_wb : entity work.aes50_wb
		generic map (
			G_PORTS           => 3,
			G_ENABLE_SRC      => true,
			G_ENABLE_AUX      => true,
			G_AUX_FIFO_AW     => 6,
			G_SIM_ASSM_FRAMES => 16)
		port map (
			clk50_i             => clk50,
			rst_i               => rst,
			clk_1024xfs_i       => clk50,
			bclk_i              => '0',
			fsync_i             => '0',
			pll_lock_i          => '1',
			wb_adr_i            => a_adr,
			wb_dat_i            => a_dat_w,
			wb_dat_o            => a_dat_r,
			wb_sel_i            => "1111",
			wb_cyc_i            => a_cyc,
			wb_stb_i            => a_stb,
			wb_we_i             => a_we,
			wb_ack_o            => a_ack,
			wb_err_o            => a_err,
			rmii_crs_dv_i       => (others => '0'),
			rmii_rxd_i          => (others => '0'),
			rmii_tx_en_o        => open,
			rmii_txd_o          => open,
			phy_rst_n_o         => open,
			aes50_clk_a_rx_i    => (others => '0'),
			aes50_clk_a_tx_o    => open,
			aes50_clk_a_tx_en_o => open,
			aes50_clk_b_rx_i    => (others => '0'),
			aes50_clk_b_tx_o    => open,
			aes50_clk_b_tx_en_o => open,
			clk_to_pll_o        => open,
			tdm_i               => (others => '0'),
			tdm_o               => open,
			aes_ok_o            => open);

	u_cs2k_wb : entity work.cs2000cp_wb
		port map (
			wb_clk_i    => clk50,
			wb_rst_i    => rst,
			wb_adr_i    => c_adr,
			wb_dat_i    => c_dat_w,
			wb_dat_o    => c_dat_r,
			wb_sel_i    => "1111",
			wb_cyc_i    => c_cyc,
			wb_stb_i    => c_stb,
			wb_we_i     => c_we,
			wb_ack_o    => c_ack,
			wb_err_o    => c_err,
			clk_16m_i   => clk16,
			pll_rst_i   => pll_rst,
			pll_aux_i   => '1',
			pll_ncs_o   => open,
			pll_cclk_o  => open,
			pll_cdata_o => open,
			clk_src_o   => clk_src);

	u_src : entity work.src_96k_48k
		generic map (G_NUM_CH => 24)
		port map (
			clk_i           => clk50,
			rst_i           => rst,
			rx_we_i         => rx_we,
			rx_phase_i      => rx_phase,
			rx_ch_i         => rx_ch,
			rx_sample_i     => rx_sample,
			rx_run_i        => rx_run,
			rx_out_valid_o  => rx_out_valid,
			rx_out_ch_o     => rx_out_ch,
			rx_out_sample_o => rx_out_sample,
			tx_we_i         => tx_we,
			tx_ch_i         => tx_ch,
			tx_sample_i     => tx_sample,
			tx_run_i        => tx_run,
			tx_out_valid_o  => tx_out_valid,
			tx_out_phase_o  => tx_out_phase,
			tx_out_ch_o     => tx_out_ch,
			tx_out_sample_o => tx_out_sample);

	process (clk50)
	begin
		if rising_edge(clk50) then
			if rx_out_valid = '1' and rx_out_ch = 0 then
				rx_last_ch0 <= to_integer(signed(rx_out_sample));
			end if;
			if tx_out_valid = '1' and tx_out_ch = 0 then
				if tx_out_phase = '0' then tx_last_p0 <= to_integer(signed(tx_out_sample));
				else tx_last_p1 <= to_integer(signed(tx_out_sample));
				end if;
			end if;
		end if;
	end process;

	stim : process
		procedure wb_wr(signal adr : out std_logic_vector(29 downto 0);
		                signal dat : out std_logic_vector(31 downto 0);
		                signal cyc, stb, we : out std_logic;
		                signal ack : in std_logic;
		                byte_off : in natural; val : in std_logic_vector(31 downto 0)) is
		begin
			wait until rising_edge(clk50);
			adr <= std_logic_vector(to_unsigned(byte_off / 4, 30));
			dat <= val; we <= '1'; cyc <= '1'; stb <= '1';
			loop wait until rising_edge(clk50); exit when ack = '1'; end loop;
			cyc <= '0'; stb <= '0'; we <= '0';
		end procedure;

		procedure wb_rd(signal adr : out std_logic_vector(29 downto 0);
		                signal dat : in std_logic_vector(31 downto 0);
		                signal cyc, stb, we : out std_logic;
		                signal ack : in std_logic;
		                byte_off : in natural; variable val : out std_logic_vector(31 downto 0)) is
		begin
			wait until rising_edge(clk50);
			adr <= std_logic_vector(to_unsigned(byte_off / 4, 30));
			we <= '0'; cyc <= '1'; stb <= '1';
			loop
				wait until rising_edge(clk50);
				if ack = '1' then val := dat; exit; end if;
			end loop;
			cyc <= '0'; stb <= '0';
		end procedure;

		variable r : std_logic_vector(31 downto 0);
	begin
		rst <= '1';
		for i in 0 to 5 loop wait until rising_edge(clk50); end loop;
		rst <= '0';
		for i in 0 to 5 loop wait until rising_edge(clk50); end loop;

		-- 1. Verify 3-port aes50_wb stride (0x00, 0x40, 0x80) and out-of-range port 3 (0xC0 -> 0)
		wb_rd(a_adr, a_dat_r, a_cyc, a_stb, a_we, a_ack, 16#00#, r);
		assert r = x"A5020301" report "Port 0 INFO mismatch" severity failure;
		wb_rd(a_adr, a_dat_r, a_cyc, a_stb, a_we, a_ack, 16#40#, r);
		assert r = x"A5020311" report "Port 1 INFO mismatch" severity failure;
		wb_rd(a_adr, a_dat_r, a_cyc, a_stb, a_we, a_ack, 16#80#, r);
		assert r = x"A5020321" report "Port 2 INFO mismatch" severity failure;
		wb_rd(a_adr, a_dat_r, a_cyc, a_stb, a_we, a_ack, 16#C0#, r);
		assert r = x"00000000" report "Out-of-range Port 3 should read 0" severity failure;

		-- Independent per-port CTRL write/readback on Port 2 (WING Port C)
		wb_wr(a_adr, a_dat_w, a_cyc, a_stb, a_we, a_ack, 16#84#, x"00000105");
		wb_rd(a_adr, a_dat_r, a_cyc, a_stb, a_we, a_ack, 16#84#, r);
		assert r = x"00000105" report "Port 2 CTRL mismatch" severity failure;

		-- 2. Verify cs2000cp_wb MAGIC, CLK_CTRL, and CS2K_CMD
		wb_rd(c_adr, c_dat_r, c_cyc, c_stb, c_we, c_ack, 16#00#, r);
		assert r = x"4353324B" report "CS2K MAGIC mismatch" severity failure;
		wb_wr(c_adr, c_dat_w, c_cyc, c_stb, c_we, c_ack, 16#04#, x"00000002");
		wb_rd(c_adr, c_dat_r, c_cyc, c_stb, c_we, c_ack, 16#04#, r);
		assert r = x"00000002" and clk_src = "010" report "CLK_CTRL mismatch" severity failure;
		wb_wr(c_adr, c_dat_w, c_cyc, c_stb, c_we, c_ack, 16#40#, x"00000631");
		wb_rd(c_adr, c_dat_r, c_cyc, c_stb, c_we, c_ack, 16#40#, r);
		assert r = x"00000631" report "CS2K_CMD mismatch" severity failure;

		-- 3. Verify src_96k_48k DC unity gain
		for p in 0 to 39 loop
			wait until rising_edge(clk50);
			rx_we <= '1'; rx_phase <= '0'; rx_ch <= to_unsigned(0, 5);
			rx_sample <= std_logic_vector(to_signed(1000000, 24));
			tx_we <= '1'; tx_ch <= to_unsigned(0, 5);
			tx_sample <= std_logic_vector(to_signed(1000000, 24));
			wait until rising_edge(clk50);
			rx_phase <= '1'; tx_we <= '0';
			wait until rising_edge(clk50);
			rx_we <= '0'; rx_run <= '1'; tx_run <= '1';
			wait until rising_edge(clk50);
			rx_run <= '0'; tx_run <= '0';
			for w in 0 to 900 loop wait until rising_edge(clk50); end loop;
		end loop;

		assert abs(rx_last_ch0 - 1000000) < 200 report "SRC RX DC gain failed" severity failure;
		assert abs(tx_last_p0 - 1000000) < 200 and abs(tx_last_p1 - 1000000) < 200
			report "SRC TX DC gain failed" severity failure;

		report "PASS: tb_modules_wb (3-port aes50_wb + cs2000cp_wb + src_96k_48k)" severity note;
		sim_done <= true;
		wait;
	end process;
end architecture sim;
