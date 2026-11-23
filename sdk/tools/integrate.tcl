# Source this file in a project, then call the xtcp::* command matching its integration style.
namespace eval xtcp {
    variable root [file normalize [file join [file dirname [info script]] ..]]
    variable id xtcp:network:xtcp:1.0
}
proc xtcp::catalog {} {
    variable root
    variable id
    set repo [file join $root ip_repo]
    set repos [get_property ip_repo_paths [current_project]]
    if {[lsearch -exact $repos $repo]<0} {lappend repos $repo; set_property ip_repo_paths $repos [current_project]}
    update_ip_catalog
    if {[llength [get_ipdefs -all $id]]!=1} {error "XTCP 1.0 could not be resolved uniquely"}
    return $id
}
proc xtcp::constraints {profile} {
    variable root
    if {$profile ni {0 1 2}} {error "Expected profile 0, 1 or 2"}
    if {$profile==0} {return}
    set path [file join $root tools axis_async_fifo.tcl]
    if {![llength [get_files -quiet $path]]} {add_files -fileset constrs_1 -norecurse $path}
    set_property FILE_TYPE TCL [get_files $path]
    set_property PROCESSING_ORDER LATE [get_files $path]
}
proc xtcp::rtl {profile} {
    variable root
    set_property XPM_LIBRARIES [lsort -unique [concat [get_property XPM_LIBRARIES [current_project]] {XPM_MEMORY XPM_CDC}]] [current_project]
    foreach folder [list {} g10 g25 jumbo third_party/mac third_party/axis] {
        foreach path [glob -nocomplain -directory [file join $root ip_repo xtcp hdl $folder] *.sv *.v] {
            if {![llength [get_files -quiet $path]]} {add_files -norecurse $path}
        }
    }
    constraints $profile
    update_compile_order -fileset sources_1
}
proc xtcp::configuration {profile mac_hex ip_hex tcp udp} {
    if {$profile ni {0 1 2} || ![regexp {^[[:xdigit:]]{12}$} $mac_hex] || ![regexp {^[[:xdigit:]]{8}$} $ip_hex]} {error "Expected a supported profile, twelve MAC digits and eight IPv4 digits"}
    foreach p [list $tcp $udp] {if {![string is integer -strict $p] || $p<1 || $p>65535} {error "Port must be in 1..65535"}}
    return [list CONFIG.PROFILE $profile CONFIG.LOCAL_MAC 0x$mac_hex CONFIG.LOCAL_IP 0x$ip_hex CONFIG.TCP_PORT [format 0x%04X $tcp] CONFIG.RBCP_PORT [format 0x%04X $udp]]
}
proc xtcp::block {instance profile mac_hex ip_hex tcp udp} {
    variable id
    set config [configuration $profile $mac_hex $ip_hex $tcp $udp]
    set cell [create_bd_cell -type ip -vlnv $id $instance]
    set_property -dict $config $cell
    constraints $profile
    return $cell
}
