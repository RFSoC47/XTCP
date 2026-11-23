# Fixed 25GBASE-R, no FEC, one GTY on the near-USB QSFP1 first lane.
proc create_phy {} {
    create_ip -name xxv_ethernet -vendor xilinx.com -library ip -version 5.0 -module_name rdx_phy
    set phy [get_ips rdx_phy]
    set cfg [list CORE {Ethernet PCS/PMA 64-bit} LINE_RATE 25 BASE_R_KR BASE-R NUM_OF_CORES 1 \
        GT_REF_CLK_FREQ 156.25 GT_DRP_CLK 156.25 INCLUDE_SHARED_LOGIC 1 \
        INCLUDE_FEC_LOGIC 0 INCLUDE_RSFEC_LOGIC 0 RUNTIME_SWITCH 0]
    set pairs {}
    foreach {key val} $cfg {lappend pairs CONFIG.$key $val}
    set_property -dict $pairs $phy
    set_property CONFIG.GT_GROUP_SELECT Quad_X0Y3 $phy
    set_property CONFIG.LANE1_GT_LOC X0Y12 $phy
    foreach {key val} [concat $cfg {GT_GROUP_SELECT Quad_X0Y3 LANE1_GT_LOC X0Y12}] {
        set got [get_property CONFIG.$key $phy]
        if {$got ne $val && !([string is double -strict $val] && [string is double -strict $got] && $val==$got)} {
            error "PHY CONFIG.$key requested=$val actual=$got"
        }
    }
    return $phy
}
