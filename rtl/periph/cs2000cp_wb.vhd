--
-- OpenAudioFPGA - Standalone CS2000-CP Clock Control & PLL Wishbone Peripheral
-- Copyright 2025-2026 OpenMixerProject
-- https://github.com/OpenMixerProject/OpenAudioFPGA
--
-- This program is free software; you can redistribute it and/or
-- modify it under the terms of the GNU General Public License
-- version 3 as published by the Free Software Foundation.
--
-- Console-level peripheral for boards using a Cirrus Logic CS2000-CP audio PLL
-- (e.g. Behringer X32/M32). Encapsulates boot-time CS2000-CP init, runtime
-- Wishbone SPI register writes (with 50 MHz <-> 16 MHz CDC), and clock source
-- selection.
--
-- Wishbone classic slave (wb_clk_i, 1 wait state, base 0x82000000):
--   +0x00 (RO) : MAGIC       = 0x4353324B ("CS2K")
--   +0x04 (RW) : CLK_CTRL    = [2:0] clk_src (0 = default/internal, 1..N = ext ref)
--   +0x08 (RO) : CLK_STATUS  = [0] pll_lock, [1] boot_done
--   +0x40 (RW) : CS2K_CMD    = [15:8] reg_map, [7:0] data (compatible with inferno-portd)
--   +0x44 (RO) : CS2K_STATUS = [31] busy or not boot_done, [15:0] cs2k_cmd
--   +0x48 (WO) : CS2K_GO     = write bit 0 = '1' to start SPI transfer

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity cs2000cp_wb is
	generic (
		G_RATIO : std_logic_vector(31 downto 0) := x"003126E9"
	);
	port (
		-- Wishbone bus domain (e.g. 50 MHz)
		wb_clk_i     : in  std_logic;
		wb_rst_i     : in  std_logic;
		wb_adr_i     : in  std_logic_vector(29 downto 0);
		wb_dat_i     : in  std_logic_vector(31 downto 0);
		wb_dat_o     : out std_logic_vector(31 downto 0);
		wb_sel_i     : in  std_logic_vector(3 downto 0);
		wb_cyc_i     : in  std_logic;
		wb_stb_i     : in  std_logic;
		wb_we_i      : in  std_logic;
		wb_ack_o     : out std_logic;
		wb_err_o     : out std_logic;

		-- CS2000-CP SPI & oscillator domain (16 MHz)
		clk_16m_i    : in  std_logic;
		pll_rst_i    : in  std_logic;
		pll_aux_i    : in  std_logic := '1';
		pll_ncs_o    : out std_logic;
		pll_cclk_o   : out std_logic;
		pll_cdata_o  : out std_logic;

		-- Selected clock source index (wb_clk_i domain, quasi-static)
		clk_src_o    : out std_logic_vector(2 downto 0)
	);
end entity cs2000cp_wb;

architecture rtl of cs2000cp_wb is
	-- Wishbone domain signals
	signal ack              : std_logic := '0';
	signal rd_data          : std_logic_vector(31 downto 0) := (others => '0');
	signal clk_src          : std_logic_vector(2 downto 0) := "000";
	signal pll_lock_s       : std_logic_vector(1 downto 0) := "00";
	signal boot_done_s      : std_logic_vector(1 downto 0) := "00";
	signal cs2k_cmd         : std_logic_vector(15 downto 0) := (others => '0');
	signal cs2k_busy        : std_logic := '0';
	signal cs2k_req_tgl     : std_logic := '0';
	signal cs2k_ack_s       : std_logic_vector(2 downto 0) := "000";

	-- 16 MHz domain signals
	signal boot_start       : std_logic;
	signal boot_addr        : std_logic_vector(7 downto 0);
	signal boot_map         : std_logic_vector(7 downto 0);
	signal boot_data        : std_logic_vector(7 downto 0);
	signal boot_done        : std_logic;

	signal cs2k_req_s       : std_logic_vector(2 downto 0) := "000";
	signal cs2k_ack_tgl     : std_logic := '0';
	type host_st_t is (H_IDLE, H_WAIT_START, H_WAIT_DONE);
	signal host_st          : host_st_t := H_IDLE;
	signal host_start       : std_logic := '0';

	signal spi_start        : std_logic;
	signal spi_busy         : std_logic;
	signal spi_addr         : std_logic_vector(7 downto 0);
	signal spi_map          : std_logic_vector(7 downto 0);
	signal spi_data         : std_logic_vector(7 downto 0);
