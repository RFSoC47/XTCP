# Derived from board NET; all serial/ref pins match frozen D11.
# The generated PHY XDC is the sole primary-clock owner: period 6.400 ns.
set_property PACKAGE_PIN F7 [get_ports {gt_txp}]
set_property PACKAGE_PIN F6 [get_ports {gt_txn}]
set_property PACKAGE_PIN D2 [get_ports {gt_rxp}]
set_property PACKAGE_PIN D1 [get_ports {gt_rxn}]
set_property PACKAGE_PIN K7 [get_ports {gt_refclk_p}]
set_property PACKAGE_PIN K6 [get_ports {gt_refclk_n}]
