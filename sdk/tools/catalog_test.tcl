source [file join [file dirname [info script]] xtcp_bd.tcl]
# Exercise the installed catalog IP in an empty Vivado project and three block designs.
set root [file normalize [file join [file dirname [info script]] ..]]
proc test_catalog {work} {
    global root
    puts "VD_STAGE preflight BEGIN"
    if {[version -short] ne "2025.2"} {error "Vivado 2025.2 is required"}
    puts "VD_STAGE preflight COMPLETE"
    puts "VD_STAGE project BEGIN"
    create_project catalog $work -part xcku5p-ffvb676-2-i
    set_property ip_repo_paths [file join $root ip_repo] [current_project]
    update_ip_catalog
    set catalog_id xtcp:network:xtcp:1.0
    if {[llength [get_ipdefs -all $catalog_id]] != 1} {error "Expected one XTCP 1.0 entry"}
    set output [open [file join $work catalog_results.tsv] w]
    puts $output "profile\tinstance\tmac_hex\tipv4_hex\ttx_bits\trx_pointer_bits"
    foreach profile {0 1 2} {
        set bytes [expr {$profile==0 ? 8 : 16}]
        set addr_bits [expr {$profile==0 ? 18 : 19}]
        set mac [format "0251000300%02X" [expr {0x11+$profile}]]
        set ip [format %08X [expr {0xc0a80a0b+$profile}]]
        set name endp_$profile
        create_ip -vlnv $catalog_id -module_name $name
        set_property -dict [list CONFIG.PROFILE $profile CONFIG.LOCAL_MAC 0x$mac CONFIG.LOCAL_IP 0x$ip CONFIG.TCP_PORT 0x5A01 CONFIG.RBCP_PORT 0x12AB] [get_ips $name]
        generate_target all [get_ips $name]
        create_bd_design design_$profile
        set cell [create_bd_cell -type ip -vlnv $catalog_id endpoint]
        set_property -dict [list CONFIG.PROFILE $profile CONFIG.LOCAL_MAC 0x$mac CONFIG.LOCAL_IP 0x$ip CONFIG.TCP_PORT 0x5A01 CONFIG.RBCP_PORT 0x12AB] $cell
        foreach object [list [get_ips $name] $cell] {
            foreach {key value} [list LOCAL_MAC $mac LOCAL_IP $ip TCP_PORT 5A01 RBCP_PORT 12AB] {
                if {[expr {[get_property CONFIG.$key $object] != [expr "0x$value"]}]} {error "Identity mismatch on $key"}
            }
        }
        xtcp_external_ports $cell $profile
        validate_bd_design
        save_bd_design
        foreach {n expected} [list USER_TX_D [expr {$bytes*8}] USER_RX_WDAT [expr {$bytes*8}] USER_RX_WENB $bytes USER_TX_B [expr {$profile==0 ? 4 : 5}] USER_RX_RADR $addr_bits] {
            set p [get_bd_pins endpoint/$n]
            set width [expr {[get_property LEFT $p]-[get_property RIGHT $p]+1}]
            if {$width!=$expected} {error "Profile $profile: $n has $width bits instead of $expected"}
        }
        set file [get_files */design_$profile.bd]
        generate_target all $file
        make_wrapper -files $file -top
        puts $output "$profile\tendpoint\t[get_property CONFIG.LOCAL_MAC $cell]\t[get_property CONFIG.LOCAL_IP $cell]\t[expr {$bytes*8}]\t$addr_bits"
        close_bd_design [current_bd_design]
    }
    close $output
    close_project
    puts "VD_STAGE project COMPLETE"
}
if {[catch {test_catalog [file normalize [lindex $argv 0]]} message options]} {
    puts stderr [dict get $options -errorinfo]
    exit 1
}
exit 0
