library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity x32_common is
	generic (
		G_AES50_PORTS			: natural range 0 to 2 := 1;	-- AES50 cores
		G_AES67					: boolean := false;				-- AES67 core on the port after the AES50 cores
		G_INFERNO				: boolean := false;				-- OpenInferno core on the port after the AES50 cores
		G_INFERNO_RXW			: positive := 2048;				-- OpenInferno CPU RX queue words (2048 ECP5, 1024 Spartan-3A)
		G_AES50_PAR_BRIDGE		: boolean := true;				-- true: aes50_par_bridge (96k SRC + Wishbone aux)
		G_AES50_SRC				: boolean := true;				-- enable 96<->48 kHz half-band FIR SRC
		G_EXT_TDM_LINES			: natural := 0;					-- additional TDM lines for the top level
		-- AUX converters: true = CS42438 codec (boards with the Spartan-3A),
		--                 false = M8000 ADC + PCM1690 DAC (boards with the ECP5)
		G_AUX_CS42438			: boolean := false;
		G_AES50_SUPPORT_44K1	: boolean := false;
		G_AES50_SIM_ASSM_SAMPLES	: natural := 2048;
		G_PLATFORM_ID			: natural range 0 to 255 := 0	-- CSR core_info: 1 = Lattice, 2 = Spartan
	);
	port (
		-- clocks and resets
		clk_16m_i			: in  std_logic;	-- 16 MHz oscillator
		clk_50m_i			: in  std_logic;	-- 50 MHz RMII clock from the PLL / DCM of the top level
		clk_100m_i			: in  std_logic := '0';	-- 100 MHz, only needed for AES67
		pll_rst_o			: out std_logic;	-- reset pulse for the PLLs / DCMs of the top level
		io_rst_o			: out std_logic;	-- reset pulse for the IO registers of the top level
		online_o			: out std_logic;	-- '1' after the startup sequence

		-- CS2000 PLL
		pll_in_o			: out std_logic;	-- 16 MHz / AES67 24.576 MHz / AES50 recovered clock
		pll_out_i			: in  std_logic;	-- 1024fs
		pll_aux_i			: in  std_logic := '1';	-- CS2000-CP PLL_LOCK status input
		pll_ncs_o			: out std_logic;
		pll_cclk_o			: out std_logic;
		pll_cdata_o			: out std_logic;

		-- audio clocks
		clk_fs512_o			: out std_logic;	-- 24.576 MHz
		clk_fs256_o			: out std_logic;	-- 12.288 MHz
		fsync_o				: out std_logic;	-- 48 kHz

		-- control bus of the i.MX25 (SPI3 CS0, after the FPGA configuration): SPIBone ->
		-- Wishbone, register map in rtl/core/openaudio_core.vhd and litex_soc/build/*/csr.csv
		spi_ncs_i			: in  std_logic;
		spi_clk_i			: in  std_logic;
		spi_mosi_i			: in  std_logic;
		spi_miso_o			: out std_logic;
		cfg_bits_o			: out std_logic_vector(7 downto 0);	-- CSR core_config (clk_50m_i domain)

		-- UART of the IO boards (i.MX25 UART3)
		uart3_txd_i			: in  std_logic;
		uart3_rxd_o			: out std_logic;
		da_rx_i				: in  std_logic;
		ad0_rx_i			: in  std_logic;
		ad1_rx_i			: in  std_logic;
		card_rx_i			: in  std_logic;
		card_rdy_i			: in  std_logic;
		da_tx_o				: out std_logic;
		ad0_tx_o			: out std_logic;
		ad1_tx_o			: out std_logic;
		card_tx_o			: out std_logic;

		-- TDM8 data
		ad0_data1_i			: in  std_logic;	-- line 0
		ad0_data0_i			: in  std_logic;	-- line 1
		ad1_data1_i			: in  std_logic;	-- line 2
		ad1_data0_i			: in  std_logic;	-- line 3
		card_in3_i			: in  std_logic;	-- line 4
		card_in2_i			: in  std_logic;	-- line 5
		card_in1_i			: in  std_logic;	-- line 6
		card_in0_i			: in  std_logic;	-- line 7
		aux_ad_i			: in  std_logic;	-- line 8
		dsp_dout_i			: in  std_logic_vector(3 downto 0);	-- lines 9 .. 12
		dsp_doutaux_i		: in  std_logic;	-- line 13

		da_data1_o			: out std_logic;	-- line 0
		da_data0_o			: out std_logic;	-- line 1
		card_out_o			: out std_logic_vector(3 downto 0);	-- lines 4 .. 7
		aux_da_o			: out std_logic;	-- line 8
		dsp_din_o			: out std_logic_vector(3 downto 0);	-- lines 9 .. 12
		dsp_dinaux_o		: out std_logic;	-- line 13

		-- additional TDM lines behind the AES50 lines
		ext_tdm_i			: in  std_logic_vector(G_EXT_TDM_LINES - 1 downto 0) := (others => '0');
		ext_tdm_o			: out std_logic_vector(G_EXT_TDM_LINES - 1 downto 0);

		-- UltraNet
		p16_a_txp_o			: out std_logic;
		p16_a_txm_o			: out std_logic;
		p16_b_txp_o			: out std_logic;
		p16_b_txm_o			: out std_logic;

		-- AUX converter control port
		aux_cclk_o			: out std_logic;
		aux_cdata_o			: out std_logic;
		aux_nrst_o			: out std_logic;
		aux_ncs_o			: out std_logic;	-- CS42438 (G_AUX_CS42438 = true)
		aux_ad_ncs_o		: out std_logic;	-- M8000 ADC (G_AUX_CS42438 = false)
		aux_da_ncs_o		: out std_logic;	-- PCM1690 DAC (G_AUX_CS42438 = false)
		conv_nrst_o			: out std_logic;	-- reset of the AD / DA boards

		-- the two network ports (index 0 = "AES50 A", 1 = "AES50 B"), RMII behind the IO registers
		rmii_crs_dv_i		: in  std_logic_vector(1 downto 0);
		rmii_rxd_i			: in  std_logic_vector(3 downto 0);
		rmii_tx_en_o		: out std_logic_vector(1 downto 0);
		rmii_txd_o			: out std_logic_vector(3 downto 0);
		phy_rst_n_o			: out std_logic_vector(1 downto 0);
		-- AES50 clock transceivers of both ports
		aes50_clk_a_rx_i	: in  std_logic_vector(1 downto 0);
		aes50_clk_a_tx_o	: out std_logic_vector(1 downto 0);
		aes50_clk_a_tx_en_o	: out std_logic_vector(1 downto 0);
		aes50_clk_a_rx_nen_o	: out std_logic_vector(1 downto 0);
		aes50_clk_b_rx_i	: in  std_logic_vector(1 downto 0);
		aes50_clk_b_tx_o	: out std_logic_vector(1 downto 0);
		aes50_clk_b_tx_en_o	: out std_logic_vector(1 downto 0);
		aes50_clk_b_rx_nen_o	: out std_logic_vector(1 downto 0);
		-- aux data of AES50 core 0 (i.MX25 UART4)
		uart4_txd_i			: in  std_logic;
		uart4_rxd_o			: out std_logic
	);
end entity x32_common;

architecture rtl of x32_common is
	constant C_BASE_LINES	: natural := 14;	-- converters, card, AUX and DSP
	constant C_AES67_LINE	: natural := C_BASE_LINES + 6 * G_AES50_PORTS;
	constant C_AES67_PORT	: natural := G_AES50_PORTS;			-- network port of the AES67 core

	function f_portb_lines return natural is
	begin
		if G_AES67 then
			return 4;
		elsif G_INFERNO then
			return 6;
		end if;
		return 0;
	end function;
	constant C_EXT_LINE		: natural := C_AES67_LINE + f_portb_lines;
	constant C_LINES		: natural := C_EXT_LINE + G_EXT_TDM_LINES;

	-- AES50 system mode of every core: "10"
	function f_aes50_sys_mode return std_logic_vector is
		variable v : std_logic_vector(2 * G_AES50_PORTS - 1 downto 0);
	begin
		for k in 0 to G_AES50_PORTS - 1 loop
			v(2 * k + 1 downto 2 * k) := "10";
		end loop;
		return v;
	end function;

	-- CS2000 ratio PLL_OUT / PLL_IN (12.20 fixed point): x3.072 from the 16 MHz oscillator,
	-- x2 from the 24.576 MHz of the AES67 core
	function f_pll_ratio return std_logic_vector is
	begin
		if G_AES67 then
			return x"00200000";
		else
			return x"003126E9";
		end if;
	end function;
	constant C_PLL_RATIO	: std_logic_vector(31 downto 0) := f_pll_ratio;

	-- network cores
	signal c50_rmii_crs_dv	: std_logic_vector(G_AES50_PORTS - 1 downto 0);
	signal c50_rmii_rxd		: std_logic_vector(2 * G_AES50_PORTS - 1 downto 0);
	signal c50_rmii_tx_en	: std_logic_vector(G_AES50_PORTS - 1 downto 0);
	signal c50_rmii_txd		: std_logic_vector(2 * G_AES50_PORTS - 1 downto 0);
	signal c50_phy_rst_n	: std_logic_vector(G_AES50_PORTS - 1 downto 0);
	signal c50_clk_a_rx		: std_logic_vector(G_AES50_PORTS - 1 downto 0);
	signal c50_clk_a_tx		: std_logic_vector(G_AES50_PORTS - 1 downto 0);
	signal c50_clk_a_tx_en	: std_logic_vector(G_AES50_PORTS - 1 downto 0);
	signal c50_clk_b_rx		: std_logic_vector(G_AES50_PORTS - 1 downto 0);
	signal c50_clk_b_tx		: std_logic_vector(G_AES50_PORTS - 1 downto 0);
	signal c50_clk_b_tx_en	: std_logic_vector(G_AES50_PORTS - 1 downto 0);
	signal c50_uart_rx		: std_logic_vector(G_AES50_PORTS - 1 downto 0);
	signal c50_uart_tx		: std_logic_vector(G_AES50_PORTS - 1 downto 0);
	signal c67_rmii_crs_dv	: std_logic := '0';
	signal c67_rmii_rxd		: std_logic_vector(1 downto 0) := "00";
	signal c67_rmii_tx_en	: std_logic;
	signal c67_rmii_txd		: std_logic_vector(1 downto 0);
	signal c67_pll_ref		: std_logic;
	signal cinf_rmii_crs_dv	: std_logic := '0';
	signal cinf_rmii_rxd	: std_logic_vector(1 downto 0) := "00";
	signal cinf_rmii_tx_en	: std_logic;
	signal cinf_rmii_txd	: std_logic_vector(1 downto 0);

	signal clk_src			: std_logic_vector(2 downto 0);
	signal aes50_clk_to_pll	: std_logic_vector(G_AES50_PORTS - 1 downto 0);
	signal pll_in_default	: std_logic;

	-- Wishbone clock/PLL peripheral bus (0x82000000 -> u_cs2000)
	signal clkctrl_wb_adr	: std_logic_vector(29 downto 0);
	signal clkctrl_wb_dat_w	: std_logic_vector(31 downto 0);
	signal clkctrl_wb_dat_r	: std_logic_vector(31 downto 0);
	signal clkctrl_wb_sel	: std_logic_vector(3 downto 0);
	signal clkctrl_wb_cyc	: std_logic;
	signal clkctrl_wb_stb	: std_logic;
	signal clkctrl_wb_we	: std_logic;
	signal clkctrl_wb_ack	: std_logic;
	signal clkctrl_wb_err	: std_logic;

	signal pll_rst			: std_logic;
	signal rst				: std_logic;
	signal online			: std_logic;
	signal aes50_rst		: std_logic;
	signal aes50_sys_mode	: std_logic_vector(2 * G_AES50_PORTS - 1 downto 0);

	signal clk_fs512		: std_logic;
	signal clk_fs256		: std_logic;
	signal fsync			: std_logic;

	signal tdm_in			: std_logic_vector(C_LINES - 1 downto 0);
	signal tdm_out			: std_logic_vector(C_LINES - 1 downto 0);
	signal tdm_par			: std_logic_vector(C_LINES * 24 - 1 downto 0);

	type t_ultranet_ch is array (1 to 8) of std_logic_vector(23 downto 0);
	signal p16_a_ch			: t_ultranet_ch;
	signal p16_b_ch			: t_ultranet_ch;
begin
	assert not (G_AES67 and G_INFERNO)
		report "x32_common: G_AES67 and G_INFERNO are mutually exclusive" severity failure;
	assert (not G_AES67 and not G_INFERNO) or G_AES50_PORTS <= 1
		report "x32_common: the X32 has two network ports" severity failure;

	------------------------------------------------------------------------
	-- startup sequence
	------------------------------------------------------------------------
	u_reset : entity work.reset
		port map (
			clk => clk_16m_i,
			o_pripll_rst => pll_rst,
			o_secpll_rst => open,
			o_global_rst => rst,
			o_online => online);

	pll_rst_o <= pll_rst;
	io_rst_o <= rst;
	online_o <= online;
	conv_nrst_o <= online;

	aes50_sys_mode <= f_aes50_sys_mode;

	u_aes50_rst : entity work.aes50_rst
		port map (
			clk_i => clk_50m_i,
			start_i => online,
			rst_o => aes50_rst);

	------------------------------------------------------------------------
	-- CS2000 audio PLL (standalone Wishbone peripheral at 0x82000000)
	------------------------------------------------------------------------
	u_cs2000 : entity work.cs2000cp_wb
		generic map (
			G_RATIO => C_PLL_RATIO)
		port map (
			wb_clk_i    => clk_50m_i,
			wb_rst_i    => aes50_rst,
			wb_adr_i    => clkctrl_wb_adr,
			wb_dat_i    => clkctrl_wb_dat_w,
			wb_dat_o    => clkctrl_wb_dat_r,
			wb_sel_i    => clkctrl_wb_sel,
			wb_cyc_i    => clkctrl_wb_cyc,
			wb_stb_i    => clkctrl_wb_stb,
			wb_we_i     => clkctrl_wb_we,
			wb_ack_o    => clkctrl_wb_ack,
			wb_err_o    => clkctrl_wb_err,
			clk_16m_i   => clk_16m_i,
			pll_rst_i   => pll_rst,
			pll_aux_i   => pll_aux_i,
			pll_ncs_o   => pll_ncs_o,
			pll_cclk_o  => pll_cclk_o,
			pll_cdata_o => pll_cdata_o,
			clk_src_o   => clk_src);

	------------------------------------------------------------------------
	-- AUX converters
	------------------------------------------------------------------------
	gen_aux_cs42438 : if G_AUX_CS42438 generate
		signal online_z		: std_logic := '0';
		signal cfg_trigger	: std_logic := '0';
		signal cfg_start	: std_logic;
		signal cfg_busy		: std_logic;
		signal cfg_address	: std_logic_vector(7 downto 0);
		signal cfg_data		: std_logic_vector(7 downto 0);
		signal cfg_map		: std_logic_vector(7 downto 0);
	begin
		process (clk_16m_i)
		begin
			if rising_edge(clk_16m_i) then
				online_z <= online;
				cfg_trigger <= online and not online_z;
			end if;
		end process;

		u_config : entity work.cs42438_config
			port map (
				clk => clk_16m_i,
				i_start => cfg_trigger,
				i_txbusy => cfg_busy,
				o_nRST => aux_nrst_o,
				o_address => cfg_address,
				o_map => cfg_map,
				o_data => cfg_data,
				o_start => cfg_start);

		u_spi : entity work.spi_tx
			port map (
				clk => clk_16m_i,
				i_address => cfg_address,
				i_map => cfg_map,
				i_data => cfg_data,
				i_start => cfg_start,
				o_nCS => aux_ncs_o,
				o_cclk => aux_cclk_o,
				o_cdata => aux_cdata_o,
				o_busy => cfg_busy);

		aux_ad_ncs_o <= '1';
		aux_da_ncs_o <= '1';
	end generate;

	gen_aux_m8000 : if not G_AUX_CS42438 generate
		signal adc_start	: std_logic;
		signal adc_busy		: std_logic;
		signal adc_done		: std_logic;
		signal adc_address	: std_logic_vector(7 downto 0);
		signal adc_data		: std_logic_vector(7 downto 0);
		signal adc_map		: std_logic_vector(7 downto 0);
		signal adc_cclk		: std_logic;
		signal adc_cdata	: std_logic;
		signal dac_start	: std_logic;
		signal dac_busy		: std_logic;
		signal dac_address	: std_logic_vector(7 downto 0);
		signal dac_data		: std_logic_vector(7 downto 0);
		signal dac_cclk		: std_logic;
		signal dac_cdata	: std_logic;
	begin
		u_adc_config : entity work.m8000adc_config
			port map (
				clk => clk_16m_i,
				i_start => online,
				i_txbusy => adc_busy,
				o_address => adc_address,
				o_map => adc_map,
				o_data => adc_data,
				o_start => adc_start,
				o_done => adc_done);

		u_adc_spi : entity work.spi_tx
			port map (
				clk => clk_16m_i,
				i_address => adc_address,
				i_map => adc_map,
				i_data => adc_data,
				i_start => adc_start,
				o_nCS => aux_ad_ncs_o,
				o_cclk => adc_cclk,
				o_cdata => adc_cdata,
				o_busy => adc_busy);

		u_dac_config : entity work.pcm1690dac_config
			port map (
				clk => clk_16m_i,
				i_start => adc_done,
				i_txbusy => dac_busy,
				o_address => dac_address,
				o_data => dac_data,
				o_start => dac_start,
				o_done => open);

		u_dac_spi : entity work.spi_16bit_tx
			port map (
				clk => clk_16m_i,
				i_address => dac_address,
				i_data => dac_data,
				i_start => dac_start,
				o_nCS => aux_da_ncs_o,
				o_cclk => dac_cclk,
				o_cdata => dac_cdata,
				o_busy => dac_busy);

		aux_cclk_o <= adc_cclk or dac_cclk;
		aux_cdata_o <= adc_cdata or dac_cdata;
		aux_nrst_o <= online;
		aux_ncs_o <= '1';
	end generate;

	------------------------------------------------------------------------
	-- UART
	------------------------------------------------------------------------
	da_tx_o <= uart3_txd_i;
	ad0_tx_o <= uart3_txd_i;
	ad1_tx_o <= uart3_txd_i;
	card_tx_o <= uart3_txd_i;

	u_uart_collector : entity work.uart_collector
		port map (
			clk_in => clk_16m_i,
			rst_in => rst,
			uart1_in => da_rx_i,
			uart2_in => ad0_rx_i,
			uart3_in => ad1_rx_i,
			uart4_in => card_rx_i,
			card_rdy => card_rdy_i,
			uart_out => uart3_rxd_o);

	------------------------------------------------------------------------
	-- audio core
	------------------------------------------------------------------------
	tdm_in(0) <= ad0_data1_i;
	tdm_in(1) <= ad0_data0_i;
	tdm_in(2) <= ad1_data1_i;
	tdm_in(3) <= ad1_data0_i;
	tdm_in(4) <= card_in3_i;
	tdm_in(5) <= card_in2_i;
	tdm_in(6) <= card_in1_i;
	tdm_in(7) <= card_in0_i;
	tdm_in(8) <= aux_ad_i;
	tdm_in(12 downto 9) <= dsp_dout_i;
	tdm_in(13) <= dsp_doutaux_i;
	tdm_in(C_EXT_LINE - 1 downto C_BASE_LINES) <= (others => '0');
	tdm_in(C_LINES - 1 downto C_EXT_LINE) <= ext_tdm_i;

	da_data1_o <= tdm_out(0);
	da_data0_o <= tdm_out(1);
	card_out_o <= tdm_out(7 downto 4);
	aux_da_o <= tdm_out(8);
	dsp_din_o <= tdm_out(12 downto 9);
	dsp_dinaux_o <= tdm_out(13);
	ext_tdm_o <= tdm_out(C_LINES - 1 downto C_EXT_LINE);

	u_core : entity work.openaudio_core
		generic map (
			G_TDM_LINES_IN => C_LINES,
			G_TDM_LINES_OUT => C_LINES,
			G_AES50_PORTS => G_AES50_PORTS,
			G_AES50_FIRST_LINE => C_BASE_LINES,
			G_AES50_SUPPORT_44K1 => G_AES50_SUPPORT_44K1,
			G_AES50_UART_AUX => true,
			G_AES50_TDM_AUX => true,
			G_AES50_UART_FIFO_AW => 11,
			G_AES50_UART_BAUD => 115200,
			G_AES50_SIM_ASSM_SAMPLES => G_AES50_SIM_ASSM_SAMPLES,
			G_AES50_PAR_BRIDGE => G_AES50_PAR_BRIDGE,
			G_AES50_ENABLE_SRC => G_AES50_SRC,
			G_AES67 => G_AES67,
			G_AES67_FIRST_LINE => C_AES67_LINE,
			G_INFERNO => G_INFERNO,
			G_INFERNO_FIRST_LINE => C_AES67_LINE,
			G_INFERNO_RXW => G_INFERNO_RXW,
			G_PLATFORM_ID => G_PLATFORM_ID)
		port map (
			clk_fs1024_i => pll_out_i,
			fs_sync_i => '0',
			clk_fs512_o => clk_fs512,
			clk_fs256_o => clk_fs256,
			fsync_o => fsync,
			spi_ncs_i => spi_ncs_i,
			spi_clk_i => spi_clk_i,
			spi_mosi_i => spi_mosi_i,
			spi_miso_o => spi_miso_o,
			cfg_bits_o => cfg_bits_o,
			tdm_i => tdm_in,
			tdm_o => tdm_out,
			tdm_par_o => tdm_par,
			clk50_i => clk_50m_i,
			aes50_rst_i => aes50_rst,
			aes50_fs_mode_i => "01",
			aes50_sys_mode_i => aes50_sys_mode,
			aes50_aux_uart_sel_i => open,
			aes50_rmii_crs_dv_i => c50_rmii_crs_dv,
			aes50_rmii_rxd_i => c50_rmii_rxd,
			aes50_rmii_tx_en_o => c50_rmii_tx_en,
			aes50_rmii_txd_o => c50_rmii_txd,
			aes50_phy_rst_n_o => c50_phy_rst_n,
			aes50_clk_a_rx_i => c50_clk_a_rx,
			aes50_clk_a_tx_o => c50_clk_a_tx,
			aes50_clk_a_tx_en_o => c50_clk_a_tx_en,
			aes50_clk_b_rx_i => c50_clk_b_rx,
			aes50_clk_b_tx_o => c50_clk_b_tx,
			aes50_clk_b_tx_en_o => c50_clk_b_tx_en,
			aes50_tdm_aux_i => open,
			aes50_tdm_aux_o => open,
			aes50_uart_i => c50_uart_rx,
			aes50_uart_o => c50_uart_tx,
			aes50_ok_o => open,
			clk100_i => clk_100m_i,
			aes67_rst_n_i => online,
			aes67_rmii_crs_dv_i => c67_rmii_crs_dv,
			aes67_rmii_rxd_i => c67_rmii_rxd,
			aes67_rmii_tx_en_o => c67_rmii_tx_en,
			aes67_rmii_txd_o => c67_rmii_txd,
			aes67_irq_o => open,
			aes67_pll_ref_o => c67_pll_ref,
			pll_lock_i => pll_aux_i,
			aes50_clk_to_pll_o => aes50_clk_to_pll,
			clkctrl_wb_adr_o => clkctrl_wb_adr,
			clkctrl_wb_dat_o => clkctrl_wb_dat_w,
			clkctrl_wb_dat_i => clkctrl_wb_dat_r,
			clkctrl_wb_sel_o => clkctrl_wb_sel,
			clkctrl_wb_cyc_o => clkctrl_wb_cyc,
			clkctrl_wb_stb_o => clkctrl_wb_stb,
			clkctrl_wb_we_o => clkctrl_wb_we,
			clkctrl_wb_ack_i => clkctrl_wb_ack,
			clkctrl_wb_err_i => clkctrl_wb_err,
			inferno_rst_i => aes50_rst,
			inferno_rmii_crs_dv_i => cinf_rmii_crs_dv,
			inferno_rmii_rxd_i => cinf_rmii_rxd,
			inferno_rmii_tx_en_o => cinf_rmii_tx_en,
			inferno_rmii_txd_o => cinf_rmii_txd);

	------------------------------------------------------------------------
	-- network
	------------------------------------------------------------------------
	gen_port : for p in 0 to 1 generate
		gen_aes50 : if p < G_AES50_PORTS generate
			c50_rmii_crs_dv(p) <= rmii_crs_dv_i(p);
			c50_rmii_rxd(2 * p + 1 downto 2 * p) <= rmii_rxd_i(2 * p + 1 downto 2 * p);
			rmii_tx_en_o(p) <= c50_rmii_tx_en(p);
			rmii_txd_o(2 * p + 1 downto 2 * p) <= c50_rmii_txd(2 * p + 1 downto 2 * p);
			phy_rst_n_o(p) <= c50_phy_rst_n(p);
			c50_clk_a_rx(p) <= aes50_clk_a_rx_i(p);
			c50_clk_b_rx(p) <= aes50_clk_b_rx_i(p);
			aes50_clk_a_tx_o(p) <= c50_clk_a_tx(p);
			aes50_clk_b_tx_o(p) <= c50_clk_b_tx(p);
			aes50_clk_a_tx_en_o(p) <= c50_clk_a_tx_en(p);
			aes50_clk_b_tx_en_o(p) <= c50_clk_b_tx_en(p);
			aes50_clk_a_rx_nen_o(p) <= '0';
			aes50_clk_b_rx_nen_o(p) <= '0';
		end generate;

		gen_aes67 : if G_AES67 and p = C_AES67_PORT generate
			c67_rmii_crs_dv <= rmii_crs_dv_i(p);
			c67_rmii_rxd <= rmii_rxd_i(2 * p + 1 downto 2 * p);
			rmii_tx_en_o(p) <= c67_rmii_tx_en;
			rmii_txd_o(2 * p + 1 downto 2 * p) <= c67_rmii_txd;
			phy_rst_n_o(p) <= online;
		end generate;

		gen_inferno : if G_INFERNO and p = C_AES67_PORT generate
			cinf_rmii_crs_dv <= rmii_crs_dv_i(p);
			cinf_rmii_rxd <= rmii_rxd_i(2 * p + 1 downto 2 * p);
			rmii_tx_en_o(p) <= cinf_rmii_tx_en;
			rmii_txd_o(2 * p + 1 downto 2 * p) <= cinf_rmii_txd;
			phy_rst_n_o(p) <= online;
		end generate;

		gen_unused : if p >= G_AES50_PORTS and not ((G_AES67 or G_INFERNO) and p = C_AES67_PORT) generate
			rmii_tx_en_o(p) <= '0';
			rmii_txd_o(2 * p + 1 downto 2 * p) <= "00";
			phy_rst_n_o(p) <= online;
		end generate;

		-- no AES50 on this port: clock transceivers off
		gen_no_aes50 : if p >= G_AES50_PORTS generate
			aes50_clk_a_tx_o(p) <= '0';
			aes50_clk_b_tx_o(p) <= '0';
			aes50_clk_a_tx_en_o(p) <= '0';
			aes50_clk_b_tx_en_o(p) <= '0';
			aes50_clk_a_rx_nen_o(p) <= '1';
			aes50_clk_b_rx_nen_o(p) <= '1';
		end generate;
	end generate;

	gen_uart : for k in 0 to G_AES50_PORTS - 1 generate
		gen_first : if k = 0 generate
			c50_uart_rx(k) <= uart4_txd_i;
		end generate;
		gen_others : if k > 0 generate
			c50_uart_rx(k) <= '1';
		end generate;
	end generate;

	gen_uart_out : if G_AES50_PORTS > 0 generate
		uart4_rxd_o <= c50_uart_tx(0);
	end generate;

	gen_no_uart_out : if G_AES50_PORTS = 0 generate
		uart4_rxd_o <= '1';
	end generate;

	-- Clock reference mux for CS2000-CP PLL:
	--   clk_src = "001": AES50 A recovered clock (if present)
	--   clk_src = "010": AES50 B recovered clock (if present)
	--   clk_src = "000": AES67 PTP NCO (if G_AES67) else internal 16 MHz oscillator
	gen_aes67_clk : if G_AES67 generate
		pll_in_default <= c67_pll_ref;
	end generate;

	gen_no_aes67_clk : if not G_AES67 generate
		pll_in_default <= clk_16m_i;
	end generate;

	gen_pll_in_2 : if G_AES50_PORTS >= 2 generate
		pll_in_o <= aes50_clk_to_pll(0) when clk_src = "001" else
		            aes50_clk_to_pll(1) when clk_src = "010" else
		            pll_in_default;
	end generate;

	gen_pll_in_1 : if G_AES50_PORTS = 1 generate
		pll_in_o <= aes50_clk_to_pll(0) when clk_src = "001" else
		            pll_in_default;
	end generate;

	gen_pll_in_0 : if G_AES50_PORTS = 0 generate
		pll_in_o <= pll_in_default;
	end generate;

	clk_fs512_o <= clk_fs512;
	clk_fs256_o <= clk_fs256;
	fsync_o <= fsync;


	u_p16_a_demux : entity work.tdm_demux
		port map (
			bclk => clk_fs256,
			fsync => fsync,
			data_in => tdm_par(3 * 24 - 1 downto 2 * 24),
			ch1_out => p16_a_ch(1),
			ch2_out => p16_a_ch(2),
			ch3_out => p16_a_ch(3),
			ch4_out => p16_a_ch(4),
			ch5_out => p16_a_ch(5),
			ch6_out => p16_a_ch(6),
			ch7_out => p16_a_ch(7),
			ch8_out => p16_a_ch(8));

	u_p16_a : entity work.ultranet_tx
		port map (
			bit_clock => clk_fs512,
			ch1 => p16_a_ch(1),
			ch2 => p16_a_ch(2),
			ch3 => p16_a_ch(3),
			ch4 => p16_a_ch(4),
			ch5 => p16_a_ch(5),
			ch6 => p16_a_ch(6),
			ch7 => p16_a_ch(7),
			ch8 => p16_a_ch(8),
			ultranet_out_p => p16_a_txp_o,
			ultranet_out_m => p16_a_txm_o);

	u_p16_b_demux : entity work.tdm_demux
		port map (
			bclk => clk_fs256,
			fsync => fsync,
			data_in => tdm_par(4 * 24 - 1 downto 3 * 24),
			ch1_out => p16_b_ch(1),
			ch2_out => p16_b_ch(2),
			ch3_out => p16_b_ch(3),
			ch4_out => p16_b_ch(4),
			ch5_out => p16_b_ch(5),
			ch6_out => p16_b_ch(6),
			ch7_out => p16_b_ch(7),
			ch8_out => p16_b_ch(8));

	u_p16_b : entity work.ultranet_tx
		port map (
			bit_clock => clk_fs512,
			ch1 => p16_b_ch(1),
			ch2 => p16_b_ch(2),
			ch3 => p16_b_ch(3),
			ch4 => p16_b_ch(4),
			ch5 => p16_b_ch(5),
			ch6 => p16_b_ch(6),
			ch7 => p16_b_ch(7),
			ch8 => p16_b_ch(8),
			ultranet_out_p => p16_b_txp_o,
			ultranet_out_m => p16_b_txm_o);
end architecture rtl;
