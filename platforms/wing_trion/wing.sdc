create_clock -name audio -period 20.345052 [get_ports clk_audio]
create_clock -name rmii -period 20.000 [get_ports clk_rmii]
# SPORT sockets use two phase-aligned copies of the same divided fabric clock.
# Provisional external budget (ns): rising-edge SHARC launch and board flight
# plus return input skew, and DSP receive setup/hold. Signoff needs measured
# skew and the actual SHARC tCO/setup/hold across the board operating range.
create_clock -name sport_ext -period 40.690104
set_input_delay -clock sport_ext -max 22.0 [get_ports dsp*_tx_data*]
set_input_delay -clock sport_ext -min 5.0 [get_ports dsp*_tx_data*]
set_output_delay -clock sport_ext -clock_fall -max 4.0 [get_ports {dsp*_rx_data* dsp*_rx_fs dsp*_tx_fs}]
set_output_delay -clock sport_ext -clock_fall -min -2.5 [get_ports {dsp*_rx_data* dsp*_rx_fs dsp*_tx_fs}]
# Explicit half-bit window: the two clock enables are disjoint, but STA
# otherwise analyzes the coincident audio edge, or 40.69 ns with -multicycle 2.
set_max_delay 20.345 -from [get_clocks audio] -to [get_clocks sport_ext]
set_max_delay 20.345 -from [get_clocks sport_ext] -to [get_clocks audio]
# Asynchronous buffered SPI and forwarded DSP debug port.
set_false_path -from [get_ports {host_sck host_mosi dsp_cs_n ctrl_cs_n dsp*_dpi_miso}]
set_false_path -to [get_ports {host_miso_out host_miso_oe dsp*_dpi_sck dsp*_dpi_sel dsp*_dpi_mosi}]
