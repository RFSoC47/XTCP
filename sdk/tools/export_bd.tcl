# Run with Vivado -mode batch -source export_bd.tcl -tclargs empty_output_directory.
set dir [file normalize [file dirname [info script]]]
source [file join $dir new_bd.tcl]
proc export_xtcp_figure {work} {
    puts "VD_STAGE preflight BEGIN"
    if {[version -short] ne "2025.2"} {error "Expected Vivado 2025.2"}
    puts "VD_STAGE preflight COMPLETE"
    puts "VD_STAGE project BEGIN"
    file mkdir $work
    set cell [xtcp_new_bd [file join $work demo] 2 025100030013 C0A80A0D 23012 4612]
    start_gui
    open_bd_design [get_files */user_endpoint.bd]
    regenerate_bd_layout
    save_bd_design
    set svg [file join $work xtcp_block_design.svg]
    write_bd_layout -force -format svg -orientation portrait $svg
    if {![file exists $svg] || [file size $svg]<1000} {error "Vivado did not export its BD Diagram"}
    puts "XTCP_NATIVE_DIAGRAM [get_property VLNV $cell] [get_property CONFIG.LOCAL_MAC $cell] [file size $svg]"
    close_project
    puts "VD_STAGE project COMPLETE"
}
if {[catch {export_xtcp_figure [file normalize [lindex $argv 0]]} msg opts]} {puts stderr [dict get $opts -errorinfo];exit 1}
exit 0
