# VIO observes only; its one clock is the free-running reference-buffer output.
set hub [get_debug_cores -quiet dbg_hub]
if {[llength $hub] != 1} {error "Expected exactly one debug hub"}
set_property C_CLK_INPUT_FREQ_HZ 156250000 $hub
set_property C_ENABLE_CLK_DIVIDER true $hub
