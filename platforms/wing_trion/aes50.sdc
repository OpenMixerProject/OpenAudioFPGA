create_generated_clock -name aes_bclk -source [get_ports clk_audio] -divide_by 4 [get_pins {CLKBUF__2|O}]

# Provisional FPGA-pad budget relative to the forwarded clock at AB15.
# RX includes PHY clock-to-out plus PCB round trip; TX includes PHY setup/hold
# and differential PCB flight. Not a measurement or a claim about the PHY.
set_input_delay -clock rmii -reference_pin [get_ports phy_b_ref] -max 10.0 [get_ports {phy_b_dv phy_b_rxd0 phy_b_rxd1}]
set_input_delay -clock rmii -reference_pin [get_ports phy_b_ref] -min 1.0 [get_ports {phy_b_dv phy_b_rxd0 phy_b_rxd1}]
set_output_delay -clock rmii -reference_pin [get_ports phy_b_ref] -max 4.0 [get_ports {phy_b_txen phy_b_txd0 phy_b_txd1}]
set_output_delay -clock rmii -reference_pin [get_ports phy_b_ref] -min -2.0 [get_ports {phy_b_txen phy_b_txd0 phy_b_txd1}]

# Only the first stage of each single-bit synchronizer lacks an edge relation.
# Keep ordinary STA on the receiving synchronizer chain and its consumers.
set_false_path -from [get_clocks audio] -to [get_pins {console/rmii_started[0]~FF|D}]
set_false_path -from [get_clocks rmii] -to [get_pins {console/core/frame_matrix.good_m[*]~FF|D}]
set_false_path -from [get_clocks rmii] -to [get_pins {console/core/gen_aes50[*].u_aes50/u_tdm/tx_en_sync[0]~FF|D console/core/gen_aes50[*].u_aes50/u_tdm/rx_blk_sync[0]~FF|D}]
set_false_path -from [get_clocks aes_bclk] -to [get_pins {console/core/gen_aes50[*].u_aes50/tx_blk_sync[0]~FF|D}]
set_false_path -from [get_ports sync_b_a_observe] -to [get_pins {console/core/gen_aes50[0].u_aes50/u_link/clk_a_samples[0]~FF|D}]
set_false_path -from [get_ports sync_b_b_observe] -to [get_pins {console/core/gen_aes50[0].u_aes50/u_link/clk_b_samples[0]~FF|D}]

# core_rst asserts both stages through asynchronous SR inputs. RMII has
# no edge relation to either destination; time the local FF-to-FF release.
set_false_path -from [get_pins {console/core/gen_aes50[*].u_aes50/core_rst~FF|CLK}] -to [get_pins {console/core/gen_aes50[*].u_aes50/audio_rst_sync[*]~FF|SR console/core/gen_aes50[*].u_aes50/bclk_rst_sync[*]~FF|SR}]

# Derived BCLK is related, but the ASSM is a held event sampled by two
# stages, not edge-qualified TDM data. No exception on the serialized data/FS.
set_false_path -from [get_clocks audio] -to [get_pins {console/core/gen_aes50[*].u_aes50/u_tdm/assm_sync[0]~FF|D}]

# Bundled data: the capture is at least two destination edges after the
# first toggle sample. No asynchronous hold relationship; keep a routed
# upper limit on every data bit to the exact snapshot register.
set_max_delay 18.0 -from [get_clocks aes_bclk] -to [get_pins {console/core/gen_aes50[*].u_aes50/tx_base_rmii[*]~FF|D console/core/gen_aes50[*].u_aes50/tx_assm_rmii~FF|D}]
set_false_path -hold -from [get_clocks aes_bclk] -to [get_pins {console/core/gen_aes50[*].u_aes50/tx_base_rmii[*]~FF|D console/core/gen_aes50[*].u_aes50/tx_assm_rmii~FF|D}]
set_max_delay 30.0 -from [get_clocks rmii] -to [get_pins {console/core/gen_aes50[*].u_aes50/u_tdm/rx_pending_base[*]~FF|D}]
set_false_path -hold -from [get_clocks rmii] -to [get_pins {console/core/gen_aes50[*].u_aes50/u_tdm/rx_pending_base[*]~FF|D}]
