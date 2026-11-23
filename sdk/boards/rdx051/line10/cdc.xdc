# Independent level flags intentionally enter two-stage ASYNC_REG chains.
# No multibit data/counter crossing is covered by this exception.
set meta_cells [get_cells -hier -regexp {.*(flag_meta_reg|debug_meta_reg)\[[0-9]+\]}]
set_false_path -to [get_pins -of_objects $meta_cells -filter {REF_PIN_NAME == D}]
# The reset chain uses asynchronous assertion and four-clock synchronous release.
set reset_cells [get_cells -hier -regexp {.*reset_sync_reg\[[0-9]+\]}]
set_false_path -to [get_pins -of_objects $reset_cells -filter {REF_PIN_NAME == PRE}]
# QSFP ResetL is an asynchronous module reset with a 107ms startup hold.
# It has no source-synchronous external capture clock or timing relation to XGMII.
set_false_path -to [get_ports {qsfp_reset_n[*]}]
# Module presence/interrupt are asynchronous levels. Routed fanout was checked:
# they feed only flag_meta/debug_meta first-stage D pins, never packet logic.
set_false_path -from [get_ports {qsfp_present_n[*] qsfp_int_n[*]}]
# Ref/helper, GT TX, and recovered RX clocks have no guaranteed common phase.
# Preserve the IP's CDC structures and pin-specific exceptions. Bound remaining
# PHY CDC paths to one 156.25 MHz period instead of assuming synchronous clocks
# or blanket-disabling their propagation-delay checks. Debug hub clocks are
# intentionally absent: their vendor max-delay contracts remain unchanged.
set ref_clock [get_clocks -regexp {^gt_refclk_p$}]
# Names are frozen to this IP configuration/release and asserted after synthesis.
# TIMING-28 is retained for engineering review; no generated-clock redefinition.
set tx_clock [get_clocks -regexp {^txoutclk_out\[0\]$}]
set rx_clock [get_clocks -regexp {^rxoutclk_out\[0\]$}]
set_max_delay 6.400 -datapath_only -from $ref_clock -to $tx_clock
set_max_delay 6.400 -datapath_only -from $rx_clock -to $tx_clock
set_max_delay 6.400 -datapath_only -from $tx_clock -to $rx_clock
# Every remaining PHY CDC data path has the above maximum-delay bound.
# Retain vendor bus-skew constraints; do not expand a skew bus to every register
# or multi-clock GT/RAM primitive in a clock domain.
