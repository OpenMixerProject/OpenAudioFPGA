# Run on a routed B-only project: efx_run --flow sta_tclsh --tcl_script audit_b.tcl wing-fpga.xml
check_timing -verbose -file cdc-check.rpt
report_clocks -file cdc-clocks.rpt
report_timing -setup -less_than_slack 0 -npaths 100 -file cdc-negative-setup.rpt
report_timing -hold -less_than_slack 0 -npaths 100 -file cdc-negative-hold.rpt

set tx [get_pins {console/core/gen_aes50[0].u_aes50/tx_base_rmii[*]~FF|D console/core/gen_aes50[0].u_aes50/tx_assm_rmii~FF|D}]
set rx [get_pins {console/core/gen_aes50[0].u_aes50/u_tdm/rx_pending_base[*]~FF|D}]
report_timing -setup -from_clock aes_bclk -to $tx -npaths 20 -file cdc-bundle-tx.rpt
report_timing -setup -from_clock rmii -to $rx -npaths 20 -file cdc-bundle-rx.rpt
report_timing -hold -from_clock aes_bclk -to $tx -npaths 20 -file cdc-bundle-tx-hold.rpt
report_timing -hold -from_clock rmii -to $rx -npaths 20 -file cdc-bundle-rx-hold.rpt

set stages [get_pins {console/rmii_started[0]~FF|CLK console/core/frame_matrix.good_m[1]~FF|CLK console/core/gen_aes50[0].u_aes50/audio_rst_sync[0]~FF|CLK console/core/gen_aes50[0].u_aes50/bclk_rst_sync[0]~FF|CLK console/core/gen_aes50[0].u_aes50/mdix_audio_sync[0]~FF|CLK console/core/gen_aes50[0].u_aes50/tx_blk_sync[0]~FF|CLK console/core/gen_aes50[0].u_aes50/u_tdm/rx_blk_sync[0]~FF|CLK console/core/gen_aes50[0].u_aes50/u_tdm/tx_en_sync[0]~FF|CLK console/core/gen_aes50[0].u_aes50/u_tdm/assm_sync[0]~FF|CLK console/core/gen_aes50[0].u_aes50/u_link/clk_a_samples[0]~FF|CLK console/core/gen_aes50[0].u_aes50/u_link/clk_b_samples[0]~FF|CLK}]
report_timing -setup -from $stages -npaths 30 -file cdc-synchronizer-stages.rpt

set rmii_rx [get_ports {phy_b_dv phy_b_rxd0 phy_b_rxd1}]
set rmii_tx [get_ports {phy_b_txen phy_b_txd0 phy_b_txd1}]
foreach check {setup hold} {
    report_timing -$check -from $rmii_rx -npaths 3 -file cdc-rmii-rx-$check.rpt
    report_timing -$check -to $rmii_tx -npaths 3 -file cdc-rmii-tx-$check.rpt
}
