create_clock -name fir_clk -period 2.000 [get_ports clk]

set data_inputs [all_inputs -no_clocks]
set data_outputs [all_outputs]

set_input_delay  -clock fir_clk -max 0.30  $data_inputs
set_input_delay  -clock fir_clk -min 0.05  $data_inputs
set_output_delay -clock fir_clk -max 0.30  $data_outputs
set_output_delay -clock fir_clk -min -0.05 $data_outputs

set_input_transition 0.2 $data_inputs
set_load 20.0 $data_outputs
