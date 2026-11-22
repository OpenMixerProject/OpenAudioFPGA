create_clock -name fabric -period 20.345052 [get_ports clk_audio]
# Mode-0 SPI is asynchronous; the bridge oversamples through two flops.
set_false_path -from [get_ports {host_sck host_mosi ctrl_cs_n dsp_cs_n}]
set_false_path -to [get_ports {host_miso_out host_miso_oe}]
