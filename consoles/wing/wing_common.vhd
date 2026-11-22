-- SPDX-License-Identifier: GPL-3.0-only
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity wing_common is
    generic (
        G_AES50_PORTS : natural range 0 to 3 := 1;
        G_DSP_LANES : positive;
        G_RX_USED, G_TX_USED : std_logic_vector(15 * G_DSP_LANES - 1 downto 0);
        G_RX_DSP, G_TX_DSP : std_logic_vector(2 * G_DSP_LANES - 1 downto 0)
    );
    port (
        clk_audio, clk_rmii, host_sck, host_mosi, ctrl_cs_n, dsp_cs_n : in std_logic;
        host_miso, host_miso_oe, dsp_bclk, dsp_clkin : out std_logic;
        dpi_miso : in std_logic_vector(3 downto 0);
        dpi_sel, dpi_sck, dpi_mosi, dsp_reset_n, dsp_fs : out std_logic_vector(3 downto 0);
        dsp_return : in std_logic_vector(G_DSP_LANES - 1 downto 0);
        dsp_send : out std_logic_vector(G_DSP_LANES - 1 downto 0);
        rmii_crs_dv, sync_a_rx, sync_b_rx : in std_logic_vector(G_AES50_PORTS - 1 downto 0);
        rmii_rxd : in std_logic_vector(2 * G_AES50_PORTS - 1 downto 0);
        rmii_tx_en, phy_reset_n, sync_a_tx, sync_a_de, sync_b_tx, sync_b_de : out std_logic_vector(G_AES50_PORTS - 1 downto 0);
        rmii_txd : out std_logic_vector(2 * G_AES50_PORTS - 1 downto 0);
        bench_observe : in std_logic := '0'
    );
end entity;

