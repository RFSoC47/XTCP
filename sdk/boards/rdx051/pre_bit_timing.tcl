# Implementation runs this hook on the actual post-route checkpoint, before Bitgen.
set work [file normalize [file join [pwd] .. ..]]
set reports [file join $work reports]
set products [file join $work products]
set port A
if {![file isdirectory $reports] || ![file isdirectory $products]} {error "Invalid implementation report path"}
    report_timing -delay_type max -max_paths 40 -nworst 1 -file [file join $reports slow_paths.rpt]
    report_timing_summary -delay_type min_max -report_unconstrained -check_timing_verbose -file [file join $reports routed_timing_summary.rpt]
    report_drc -file [file join $reports routed_drc.rpt]
    report_methodology -file [file join $reports routed_methodology.rpt]
    report_route_status -file [file join $reports route_status.rpt]
    report_utilization -hierarchical -hierarchical_depth 3 -file [file join $reports routed_utilization.rpt]
    report_utilization -file [file join $reports utilization_flat.rpt]
    report_utilization -hierarchical -hierarchical_depth 8 -file [file join $reports memory_hierarchy.rpt]
    set f [open [file join $reports memory_cells.tsv] w]
    puts $f "NAME\tREF_NAME\tLOC"
    foreach cell [get_cells -quiet -hier -filter {REF_NAME =~ RAMB* || REF_NAME =~ URAM*}] {
        puts $f "$cell\t[get_property REF_NAME $cell]\t[get_property LOC $cell]"
    }
    close $f
    set f [open [file join $reports memory_properties.txt] w]
    foreach cell [get_cells -quiet -hier -filter {REF_NAME =~ RAMB* || REF_NAME =~ URAM*}] {
        puts $f [report_property -all -return_string $cell]
    }
    close $f
    report_control_sets -verbose -file [file join $reports control_sets.rpt]
    report_clocks -file [file join $reports clocks.rpt]
    report_clock_interaction -file [file join $reports clock_interaction.rpt]
    report_cdc -details -file [file join $reports cdc.rpt]
    report_exceptions -file [file join $reports exceptions.rpt]
    report_exceptions -ignored -file [file join $reports ignored_exceptions.rpt]
    report_exceptions -coverage -file [file join $reports exception_coverage.rpt]
    report_bus_skew -file [file join $reports bus_skew.rpt]
    report_io -file [file join $reports io.rpt]
    check_timing -verbose -file [file join $reports check_timing.rpt]
    write_xdc -force [file join $reports effective_constraints.xdc]
    write_checkpoint -force [file join $products routed.dcp]
    write_debug_probes -force [file join $products xtcp_rdx051.ltx]
    set setup [get_timing_paths -delay_type max -max_paths 1]
    set hold [get_timing_paths -delay_type min -max_paths 1]
    if {[llength $setup] != 1 || [llength $hold] != 1} {error "Missing timing paths"}
    set wns [get_property SLACK $setup]
    set whs [get_property SLACK $hold]
    puts "VD_WNS_NS=$wns"
    puts "VD_WHS_NS=$whs"
    if {$wns <= 0 || $whs <= 0} {error "Nonpositive optimized routed timing"}
    set f [open [file join $reports routed_methodology.rpt] r]
    set methodology [read $f]
    close $f
    if {[regexp {\|\s+(Critical Warning|Error)\s+\|} $methodology]} {
        error "Critical methodology finding; bitstream gate closed"
    }
