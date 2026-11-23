# In the GUI Tcl Console: source /path/to/XTCP/tools/new_bd.tcl
# Call xtcp_new_bd with an unused output directory; the created project remains open.
set xtcp_script_dir [file normalize [file dirname [info script]]]
source [file join $xtcp_script_dir integrate.tcl]
source [file join $xtcp_script_dir xtcp_bd.tcl]
proc xtcp_new_bd {output {profile 2} {mac 025100030013} {ip C0A80A0D} {tcp 23012} {udp 4612}} {
    if {[llength [get_projects -quiet]]} {error "Close the current project or use a separate Vivado window"}
    if {[file exists $output]} {error "Choose a new project directory"}
    create_project xtcp_user [file normalize $output] -part xcku5p-ffvb676-2-i
    set_property target_language Verilog [current_project]
    xtcp::catalog
    create_bd_design user_endpoint
    set cell [xtcp::block endpoint $profile $mac $ip $tcp $udp]
    xtcp_external_ports $cell $profile
    validate_bd_design
    save_bd_design
    set bd [get_files */user_endpoint.bd]
    set_property synth_checkpoint_mode None $bd
    generate_target all $bd
    add_files -norecurse [make_wrapper -files $bd -top]
    update_compile_order -fileset sources_1
    return $cell
}
