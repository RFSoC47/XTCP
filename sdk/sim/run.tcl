# Usage (batch Tcl): run.tcl empty_directory profile
set root [file normalize [file join [file dirname [info script]] ..]]
proc simulate {work profile} {
    global root
    puts "VD_STAGE preflight BEGIN"
    if {[version -short] ne "2025.2" || $profile ni {0 1 2}} {error "Expected Vivado 2025.2 and a supported profile"}
    puts "VD_STAGE preflight COMPLETE"
    puts "VD_STAGE project BEGIN"
    create_project wire $work -part xcku5p-ffvb676-2-i
    set_property XPM_LIBRARIES {XPM_CDC XPM_MEMORY} [current_project]
    set_property target_language Verilog [current_project]
    foreach dir [list {} g10 g25 jumbo third_party/mac third_party/axis] {
        set files [glob -nocomplain -directory [file join $root ip_repo xtcp hdl $dir] *.v *.sv]
        if {[llength $files]} {add_files -norecurse $files}
    }
    add_files -norecurse [file join $root examples xtcp_example_app.sv]
    add_files -fileset sim_1 -norecurse [file join $root sim tb_xtcp.sv]
    set_property top tb_xtcp [get_filesets sim_1]
    set_property generic [list PROFILE=$profile] [get_filesets sim_1]
    set_property xsim.simulate.runtime all [get_filesets sim_1]
    update_compile_order -fileset sim_1
    launch_simulation
    set f [open [file join $work wire.sim sim_1 behav xsim simulate.log] r]
    set transcript [read $f]
    close $f
    if {![string match "*XTCP_WIRE_PASS profile=$profile *" $transcript] || [regexp {Fatal:} $transcript]} {error "Ethernet/TCP wire regression failed"}
    close_sim
    close_project
    puts "VD_STAGE project COMPLETE"
}
if {[catch {simulate [file normalize [lindex $argv 0]] [lindex $argv 1]} failure opts]} {puts stderr [dict get $opts -errorinfo];exit 1}
exit 0
