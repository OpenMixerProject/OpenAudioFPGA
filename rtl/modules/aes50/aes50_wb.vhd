--
-- OpenAudioFPGA - Modular N-Port AES50v2 + 96 kHz SRC + Wishbone Aux Module
-- Copyright 2025-2026 OpenMixerProject
-- https://github.com/OpenMixerProject/OpenAudioFPGA
--
-- This program is free software; you can redistribute it and/or
-- modify it under the terms of the GNU General Public License
-- version 3 as published by the Free Software Foundation.
--
-- Vendor-neutral, console-neutral AES50v2 module parameterized for any number of
-- ports (G_PORTS = 1..8: e.g. 1-2 on X32, 3 on WING).
--
-- Wishbone classic slave (clk50_i, 1 wait state, 0x40 byte stride per port k):
--   base + k*0x40 + 0x00 (RO) : PORT_INFO     = [31:16] 0xA502 ("A502" magic),
--                                               [15:8]  G_PORTS,
--                                               [7:4]   port index k,
--                                               [0]     G_ENABLE_SRC (1 = 96k SRC built)
--   base + k*0x40 + 0x04 (RW) : PORT_CTRL     = [0]   fs96 (0=48k/48ch, 1=96k/24ch+SRC),
--                                               [2:1] sys_mode ("00"=Slave, "01"=Master),
--                                               [8]   soft_rst
--   base + k*0x40 + 0x08 (RO) : PORT_STATUS   = [0] aes_ok, [1] rx_ok, [2] tx_started,
--                                               [3] fmt_valid, [15:8] fmt
--   base + k*0x40 + 0x0C (RO) : PORT_DROP_CNT = 32-bit RX dropped block counter
--   base + k*0x40 + 0x10 (WO) : AUX_TX        = [7:0] byte pushed to port k aux TX FIFO
--   base + k*0x40 + 0x14 (RO) : AUX_RX        = [7:0] byte, [8] valid, [31:16] rx_count (pops 1 byte)
--   base + k*0x40 + 0x18 (RO) : AUX_STATUS    = [31:16] tx_count, [15:0] rx_count

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity aes50_wb is
	generic (
		G_PORTS             : positive range 1 to 8 := 2;
		G_ENABLE_SRC        : boolean := true;
		G_ENABLE_AUX        : boolean := true;
		G_AUX_FIFO_AW       : natural := 10;
		G_SIM_ASSM_FRAMES   : natural := 2048
	);
	port (
		clk50_i             : in  std_logic;
		rst_i               : in  std_logic;
		clk_1024xfs_i       : in  std_logic;
		bclk_i              : in  std_logic;
		fsync_i             : in  std_logic;
		pll_lock_i          : in  std_logic := '1';

		-- Wishbone slave (clk50_i domain)
		wb_adr_i            : in  std_logic_vector(29 downto 0);
		wb_dat_i            : in  std_logic_vector(31 downto 0);
		wb_dat_o            : out std_logic_vector(31 downto 0);
		wb_sel_i            : in  std_logic_vector(3 downto 0);
		wb_cyc_i            : in  std_logic;
		wb_stb_i            : in  std_logic;
		wb_we_i             : in  std_logic;
		wb_ack_o            : out std_logic;
		wb_err_o            : out std_logic;

		-- Per-port RMII PHY interfaces
		rmii_crs_dv_i       : in  std_logic_vector(G_PORTS - 1 downto 0);
		rmii_rxd_i          : in  std_logic_vector(2 * G_PORTS - 1 downto 0);
		rmii_tx_en_o        : out std_logic_vector(G_PORTS - 1 downto 0);
		rmii_txd_o          : out std_logic_vector(2 * G_PORTS - 1 downto 0);
		phy_rst_n_o         : out std_logic_vector(G_PORTS - 1 downto 0);

		-- Per-port AES50 LVDS clock transceivers & recovered clock
		aes50_clk_a_rx_i    : in  std_logic_vector(G_PORTS - 1 downto 0);
		aes50_clk_a_tx_o    : out std_logic_vector(G_PORTS - 1 downto 0);
		aes50_clk_a_tx_en_o : out std_logic_vector(G_PORTS - 1 downto 0);
		aes50_clk_b_rx_i    : in  std_logic_vector(G_PORTS - 1 downto 0);
		aes50_clk_b_tx_o    : out std_logic_vector(G_PORTS - 1 downto 0);
		aes50_clk_b_tx_en_o : out std_logic_vector(G_PORTS - 1 downto 0);
		clk_to_pll_o        : out std_logic_vector(G_PORTS - 1 downto 0);

		-- Per-port 6x TDM8 audio lines (port k uses 6*k+5 downto 6*k)
		tdm_i               : in  std_logic_vector(6 * G_PORTS - 1 downto 0);
		tdm_o               : out std_logic_vector(6 * G_PORTS - 1 downto 0);
		aes_ok_o            : out std_logic_vector(G_PORTS - 1 downto 0)
	);