architecture rtl of wing_common is
    signal phase : unsigned(9 downto 0);
    signal started : std_logic_vector(3 downto 0) := (others => '0');
    signal rmii_started : std_logic_vector(3 downto 0) := (others => '0');
    signal audio_ready : std_logic := '0';
    signal rst, rmii_rst, ready, ctrl_sel, dsp_sel, ctrl_miso, dsp_miso : std_logic;
    signal rx_dv : std_logic_vector(rmii_crs_dv'range);
    signal rx_dibits, tx_dibits : std_logic_vector(rmii_rxd'range);
    signal tx_enable : std_logic_vector(rmii_tx_en'range);
    signal req_reset, req_fs, req_valid : std_logic_vector(3 downto 0);
    signal release_n, armed, sending, accepting : std_logic_vector(3 downto 0) := (others => '0');
    signal valid_pending : std_logic_vector(3 downto 0) := (others => '0');
    signal observe_meta, observe_sync : std_logic := '0';
    attribute async_reg : boolean;
    attribute async_reg of rmii_started, observe_meta, observe_sync : signal is true;
    signal from_dsp_valid, to_dsp_enable : std_logic_vector(G_DSP_LANES - 1 downto 0);
    constant RESET_MASK : std_logic_vector(3 downto 0) := "1011";
    function lane_owner(packed : std_logic_vector; n : natural) return natural is
    begin
        return to_integer(unsigned(packed(2*n+1 downto 2*n)));
    end;
begin
    rst <= not started(3);
    rmii_rst <= not rmii_started(3);
    process(clk_rmii)
    begin
        if rising_edge(clk_rmii) then
            rmii_started <= rmii_started(2 downto 0) & audio_ready;
            rx_dv <= rmii_crs_dv;
            rx_dibits <= rmii_rxd;
        end if;
        if falling_edge(clk_rmii) then
            rmii_tx_en <= tx_enable;
            rmii_txd <= tx_dibits;
        end if;
    end process;

    process(clk_audio)
        variable permit : std_logic_vector(3 downto 0);
    begin
        if rising_edge(clk_audio) then
            started <= started(2 downto 0) & '1';
            audio_ready <= ready;
            observe_meta <= bench_observe;
            observe_sync <= observe_meta;
            if ready = '0' then
                release_n <= (others => '0'); armed <= (others => '0');
                sending <= (others => '0'); accepting <= (others => '0');
                valid_pending <= (others => '0');
            elsif phase = 1019 then
                permit := req_reset or not RESET_MASK;
                release_n <= req_reset and RESET_MASK;
                -- A just-released DSP cannot emit a frame until a later arm.
                armed <= req_fs and permit and (release_n or not RESET_MASK);
                valid_pending <= req_valid and sending;
            elsif phase = 0 then
                sending <= armed;
            elsif phase = 1 then
                accepting <= valid_pending and armed and (release_n or not RESET_MASK);
            end if;
            -- Drive FS on rising SPORT BCLK, one bit before the MSB launch.
            if phase = 1022 and ready = '1' then dsp_fs <= armed;
            elsif phase = 0 or ready = '0' then dsp_fs <= (others => '0'); end if;
        end if;
    end process;
    dsp_reset_n <= release_n;
    dsp_clkin <= not phase(1);

    lanes : for i in 0 to G_DSP_LANES - 1 generate
        from_dsp_valid(i) <= accepting(lane_owner(G_RX_DSP, i));
        -- The slot loads its MSB on the same edge that commits sending.
        -- Use the precomputed frame decision there; no gate in the pad path.
        to_dsp_enable(i) <= armed(lane_owner(G_TX_DSP, i));
    end generate;

    ctrl_sel <= ctrl_cs_n or not dsp_cs_n;
    dsp_sel <= dsp_cs_n or not ctrl_cs_n;
    host_miso <= ctrl_miso when ctrl_sel = '0' else dsp_miso;
    host_miso_oe <= not (ctrl_sel and dsp_sel) and not rst;
    passthrough : entity work.dsp_spi
        port map (clk_audio, rst, dsp_sel, host_sck, host_mosi, dsp_miso, dpi_miso, dpi_sel, dpi_sck, dpi_mosi);

    core : entity work.openaudio_core
        generic map (
            G_TDM_LINES_IN => 96, G_TDM_LINES_OUT => 96, G_FRAME_ROUTES => 768,
            G_DSP_LANES => G_DSP_LANES, G_DSP_RX_USED => G_RX_USED, G_DSP_TX_USED => G_TX_USED,
            G_AES50_PORTS => G_AES50_PORTS, G_AES50_FIRST_LINE => 0,
            G_AES50_UART_AUX => false, G_AES50_TDM_AUX => false, G_PLATFORM_ID => 3)
        port map (
            clk_fs1024_i => clk_audio, clk50_i => clk_rmii, clk_fs512_o => dsp_bclk,
            clk_fs256_o => open, fsync_o => open, frame_reset_i => rst,
            frame_phase_o => phase, frame_ready_o => ready, frame_status_extra_i => observe_sync,
            dsp_tdm_i => dsp_return, dsp_valid_i => from_dsp_valid, dsp_tdm_o => dsp_send,
            dsp_tx_enable_i => to_dsp_enable,
            dsp_reset_release_o => req_reset, dsp_audio_enable_o => req_fs, dsp_audio_valid_o => req_valid,
            spi_ncs_i => ctrl_sel, spi_clk_i => host_sck, spi_mosi_i => host_mosi, spi_miso_o => ctrl_miso,
            cfg_bits_o => open, tdm_i => (others => '0'), tdm_o => open, tdm_par_o => open,
            aes50_rst_i => rmii_rst, aes50_sys_mode_i => (others => '1'), -- AES master, TDM slave
            aes50_rmii_crs_dv_i => rx_dv, aes50_rmii_rxd_i => rx_dibits,
            aes50_rmii_tx_en_o => tx_enable, aes50_rmii_txd_o => tx_dibits, aes50_phy_rst_n_o => phy_reset_n,
            aes50_clk_a_rx_i => sync_a_rx, aes50_clk_a_tx_o => sync_a_tx, aes50_clk_a_tx_en_o => sync_a_de,
            aes50_clk_b_rx_i => sync_b_rx, aes50_clk_b_tx_o => sync_b_tx, aes50_clk_b_tx_en_o => sync_b_de,
            aes50_tdm_aux_o => open, aes50_uart_o => open, aes50_ok_o => open,
            aes67_rmii_tx_en_o => open, aes67_rmii_txd_o => open, aes67_irq_o => open, aes67_pll_ref_o => open);
end architecture;