begin
	clk_src_o <= clk_src;
	wb_ack_o  <= ack;
	wb_err_o  <= '0';
	wb_dat_o  <= rd_data;

	-- Boot-time CS2000-CP initializer (16 MHz domain)
	u_boot : entity work.cs2000cp_config
		generic map (G_RATIO => G_RATIO)
		port map (
			clk       => clk_16m_i,
			i_start   => pll_rst_i,
			i_txbusy  => spi_busy,
			o_address => boot_addr,
			o_map     => boot_map,
			o_data    => boot_data,
			o_start   => boot_start,
			o_done    => boot_done);

	-- Host CS2000-CP SPI transfer FSM (16 MHz domain, active after boot init)
	process (clk_16m_i)
	begin
		if rising_edge(clk_16m_i) then
			host_start <= '0';
			cs2k_req_s <= cs2k_req_s(1 downto 0) & cs2k_req_tgl;
			case host_st is
				when H_IDLE =>
					if boot_done = '1' and cs2k_req_s(2) /= cs2k_req_s(1) then
						host_start <= '1';
						host_st    <= H_WAIT_START;
					end if;
				when H_WAIT_START =>
					if spi_busy = '1' then
						host_st <= H_WAIT_DONE;
					end if;
				when H_WAIT_DONE =>
					if spi_busy = '0' then
						cs2k_ack_tgl <= not cs2k_ack_tgl;
						host_st      <= H_IDLE;
					end if;
			end case;
		end if;
	end process;

	spi_start <= host_start           when boot_done = '1' else boot_start;
	spi_addr  <= x"9E"                when boot_done = '1' else boot_addr;
	spi_map   <= cs2k_cmd(15 downto 8) when boot_done = '1' else boot_map;
	spi_data  <= cs2k_cmd(7 downto 0)  when boot_done = '1' else boot_data;

	u_spi : entity work.spi_tx
		port map (
			clk       => clk_16m_i,
			i_address => spi_addr,
			i_map     => spi_map,
			i_data    => spi_data,
			i_start   => spi_start,
			o_nCS     => pll_ncs_o,
			o_cclk    => pll_cclk_o,
			o_cdata   => pll_cdata_o,
			o_busy    => spi_busy);

	-- Wishbone register interface (wb_clk_i domain)
	process (wb_clk_i)
		variable byte_off : std_logic_vector(7 downto 0);
	begin
		if rising_edge(wb_clk_i) then
			ack <= '0';
			if wb_rst_i = '1' then
				clk_src   <= "000";
				cs2k_cmd  <= (others => '0');
				cs2k_busy <= '0';
				rd_data   <= (others => '0');
			else
				pll_lock_s  <= pll_lock_s(0) & pll_aux_i;
				boot_done_s <= boot_done_s(0) & boot_done;
				cs2k_ack_s  <= cs2k_ack_s(1 downto 0) & cs2k_ack_tgl;
				if cs2k_ack_s(2) /= cs2k_ack_s(1) then
					cs2k_busy <= '0';
				end if;

				if wb_cyc_i = '1' and wb_stb_i = '1' and ack = '0' then
					ack      <= '1';
					byte_off := wb_adr_i(5 downto 0) & "00";
					if unsigned(wb_adr_i(9 downto 6)) = 0 then
						if wb_we_i = '1' then
							case byte_off is
								when x"04" =>
									if wb_sel_i(0) = '1' then
										clk_src <= wb_dat_i(2 downto 0);
									end if;
								when x"40" =>
									if wb_sel_i(0) = '1' then
										cs2k_cmd(7 downto 0) <= wb_dat_i(7 downto 0);
									end if;
									if wb_sel_i(1) = '1' then
										cs2k_cmd(15 downto 8) <= wb_dat_i(15 downto 8);
									end if;
								when x"48" =>
									if wb_sel_i(0) = '1' and wb_dat_i(0) = '1' and cs2k_busy = '0' and boot_done_s(1) = '1' then
										cs2k_req_tgl <= not cs2k_req_tgl;
										cs2k_busy    <= '1';
									end if;
								when others =>
									null;
							end case;
						else
							case byte_off is
								when x"00" =>
									rd_data <= x"4353324B"; -- "CS2K"
								when x"04" =>
									rd_data <= (31 downto 3 => '0') & clk_src;
								when x"08" =>
									rd_data <= (31 downto 2 => '0') & boot_done_s(1) & pll_lock_s(1);
								when x"40" =>
									rd_data <= x"0000" & cs2k_cmd;
								when x"44" =>
									rd_data <= (cs2k_busy or not boot_done_s(1)) & "000000000000000" & cs2k_cmd;
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