end entity aes50_wb;

architecture rtl of aes50_wb is
	type t_mode_arr is array (0 to G_PORTS - 1) of std_logic_vector(1 downto 0);
	type t_byte_arr is array (0 to G_PORTS - 1) of std_logic_vector(7 downto 0);
	type t_cnt16_arr is array (0 to G_PORTS - 1) of std_logic_vector(15 downto 0);
	type t_cnt32_arr is array (0 to G_PORTS - 1) of unsigned(31 downto 0);

	signal p_fs96       : std_logic_vector(G_PORTS - 1 downto 0) := (others => '0');
	signal p_sys_mode   : t_mode_arr := (others => "01"); -- Default AES50 Master
	signal p_soft_rst   : std_logic_vector(G_PORTS - 1 downto 0) := (others => '0');

	signal p_aes_ok     : std_logic_vector(G_PORTS - 1 downto 0);
	signal p_rx_ok      : std_logic_vector(G_PORTS - 1 downto 0);
	signal p_tx_st      : std_logic_vector(G_PORTS - 1 downto 0);
	signal p_drop       : std_logic_vector(G_PORTS - 1 downto 0);
	signal p_fmt_v      : std_logic_vector(G_PORTS - 1 downto 0);
	signal p_fmt        : t_byte_arr;
	signal p_drop_cnt   : t_cnt32_arr := (others => (others => '0'));

	signal p_aux_tx_we  : std_logic_vector(G_PORTS - 1 downto 0) := (others => '0');
	signal aux_tx_byte  : std_logic_vector(7 downto 0) := (others => '0');
	signal p_aux_tx_cnt : t_cnt16_arr;
	signal p_aux_rx_rd  : std_logic_vector(G_PORTS - 1 downto 0) := (others => '0');
	signal p_aux_rx_b   : t_byte_arr;
	signal p_aux_rx_v   : std_logic_vector(G_PORTS - 1 downto 0);
	signal p_aux_rx_cnt : t_cnt16_arr;

	signal ack          : std_logic := '0';
	signal rd_data      : std_logic_vector(31 downto 0) := (others => '0');

	function f_src_bit return std_logic is
	begin
		if G_ENABLE_SRC then return '1'; else return '0'; end if;
	end function;
