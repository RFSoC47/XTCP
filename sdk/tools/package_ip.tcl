# Regenerate the local Vivado IP repository from its public HDL.
set release_root [file normalize [file join [file dirname [info script]] ..]]
proc package_xtcp {work} {
    global release_root
    puts "VD_STAGE preflight BEGIN"
    if {[version -short] ne "2025.2"} {error "Vivado 2025.2 is required for this release"}
    puts "VD_STAGE preflight COMPLETE"
    puts "VD_STAGE project BEGIN"
    file mkdir $work
    create_project packaging [file join $work creator] -part xcku5p-ffvb676-2-i
    set dir [file join $work repo xtcp]
    file mkdir $dir
    file copy [file join $release_root ip_repo xtcp hdl] $dir
    set files [concat [glob $dir/hdl/*.v] [glob $dir/hdl/*/*.sv] [glob $dir/hdl/third_party/*/*.v]]
    add_files -norecurse $files
    set_property top xtcp [current_fileset]
    set_property XPM_LIBRARIES {XPM_MEMORY XPM_CDC} [current_project]
    update_compile_order -fileset sources_1
    ipx::package_project -root_dir $dir -vendor xtcp -library network -taxonomy /UserIP -set_current true
    set core [ipx::current_core]
    set_property name xtcp $core
    set_property version 1.0 $core
    set_property display_name XTCP $core
    set_property description {Single-connection IPv4/TCP endpoint with an 8-bit UDP control bus and 10 or 25 Gb/s line interface.} $core
    set_property supported_families {kintexuplus Production} $core
    set_property core_revision 1 $core
    set pp [ipx::get_user_parameters PROFILE -of_objects $core]
    set_property value_validation_type pairs $pp
    set_property value_validation_pairs {XTCP-10G 0 XTCP-25G 1 XTCP-25G-Jumbo 2} $pp
    set_property display_name {Line profile} $pp
    foreach {key caption} {LOCAL_MAC {Local MAC (48 bits)} LOCAL_IP {Local IPv4 (32 bits)} TCP_PORT {TCP listen port} RBCP_PORT {UDP control port}} {
        set_property display_name $caption [ipx::get_user_parameters $key -of_objects $core]
    }
    # IP-XACT vector bounds follow PROFILE in both customization and Block Design.
    foreach {name small large} {USER_TX_D 63 127 USER_TX_B 3 4 USER_RX_SIZE 17 18 USER_RX_RADR 17 18 USER_RX_WADR 17 18 USER_RX_WENB 7 15 USER_RX_WDAT 63 127} {
        set port [ipx::get_ports $name -of_objects $core]
        set dep [format {%d + %d * (spirit:decode(id('MODELPARAM_VALUE.PROFILE')) > 0)} $small [expr {$large-$small}]]
        set_property size_left_dependency $dep $port
    }
    ipx::create_xgui_files $core
    ipx::update_checksums $core
    ipx::save_core $core
    ipx::check_integrity $core
    puts "XTCP_CATALOG [get_property VLNV $core]"
    close_project
    puts "VD_STAGE project COMPLETE"
}
if {[catch {package_xtcp [file normalize [lindex $argv 0]]} message options]} {
    puts stderr [dict get $options -errorinfo]
    exit 1
}
exit 0
