# Exercise the same project-creation procedures provided to a GUI user.
set demo_root [file normalize [file join [file dirname [info script]] ..]]
source [file join $demo_root tools new_bd.tcl]
proc run_demo {work} {
    global demo_root
    puts "VD_STAGE preflight BEGIN"
    if {[version -short] ne "2025.2"} {error "Expected Vivado 2025.2"}
    puts "VD_STAGE preflight COMPLETE"
    puts "VD_STAGE project BEGIN"
    file mkdir $work
    set cell [xtcp_new_bd [file join $work bd_gui] 2 0251ABCDEF19 C0A80A15 24001 4701]
    if {[get_property CONFIG.LOCAL_MAC $cell]!=0x0251ABCDEF19 || [get_property LEFT [get_bd_pins $cell/USER_TX_D]]!=127} {error "Wrong user configuration"}
    puts "XTCP_GUI_REOPEN [get_property CONFIG.PROFILE $cell] [get_property CONFIG.LOCAL_MAC $cell]"
    close_bd_design [current_bd_design]
    open_bd_design [get_files */user_endpoint.bd]
    if {[get_property CONFIG.TCP_PORT [get_bd_cells endpoint]]!=24001} {error "Reopened BD lost customization"}
    close_project
    create_project rtl_user [file join $work rtl_user] -part xcku5p-ffvb676-2-i
    xtcp::rtl 1
    set_property top xtcp [current_fileset]
    set_property generic [list PROFILE=1] [current_fileset]
    synth_design -rtl -name rtl_1 -top xtcp -part xcku5p-ffvb676-2-i
    set bits [get_ports -quiet -regexp {USER_TX_D\[[0-9]+\]}]
    if {[llength $bits]!=128} {error "Direct-RTL elaboration width [llength $bits], expected 128"}
    puts "XTCP_DIRECT_ELABORATION PASS width=[llength $bits]"
    close_project
    puts "VD_STAGE project COMPLETE"
}
if {[catch {run_demo [file normalize [lindex $argv 0]]} msg opts]} {puts stderr [dict get $opts -errorinfo];exit 1}
exit 0
