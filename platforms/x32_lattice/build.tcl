# Batch build with Lattice Diamond: diamondc build.tcl [synth|map|par|bit]
# (default: bit = everything up to the bitstream). Or open x32_lattice.ldf in the GUI.

set target bit
if {$argc > 0} { set target [lindex $argv 0] }

prj_project open "x32_lattice.ldf"
prj_run Synthesis -impl impl1
if {$target ne "synth"} { prj_run Map -impl impl1 }
if {$target eq "par" || $target eq "bit"} {
	prj_run PAR -impl impl1
	# timing report (impl1/x32_lattice_impl1.twr)
	prj_run PAR -impl impl1 -task PARTrace
}
if {$target eq "bit"} { prj_run Export -impl impl1 -task Bitgen }
prj_project close
