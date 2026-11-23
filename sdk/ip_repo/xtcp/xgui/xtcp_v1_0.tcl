# Definitional proc to organize widgets for parameters.
proc init_gui { IPINST } {
  ipgui::add_param $IPINST -name "Component_Name"
  #Adding Page
  set Page_0 [ipgui::add_page $IPINST -name "Page 0"]
  ipgui::add_param $IPINST -name "LOCAL_IP" -parent ${Page_0}
  ipgui::add_param $IPINST -name "LOCAL_MAC" -parent ${Page_0}
  ipgui::add_param $IPINST -name "PROFILE" -parent ${Page_0}
  ipgui::add_param $IPINST -name "RBCP_PORT" -parent ${Page_0}
  ipgui::add_param $IPINST -name "TCP_PORT" -parent ${Page_0}


}

proc update_PARAM_VALUE.LOCAL_IP { PARAM_VALUE.LOCAL_IP } {
	# Procedure called to update LOCAL_IP when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.LOCAL_IP { PARAM_VALUE.LOCAL_IP } {
	# Procedure called to validate LOCAL_IP
	return true
}

proc update_PARAM_VALUE.LOCAL_MAC { PARAM_VALUE.LOCAL_MAC } {
	# Procedure called to update LOCAL_MAC when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.LOCAL_MAC { PARAM_VALUE.LOCAL_MAC } {
	# Procedure called to validate LOCAL_MAC
	return true
}

proc update_PARAM_VALUE.PROFILE { PARAM_VALUE.PROFILE } {
	# Procedure called to update PROFILE when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.PROFILE { PARAM_VALUE.PROFILE } {
	# Procedure called to validate PROFILE
	return true
}

proc update_PARAM_VALUE.RBCP_PORT { PARAM_VALUE.RBCP_PORT } {
	# Procedure called to update RBCP_PORT when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.RBCP_PORT { PARAM_VALUE.RBCP_PORT } {
	# Procedure called to validate RBCP_PORT
	return true
}

proc update_PARAM_VALUE.TCP_PORT { PARAM_VALUE.TCP_PORT } {
	# Procedure called to update TCP_PORT when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.TCP_PORT { PARAM_VALUE.TCP_PORT } {
	# Procedure called to validate TCP_PORT
	return true
}


proc update_MODELPARAM_VALUE.PROFILE { MODELPARAM_VALUE.PROFILE PARAM_VALUE.PROFILE } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.PROFILE}] ${MODELPARAM_VALUE.PROFILE}
}

proc update_MODELPARAM_VALUE.LOCAL_MAC { MODELPARAM_VALUE.LOCAL_MAC PARAM_VALUE.LOCAL_MAC } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.LOCAL_MAC}] ${MODELPARAM_VALUE.LOCAL_MAC}
}

proc update_MODELPARAM_VALUE.LOCAL_IP { MODELPARAM_VALUE.LOCAL_IP PARAM_VALUE.LOCAL_IP } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.LOCAL_IP}] ${MODELPARAM_VALUE.LOCAL_IP}
}

proc update_MODELPARAM_VALUE.TCP_PORT { MODELPARAM_VALUE.TCP_PORT PARAM_VALUE.TCP_PORT } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.TCP_PORT}] ${MODELPARAM_VALUE.TCP_PORT}
}

proc update_MODELPARAM_VALUE.RBCP_PORT { MODELPARAM_VALUE.RBCP_PORT PARAM_VALUE.RBCP_PORT } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.RBCP_PORT}] ${MODELPARAM_VALUE.RBCP_PORT}
}

