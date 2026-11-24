--
-- OpenAudioFPGA - Wishbone wrapper for OpenInferno Port B (inferno_port_x32)
-- Copyright 2025-2026 OpenMixerProject
-- https://github.com/OpenMixerProject/OpenAudioFPGA
--
-- This program is free software; you can redistribute it and/or
-- modify it under the terms of the GNU General Public License
-- version 3 as published by the Free Software Foundation.
--
-- Maps Wishbone classic cycles at 0xA0000000 (byte offsets 0x000..0x3FC)
-- onto inferno_port_x32's 12-bit byte-addressed register window:
--   0x000..0x0FF : aoip_regs
--   0x100..0x1FF : inferno_regs (MAXLAT=1 / 1 ms, MAX_CH=48)
--   0x200..0x2FF : cpu_pktq
--   0x300..0x3FF : fs_phase

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity inferno_wb is
	generic (
		G_MAX_CH  : integer := 48;
		G_NTXF    : integer := 16;
		G_NRXF    : integer := 16;
		G_MAXFCH  : integer := 32;
		G_MAX_FPP : integer := 16;
		G_NR      : integer := 64;
		G_NF      : integer := 64;
		G_MAXLAT  : integer := 1;
		G_TXW     : integer := 512;
		G_RXW     : integer := 2048
	);
	port (
		clk50_i       : in  std_logic;
		rst_i         : in  std_logic;
		bclk_i        : in  std_logic;
		fsync_i       : in  std_logic;

		-- RMII PHY
		rmii_crs_dv_i : in  std_logic;
		rmii_rxd_i    : in  std_logic_vector(1 downto 0);
		rmii_tx_en_o  : out std_logic;
		rmii_txd_o    : out std_logic_vector(1 downto 0);

		-- 6x TDM8 audio interface (1-BCLK FSYNC delay)
		tdm_i         : in  std_logic_vector(5 downto 0);
		tdm_o         : out std_logic_vector(5 downto 0);

		-- Wishbone slave (clk50_i domain)
		wb_adr_i      : in  std_logic_vector(29 downto 0);
		wb_dat_i      : in  std_logic_vector(31 downto 0);
		wb_dat_o      : out std_logic_vector(31 downto 0);
		wb_sel_i      : in  std_logic_vector(3 downto 0);
		wb_cyc_i      : in  std_logic;
		wb_stb_i      : in  std_logic;
		wb_we_i       : in  std_logic;
		wb_ack_o      : out std_logic;
		wb_err_o      : out std_logic
	);
end entity inferno_wb;

architecture rtl of inferno_wb is
	component inferno_port
		generic (
			MAX_CH  : integer := 48;
			NTXF    : integer := 16;
			NRXF    : integer := 16;
			MAXFCH  : integer := 32;
			MAX_FPP : integer := 16;
			NR      : integer := 64;
			NF      : integer := 64;
			MAXLAT  : integer := 1;
			TXW     : integer := 512;
			RXW     : integer := 2048
		);
		port (
			clk50_i       : in  std_logic;
			rst_i         : in  std_logic;
			bclk_i        : in  std_logic;
			fsync_i       : in  std_logic;
			rmii_crs_dv_i : in  std_logic;
			rmii_rxd_i    : in  std_logic_vector(1 downto 0);
			rmii_tx_en_o  : out std_logic;
			rmii_txd_o    : out std_logic_vector(1 downto 0);
			tdm_i         : in  std_logic_vector(5 downto 0);
			tdm_o         : out std_logic_vector(5 downto 0);
			reg_addr_i    : in  std_logic_vector(11 downto 0);
			reg_wdata_i   : in  std_logic_vector(31 downto 0);
			reg_we_i      : in  std_logic;
			reg_re_i      : in  std_logic;
			reg_rdata_o   : out std_logic_vector(31 downto 0)
		);
	end component;

	-- Two-cycle read/write handshake:
	--   cycle 0: pulse reg_we_i or reg_re_i (registered outputs of inferno_port_x32 settle on cycle 1)
	--   cycle 1: assert wb_ack_o with valid reg_rdata_o
	signal state      : std_logic := '0';
	signal reg_addr   : std_logic_vector(11 downto 0) := (others => '0');
	signal reg_wdata  : std_logic_vector(31 downto 0) := (others => '0');
	signal reg_we     : std_logic := '0';
	signal reg_re     : std_logic := '0';
	signal reg_rdata  : std_logic_vector(31 downto 0);
	signal wb_dat_r   : std_logic_vector(31 downto 0) := (others => '0');
	signal ack        : std_logic := '0';
begin
	u_inferno : inferno_port
		generic map (
			MAX_CH  => G_MAX_CH,
			NTXF    => G_NTXF,
			NRXF    => G_NRXF,
			MAXFCH  => G_MAXFCH,
			MAX_FPP => G_MAX_FPP,
			NR      => G_NR,
			NF      => G_NF,
			MAXLAT  => G_MAXLAT,
			TXW     => G_TXW,
			RXW     => G_RXW
		)
		port map (
			clk50_i       => clk50_i,
			rst_i         => rst_i,
			bclk_i        => bclk_i,
			fsync_i       => fsync_i,
			rmii_crs_dv_i => rmii_crs_dv_i,
			rmii_rxd_i    => rmii_rxd_i,
			rmii_tx_en_o  => rmii_tx_en_o,
			rmii_txd_o    => rmii_txd_o,
			tdm_i         => tdm_i,
			tdm_o         => tdm_o,
			reg_addr_i    => reg_addr,
			reg_wdata_i   => reg_wdata,
			reg_we_i      => reg_we,
			reg_re_i      => reg_re,
			reg_rdata_o   => reg_rdata
		);

	process (clk50_i)
	begin
		if rising_edge(clk50_i) then
			reg_we <= '0';
			reg_re <= '0';
			ack    <= '0';
			if rst_i = '1' then
				state <= '0';
			else
				if state = '0' then
					if wb_cyc_i = '1' and wb_stb_i = '1' and ack = '0' then
						reg_addr  <= wb_adr_i(9 downto 0) & "00";
						reg_wdata <= wb_dat_i;
						if wb_we_i = '1' then
							reg_we <= '1';
						else
							reg_re <= '1';
						end if;
						state <= '1';
					end if;
				else
					-- Latch combinational reg_rdata on the exact edge reg_re='1' is sampled
					-- by inferno_port_x32 (before FIFO-popping registers advance).
					wb_dat_r <= reg_rdata;
					ack      <= '1';
					state    <= '0';
				end if;
			end if;
		end if;
	end process;

	wb_dat_o <= wb_dat_r;
	wb_ack_o <= ack;
	wb_err_o <= '0';
end architecture rtl;
