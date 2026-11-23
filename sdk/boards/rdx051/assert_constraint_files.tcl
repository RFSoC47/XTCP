# Read-only pre-launch assertion. Each expected policy is an explicit design input.
proc vd_assert_constraint_files {run_name entries} {
    if {[llength $entries] == 0} {error VD_CONSTRAINT_EMPTY_CONTRACT}
    set run [get_runs -quiet $run_name]
    if {[llength $run] != 1 || $run ne $run_name} {error VD_CONSTRAINT_RUN}
    set fs [get_filesets -quiet [get_property CONSTRSET $run]]
    if {[llength $fs] != 1} {error VD_CONSTRAINT_FILESET}
    set members [get_files -quiet -of_objects $fs]
    set seen [dict create]
    set rows {}
    foreach entry $entries {
        if {[llength $entry] != 5} {error VD_CONSTRAINT_ENTRY}
        lassign $entry path type synthesis implementation order
        if {[file pathtype $path] ne "absolute" || $type ni {TCL XDC} ||
            $synthesis ni {0 1} || $implementation ni {0 1} ||
            $order ni {EARLY NORMAL LATE}} {error VD_CONSTRAINT_POLICY}
        set path [file normalize $path]
        if {[dict exists $seen $path]} {error VD_CONSTRAINT_DUPLICATE}
        dict set seen $path 1
        set matched {}
        foreach f $members {if {[file normalize $f] eq $path} {lappend matched $f}}
        if {[llength $matched] != 1} {error "VD_CONSTRAINT_MEMBERSHIP $path"}
        set f [lindex $matched 0]
        set actual [list [get_property FILE_TYPE $f] \
            [expr {!![get_property USED_IN_SYNTHESIS $f]}] \
            [expr {!![get_property USED_IN_IMPLEMENTATION $f]}] [get_property PROCESSING_ORDER $f]]
        if {$actual ne [list $type $synthesis $implementation $order]} {
            error "VD_CONSTRAINT_REGISTRATION $path expected=[lrange $entry 1 end] actual=$actual"
        }
        lappend rows [linsert $actual 0 $path]
    }
    return $rows
}
