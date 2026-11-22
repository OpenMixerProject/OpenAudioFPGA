-- 
--   ____                  __   ______ ___  
--  / __ \                 \ \ / /___ \__ \ 
-- | |  | |_ __   ___ _ __  \ V /  __) | ) |
-- | |  | | '_ \ / _ \ '_ \  > <  |__ < / / 
-- | |__| | |_) |  __/ | | |/ . \ ___) / /_ 
--  \____/| .__/ \___|_| |_/_/ \_\____/____|
--        | |                               
--        |_|                               
-- 
-- OpenX32 - The OpenSource Operating System for the Behringer X32 Audio Mixing Console
-- Copyright 2025-2026 OpenMixerProject
-- https://github.com/OpenMixerProject/OpenX32
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
-- Audio clock tree of the X32 (512fs / 256fs / fs), frame-locked to the AES67 core
-- v0.1.0, 11.11.2026
-- OpenX32 Project
-- https://github.com/OpenMixerProject/OpenX32
-- 

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity audioclk is
	generic (

		AES67_SYNC_CNT	: natural range 0 to 511 := 0;

		FS_ADVANCE		: natural range 0 to 511 := 3
	);
	port (
		clock_to_aes67_i : in std_logic;
		aes67_fs_i : in std_logic; -- frame sync of the AES67 core 
		aes67_bclk_i : in std_logic;
		fs_x_1024_i		: in std_logic; -- 49.152 MHz
		fs_x_512_o		: out std_logic; -- 24.576 MHz
		fs_x_256_o		: out std_logic; -- 12.288 MHz
		fs_x_128_o		: out std_logic; -- 6.144 MHz
		fs_x_64_o		: out std_logic; -- 3.072 MHz
		fs_o				: out std_logic -- 48 kHz
	);
end entity;


architecture behavioral of audioclk is
	signal clk_a			: std_logic := '0';
	signal clk_b			: std_logic := '0';
	signal clk_c			: std_logic := '0';
	signal clk_d			: std_logic := '0';
	signal fs				: std_logic := '0';
	signal cnt				: unsigned(8 downto 0) := (others => '0');
	signal aes67_fs_z		: std_logic := '0';
	signal aes67_fs_zz	: std_logic := '0';
begin
	process (fs_x_1024_i)
		variable c		: unsigned(8 downto 0);
		variable c_fs	: unsigned(8 downto 0);
	begin
		if rising_edge(fs_x_1024_i) then
			if (clk_a = '0') then
				clk_a <= '1';
				aes67_fs_z <= aes67_fs_i;
				aes67_fs_zz <= aes67_fs_z;

				if (aes67_fs_z = '1' and aes67_fs_zz = '0') then
					c := to_unsigned(AES67_SYNC_CNT, 9);
				else
					c := cnt;
				end if;
				cnt <= c + 1;

				c_fs := c + FS_ADVANCE;
				clk_b <= not c(0);
				clk_c <= not c(1);
				clk_d <= not c(2);
				fs <= not c_fs(8);
			else
				-- falling edge of clk_a
				clk_a <= '0';
			end if;
		end if;
	end process;
	
	-- output the signals
	fs_x_512_o <= clk_a;
	fs_x_256_o <= clk_b;
	fs_x_128_o <= clk_c;
	fs_x_64_o  <= clk_d;
	fs_o <= fs;
end behavioral;