begin
	aes_ok_o <= p_aes_ok;
	wb_ack_o <= ack;
	wb_err_o <= '0';
	wb_dat_o <= rd_data;

	gen_ports : for k in 0 to G_PORTS - 1 generate
		u_bridge : entity work.aes50_par_bridge
			generic map (
				G_ENABLE_SRC      => G_ENABLE_SRC,
				G_ENABLE_AUX      => G_ENABLE_AUX,
				G_AUX_FIFO_AW     => G_AUX_FIFO_AW,
				G_SIM_ASSM_FRAMES => G_SIM_ASSM_FRAMES)
			port map (
				clk50_i             => clk50_i,
				rst_i               => rst_i or p_soft_rst(k),
				clk_1024xfs_i       => clk_1024xfs_i,
				bclk_i              => bclk_i,
				fsync_i             => fsync_i,
				fs96_i              => p_fs96(k),
				sys_mode_i          => p_sys_mode(k),
				rmii_crs_dv_i       => rmii_crs_dv_i(k),
				rmii_rxd_i          => rmii_rxd_i(2 * k + 1 downto 2 * k),
				rmii_tx_en_o        => rmii_tx_en_o(k),
				rmii_txd_o          => rmii_txd_o(2 * k + 1 downto 2 * k),
				phy_rst_n_o         => phy_rst_n_o(k),
				aes50_clk_a_rx_i    => aes50_clk_a_rx_i(k),
				aes50_clk_a_tx_o    => aes50_clk_a_tx_o(k),
				aes50_clk_a_tx_en_o => aes50_clk_a_tx_en_o(k),
				aes50_clk_b_rx_i    => aes50_clk_b_rx_i(k),
				aes50_clk_b_tx_o    => aes50_clk_b_tx_o(k),
				aes50_clk_b_tx_en_o => aes50_clk_b_tx_en_o(k),
				pll_lock_n_i        => not pll_lock_i,
				clk_to_pll_o        => clk_to_pll_o(k),
				tdm_i               => tdm_i(6 * k + 5 downto 6 * k),
				tdm_o               => tdm_o(6 * k + 5 downto 6 * k),
				aux_tx_we_i         => p_aux_tx_we(k),
				aux_tx_byte_i       => aux_tx_byte,
				aux_tx_count_o      => p_aux_tx_cnt(k),
				aux_rx_rd_i         => p_aux_rx_rd(k),
				aux_rx_byte_o       => p_aux_rx_b(k),
				aux_rx_valid_o      => p_aux_rx_v(k),
				aux_rx_count_o      => p_aux_rx_cnt(k),
				aes_ok_o            => p_aes_ok(k),
				rx_ok_o             => p_rx_ok(k),
				tx_started_o        => p_tx_st(k),
				rx_block_drop_o     => p_drop(k),
				fmt_valid_o         => p_fmt_v(k),
				fmt_o               => p_fmt(k));
	end generate;

	process (clk50_i)
		variable port_idx : natural range 0 to 7;
		variable reg_off  : std_logic_vector(5 downto 0);
	begin
		if rising_edge(clk50_i) then
			ack         <= '0';
			p_aux_tx_we <= (others => '0');
			p_aux_rx_rd <= (others => '0');

			if rst_i = '1' then
				p_fs96     <= (others => '0');
				p_sys_mode <= (others => "01");
				p_soft_rst <= (others => '0');
				p_drop_cnt <= (others => (others => '0'));
				rd_data    <= (others => '0');
			else
				for k in 0 to G_PORTS - 1 loop
					if p_drop(k) = '1' then
						p_drop_cnt(k) <= p_drop_cnt(k) + 1;
					end if;
				end loop;

				if wb_cyc_i = '1' and wb_stb_i = '1' and ack = '0' then
					ack      <= '1';
					port_idx := to_integer(unsigned(wb_adr_i(6 downto 4)));
					reg_off  := wb_adr_i(3 downto 0) & "00";

					if unsigned(wb_adr_i(9 downto 7)) = 0 and port_idx < G_PORTS then
						if wb_we_i = '1' then
							case reg_off is
								when "000100" => -- 0x04 PORT_CTRL
									if wb_sel_i(0) = '1' then
										p_fs96(port_idx)     <= wb_dat_i(0);
										p_sys_mode(port_idx) <= wb_dat_i(2 downto 1);
									end if;
									if wb_sel_i(1) = '1' then
										p_soft_rst(port_idx) <= wb_dat_i(8);
									end if;
								when "010000" => -- 0x10 AUX_TX
									if wb_sel_i(0) = '1' then
										aux_tx_byte           <= wb_dat_i(7 downto 0);
										p_aux_tx_we(port_idx) <= '1';
									end if;
								when others =>
									null;
							end case;
						else
							case reg_off is
								when "000000" => -- 0x00 PORT_INFO
									rd_data <= x"A502" &
									           std_logic_vector(to_unsigned(G_PORTS, 8)) &
									           std_logic_vector(to_unsigned(port_idx, 4)) &
									           "000" & f_src_bit;
								when "000100" => -- 0x04 PORT_CTRL
									rd_data <= x"00000" & "000" & p_soft_rst(port_idx) &
									           "00000" & p_sys_mode(port_idx) & p_fs96(port_idx);
								when "001000" => -- 0x08 PORT_STATUS
									rd_data <= x"0000" & p_fmt(port_idx) & "0000" &
									           p_fmt_v(port_idx) & p_tx_st(port_idx) &
									           p_rx_ok(port_idx) & p_aes_ok(port_idx);
								when "001100" => -- 0x0C PORT_DROP_CNT
									rd_data <= std_logic_vector(p_drop_cnt(port_idx));
								when "010100" => -- 0x14 AUX_RX
									rd_data <= p_aux_rx_cnt(port_idx) & "0000000" &
									           p_aux_rx_v(port_idx) & p_aux_rx_b(port_idx);
									if p_aux_rx_v(port_idx) = '1' then
										p_aux_rx_rd(port_idx) <= '1';
									end if;
								when "011000" => -- 0x18 AUX_STATUS
									rd_data <= p_aux_tx_cnt(port_idx) & p_aux_rx_cnt(port_idx);
								when others =>
									rd_data <= (others => '0');
							end case;
						end if;
					else
						if wb_we_i = '0' then
							rd_data <= (others => '0');
						end if;
					end if;
				end if;
			end if;
		end if;
	end process;
end architecture rtl;
