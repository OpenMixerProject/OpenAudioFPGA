--
-- OpenAudioFPGA - generic audio core for OpenX32 / OpenWING
-- Copyright 2025-2026 OpenMixerProject
-- https://github.com/OpenMixerProject/OpenAudioFPGA
--
-- This program is free software; you can redistribute it and/or
-- modify it under the terms of the GNU General Public License
-- version 3 as published by the Free Software Foundation.
--
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
-- GNU General Public License for more details.
--
--
-- Routing RAM of the audio matrix with a Wishbone frontend.
--
-- One 32 bit word per destination channel (word address = destination
-- line * 8 + channel, byte address = 4 * that), bits G_AW - 1 .. 0 hold the source:
--   0                  off (silence)
--   1 .. 2**G_AW - 1   source channel line * 8 + channel + 1
-- The other bits read as 0 and ignore writes. Only the low byte lane (sel(0)) is
-- written. Words beyond the 2**G_AW destinations read as 0 and ignore writes, so
-- the RAM may sit in a larger bus window.
--
-- Two clock domains: the Wishbone port (read / write, wb_clk_i) and the matrix port
-- (read only, mtx_clk_i) of a dual port RAM. Wishbone: classic cycles, one wait
-- state (ack one clock after stb), no bursts (cti / bte are ignored), never err.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity routing_wb is
	generic (
		G_AW			: natural := 8;		-- log2 of the destinations, also the source width
		G_WIN_AW		: natural := 14		-- word address bits of the bus window (64 KiB)
	);
	port (
		-- Wishbone slave
		wb_clk_i		: in  std_logic;
		wb_adr_i		: in  std_logic_vector(29 downto 0);	-- word address
		wb_dat_i		: in  std_logic_vector(31 downto 0);
		wb_dat_o		: out std_logic_vector(31 downto 0);
		wb_sel_i		: in  std_logic_vector(3 downto 0);
		wb_cyc_i		: in  std_logic;
		wb_stb_i		: in  std_logic;
		wb_we_i			: in  std_logic;
		wb_ack_o		: out std_logic;
		wb_err_o		: out std_logic;

		-- matrix: source of the destination channel_idx, one clock latency
		mtx_clk_i		: in  std_logic;
		mtx_channel_i	: in  std_logic_vector(G_AW - 1 downto 0);
		mtx_source_o	: out std_logic_vector(G_AW - 1 downto 0)
	);
end entity routing_wb;

architecture rtl of routing_wb is
	type ram_t is array (0 to 2**G_AW - 1) of std_logic_vector(G_AW - 1 downto 0);
	signal ram		: ram_t := (others => (others => '0'));

	signal wb_addr	: unsigned(G_AW - 1 downto 0);
	signal in_range	: std_logic;
	signal ack		: std_logic := '0';
	signal rd_data	: std_logic_vector(G_AW - 1 downto 0);
	signal rd_valid	: std_logic;
begin
	wb_addr <= unsigned(wb_adr_i(G_AW - 1 downto 0));
	in_range <= '1' when unsigned(wb_adr_i(G_WIN_AW - 1 downto G_AW)) = 0 else '0';

	-- Wishbone port
	process (wb_clk_i)
	begin
		if rising_edge(wb_clk_i) then
			ack <= '0';
			if wb_cyc_i = '1' and wb_stb_i = '1' and ack = '0' then
				ack <= '1';
				if wb_we_i = '1' and wb_sel_i(0) = '1' and in_range = '1' then
					ram(to_integer(wb_addr)) <= wb_dat_i(G_AW - 1 downto 0);
				end if;
			end if;
			rd_data <= ram(to_integer(wb_addr));
			rd_valid <= in_range;
		end if;
	end process;

	wb_ack_o <= ack;
	wb_err_o <= '0';
	wb_dat_o <= std_logic_vector(resize(unsigned(rd_data), 32)) when rd_valid = '1' else (others => '0');

	-- matrix port
	process (mtx_clk_i)
	begin
		if rising_edge(mtx_clk_i) then
			mtx_source_o <= ram(to_integer(unsigned(mtx_channel_i)));
		end if;
	end process;
end architecture rtl;
