set source_root [file normalize [file dirname [info script]]]
proc require_run {name} {
    set run [get_runs $name]
    set status [get_property STATUS $run]
    puts "RUN_RESULT name=$name status=$status progress=[get_property PROGRESS $run]"
    if {[get_property PROGRESS $run] ne "100%" || [regexp -nocase {error|fail} $status]} {
        error "Run did not complete: $name $status"
    }
}
proc main {} {
    if {$::argc ni {3 7}} {error "build.tcl output_dir profile rtl|catalog|bd ?mac_hex ipv4_hex tcp_decimal rbcp_decimal?"}
    lassign $::argv output profile integration mac ip tcp_port rbcp_port
    if {$profile ni {0 1 2} || $integration ni {rtl catalog bd}} {error "Select profile 0, 1 or 2 and integration rtl, catalog or bd"}
    set work [file normalize $output]
    if {$::argc==3} {
        set mac [format "0251000300%02X" [expr {0x11+$profile}]]
        set ip [format "C0A80A%02X" [expr {11+$profile}]]
        set tcp_port 24
        set rbcp_port 4660
    }
    if {![regexp {^[a-fA-F0-9]{12}$} $mac] || ![regexp {^[a-fA-F0-9]{8}$} $ip]} {error "Supply 12 MAC and 8 IPv4 hexadecimal digits"}
    foreach n [list $tcp_port $rbcp_port] {if {![string is integer -strict $n] || $n<1 || $n>65535} {error "Invalid transport port"}}
    set board $::source_root
    set root [file normalize [file join $board ../..]]
    set variant [expr {$profile==0 ? "line10" : "line25"}]
    puts "VD_STAGE preflight BEGIN"
    if {[version -short] ne "2025.2"} {error "Vivado release drift"}
    if {[llength [get_parts xcku5p-ffvb676-2-i]] != 1} {error "Part unavailable"}
    set_param general.maxThreads 4
    puts "VD_STAGE preflight COMPLETE"
    puts "VD_STAGE project BEGIN"
    create_project xtcp_example $work -part xcku5p-ffvb676-2-i
    set_property XPM_LIBRARIES {XPM_MEMORY XPM_CDC} [current_project]
    set_property target_language Verilog [current_project]
    set_property simulator_language Mixed [current_project]
    set reports [file join $work reports]
    set products [file join $work products]
    file mkdir $reports $products
    add_files -norecurse [list [file join $board $variant xtcp_rdx051.v] [file join $root examples xtcp_example_app.sv]]
    set_property top xtcp_rdx051 [current_fileset]
    set_property generic [list PROFILE=$profile LOCAL_MAC=48'h$mac LOCAL_IP=32'h$ip TCP_PORT=$tcp_port RBCP_PORT=$rbcp_port] [current_fileset]
    if {$integration eq "rtl"} {
        foreach dir [list {} g10 g25 jumbo third_party/mac third_party/axis] {
            set files [glob -nocomplain -directory [file join $root ip_repo xtcp hdl $dir] *.v *.sv]
            if {[llength $files]} {add_files -norecurse $files}
        }
    } else {
        set_property ip_repo_paths [file join $root ip_repo] [current_project]
        update_ip_catalog
        set id xtcp:network:xtcp:1.0
        set config [list CONFIG.PROFILE $profile CONFIG.LOCAL_MAC 0x$mac CONFIG.LOCAL_IP 0x$ip CONFIG.TCP_PORT [format 0x%04X $tcp_port] CONFIG.RBCP_PORT [format 0x%04X $rbcp_port]]
        if {$integration eq "catalog"} {
            create_ip -vlnv $id -module_name xtcp_customized
            set cell [get_ips xtcp_customized]
            set_property -dict $config $cell
            set file [get_files [get_property IP_FILE $cell]]
            set_property generate_synth_checkpoint false $file
            generate_target all $file
            set_property verilog_define XTCP_CATALOG [current_fileset]
        } else {
            source [file join $root tools xtcp_bd.tcl]
            create_bd_design xtcp_design
            set cell [create_bd_cell -type ip -vlnv $id endpoint]
            set_property -dict $config $cell
            xtcp_external_ports $cell $profile
            validate_bd_design
            save_bd_design
            set file [get_files */xtcp_design.bd]
            set_property synth_checkpoint_mode None $file
            generate_target all $file
            set_property verilog_define XTCP_BD [current_fileset]
        }
        foreach {key expected} $config {
            if {[get_property $key $cell] != $expected} {error "Configured value mismatch: $key"}
        }
    }
    add_files -fileset utils_1 -norecurse [file join $board impl_pre_opt.tcl]
    foreach path [list [file join $board board_common.xdc] [file join $board port_A.xdc] [file join $board $variant cdc.xdc]] {
        add_files -fileset constrs_1 -norecurse $path
        set_property FILE_TYPE XDC [get_files $path]
        set_property USED_IN_SYNTHESIS true [get_files $path]
        set_property USED_IN_IMPLEMENTATION true [get_files $path]
        set_property PROCESSING_ORDER NORMAL [get_files $path]
    }
    set_property PROCESSING_ORDER LATE [get_files */cdc.xdc]
    if {$profile!=0} {
        set fifo_constraints [file join $root tools axis_async_fifo.tcl]
        add_files -fileset constrs_1 -norecurse $fifo_constraints
        set_property FILE_TYPE TCL [get_files $fifo_constraints]
        set_property PROCESSING_ORDER LATE [get_files $fifo_constraints]
    }
    source [file join $board $variant phy.tcl]
    create_phy
    create_ip -name vio -vendor xilinx.com -library ip -version 3.0 -module_name rdx_status_vio
    set_property -dict [list CONFIG.C_NUM_PROBE_IN {1} CONFIG.C_PROBE_IN0_WIDTH {32} \
        CONFIG.C_NUM_PROBE_OUT {0} CONFIG.C_EN_PROBE_IN_ACTIVITY {0}] [get_ips rdx_status_vio]
    foreach ip {rdx_phy rdx_status_vio} {
        generate_target all [get_ips $ip]
        report_property -all -file [file join $reports ${ip}_properties.txt] [get_ips $ip]
        # Only the parent XCI owns the synthesis run; GT child XCI is managed by it.
        create_ip_run [get_files [get_property IP_FILE [get_ips $ip]]]
    }
    report_ip_status -file [file join $reports ip_status.rpt]
    update_compile_order -fileset sources_1
    report_compile_order -constraints -file [file join $reports constraint_order.rpt]
    set f [open [file join $reports constraint_files.txt] w]
    foreach file [get_files -all -filter {FILE_TYPE == XDC}] {
        puts $f [report_property -return_string $file]
    }
    close $f
    set engine [get_runs impl_1]
    set_property STRATEGY Performance_ExplorePostRoutePhysOpt $engine
    set_property STEPS.OPT_DESIGN.TCL.PRE [file join $board impl_pre_opt.tcl] $engine
    set guard [file join $board pre_bit_timing.tcl]
    add_files -fileset utils_1 -norecurse $guard
    set_property STEPS.WRITE_BITSTREAM.TCL.PRE $guard $engine
    if {![get_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED $engine] ||
        [file tail [get_property STEPS.OPT_DESIGN.TCL.PRE $engine]] ne "impl_pre_opt.tcl" ||
        [file tail [get_property STEPS.WRITE_BITSTREAM.TCL.PRE $engine]] ne "pre_bit_timing.tcl"} {
        error "Expected implementation strategy and hooks"
    }
    puts "VD_STAGE project COMPLETE"
    puts "VD_STAGE synthesis BEGIN"
    source [file join $board assert_constraint_files.tcl]
    set expected_constraints [list \
        [list [file join $board board_common.xdc] XDC 1 1 NORMAL] \
        [list [file join $board port_A.xdc] XDC 1 1 NORMAL] \
        [list [file join $board $variant cdc.xdc] XDC 1 1 LATE]]
    if {$profile!=0} {lappend expected_constraints [list $fifo_constraints TCL 1 1 LATE]}
    set checked_constraints [vd_assert_constraint_files impl_1 $expected_constraints]
    set f [open [file join $reports asserted_constraint_registration.txt] w]
    puts $f $checked_constraints
    close $f
    set ip_runs [get_runs {rdx_phy_synth_1 rdx_status_vio_synth_1}]
    launch_runs $ip_runs -jobs 2
    foreach run $ip_runs {wait_on_run $run; require_run $run}
    launch_runs synth_1 -jobs 2
    wait_on_run synth_1
    require_run synth_1
    open_run synth_1
    # Structural assertions belong in Tcl, not restricted XDC ingestion.
    set meta_cells [get_cells -hier -regexp {.*(flag_meta_reg|debug_meta_reg)\[[0-9]+\]}]
    set reset_cells [get_cells -hier -regexp {.*reset_sync_reg\[[0-9]+\]}]
    if {[llength $meta_cells] < 10 || [llength $reset_cells] != ($profile==0 ? 4 : 8)} {error "Synchronizer structure changed"}
    foreach pattern {{^gt_refclk_p$} {^txoutclk_out\[0\]$} {^rxoutclk_out\[0\]$}} {
        if {[llength [get_clocks -regexp $pattern]] != 1} {error "CDC clock selection changed: $pattern"}
    }
    report_utilization -hierarchical -hierarchical_depth 3 -file [file join $reports synthesized_utilization.rpt]
    report_clocks -file [file join $reports synthesized_clocks.rpt]
    close_design
    puts "VD_STAGE synthesis COMPLETE"
    puts "VD_STAGE implementation BEGIN"
    launch_runs impl_1 -to_step write_bitstream -jobs 2
    wait_on_run impl_1
    require_run impl_1
    puts "VD_STAGE implementation COMPLETE"
    puts "VD_STAGE reports BEGIN"
    foreach path [list [file join $reports routed_timing_summary.rpt] [file join $reports routed_methodology.rpt] [file join $products routed.dcp]] {
        if {![file isfile $path]} {error "Pre-bit hook missed $path"}
    }
    puts "VD_STAGE reports COMPLETE"
    puts "VD_STAGE bitstream BEGIN"
    file copy [file join $work xtcp_example.runs impl_1 xtcp_rdx051.bit] [file join $products xtcp_rdx051.bit]
    close_project
    puts "VD_STAGE bitstream COMPLETE"
}
if {[catch {main} message options]} {
    puts stderr "BUILD_FAILED: $message"
    puts stderr [dict get $options -errorinfo]
    exit 1
}
exit 0
