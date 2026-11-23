proc create_phy {} {
    create_ip -name xxv_ethernet -vendor xilinx.com -library ip -version 5.0 -module_name rdx_phy
    set_property -dict [list CONFIG.CORE {Ethernet PCS/PMA 64-bit} CONFIG.LINE_RATE {10} \
        CONFIG.BASE_R_KR {BASE-R} CONFIG.NUM_OF_CORES {1} CONFIG.GT_REF_CLK_FREQ {156.25} \
        CONFIG.GT_DRP_CLK {156.25} CONFIG.INCLUDE_SHARED_LOGIC {1}] [get_ips rdx_phy]
    set_property CONFIG.GT_GROUP_SELECT Quad_X0Y3 [get_ips rdx_phy]
    set_property CONFIG.LANE1_GT_LOC X0Y12 [get_ips rdx_phy]
}
