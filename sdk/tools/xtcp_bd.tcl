# Export the native endpoint ports with their customized widths and clock metadata.
proc xtcp_external_ports {cell profile} {
        foreach pin [get_bd_pins -of_objects $cell] {
            set n [get_property NAME $pin]
            set d [get_property DIR $pin]
            set left [get_property LEFT $pin]
            set right [get_property RIGHT $pin]
            if {$n in {APP_CLK LINE_CLK}} {
                set hz [expr {$profile==0 ? 156250000 : ($n eq "APP_CLK" ? 195312500 : 390625000)}]
                set port [create_bd_port -dir I -type clk -freq_hz $hz $n]
            } elseif {$n in {APP_RST LINE_RST}} {
                set port [create_bd_port -dir I -type rst $n]
                set_property CONFIG.POLARITY ACTIVE_HIGH $port
            } elseif {$left ne "" && $right ne ""} {
                set port [create_bd_port -dir $d -from $left -to $right $n]
            } else {
                set port [create_bd_port -dir $d $n]
            }
            connect_bd_net $pin $port
        }
}
