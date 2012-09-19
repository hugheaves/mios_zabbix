-- MiOS "Smart Switch" Plugin
--
-- Copyright (C) 2012  Hugh Eaves
--
-- This program is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation, either version 3 of the License, or
-- (at your option) any later version.
--
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.
--
-- You should have received a copy of the GNU General Public License
-- along with this program.  If not, see <http://www.gnu.org/licenses/>.

-- IMPORT GLOBALS
local luup = luup
local string = string
local require = require
local math = math
local io = io
local os = os
local json = g_dkjson
local log = g_log
local util = g_util

local PLUGIN_VERSION = "0.2"
local LOG_PREFIX = "Zabbix"

local CONFIG_FILE = "/tmp/zabbix_agentd.conf"
local AGENT_PID_FILE = "/tmp/zabbix_agentd.pid"

local LOG_PATH = "/var/log/cmh/"
local SENDER_STDOUT_FILE = LOG_PATH .. "zabbix_sender.out"
local AGENT_STDOUT_FILE = LOG_PATH .. "zabbix_agentd.out"
local AGENT_LOG_FILE = LOG_PATH .. "zabbix_agentd.log"

local BIN_PATH = "/etc/cmh-ludl/"
local SENDER_BIN = "zabbix_sender"
local SENDER_PATH = BIN_PATH .. SENDER_BIN
local AGENT_BIN = "zabbix_agentd"
local AGENT_PATH = BIN_PATH .. AGENT_BIN

local SID = {
	ZABBIX = "urn:hugheaves-com:serviceId:Zabbix1"
}

local DEFAULT_LOG_CONFIG = {
	["version"] = 1,
	["files"] = {
		["./*L_Zabbix_log.lua$"] = {
			["level"] = log.LOG_LEVEL_INFO,
			["functions"] = {
			}
		},
		["./*L_Zabbix_util.lua$"] = {
			["level"] = log.LOG_LEVEL_INFO,
			["functions"] = {
			}
		},
	}
}

-- GLOBALS
local g_deviceId = nil
local g_statusUrl = "http://localhost:3480/data_request?id=lu_status2&output_format=json"
local g_sender = nil

-----------------------------------------
--------- Utility Functions -------------
-----------------------------------------

--- Build the Zabbix "Key" for a specific device / service / variable
local function buildKey(service, variable)
	return "mios.upnp[" .. service .. "," .. variable .. "]"
end

local function executeCommand(command)
	log.info ("Executing command [", command, "]")
	local returnCode = os.execute (command)
	log.info ("Received return code [", returnCode, "] for command [", command, "]")
end
------------------------------------------
---------- Zabbix Communication ----------
------------------------------------------
--- Callback that receives notification of any changes in UPnP variables
-- Collects the changes for periodic transmission by the sendEvents() function
function variableWatchCallback(lul_device, lul_service, lul_variable, lul_value_old, lul_value_new)
	log.debug("lul_device = ", lul_device,
	", lul_service = ", lul_service,
	", lul_variable = ", lul_variable,
	", lul_value_old = ", lul_value_old,
	", lul_value_new = ", lul_value_new)

	local hostNamePrefix = util.getLuupVariable(SID.ZABBIX, "HostNamePrefix", g_deviceId, util.T_STRING)

	local outputData = {
		hostNamePrefix,
		"_",
		lul_device,
		" ",
		buildKey (lul_service, lul_variable),
		" ",
		lul_value_new,
		"\n"
	}

	local outputLine = table.concat(outputData)

	log.debug ("Sending to Zabbix, outputLine = |", outputLine, "|")

	g_sender:write (outputLine)
	g_sender:flush ()

	log.debug ("Done sending to Zabbix")

end

---------------------------------------------------
---------- Zabbix Import File Generation ----------
---------------------------------------------------

local function generateTemplates(xmlOutput, statusData, templateType, templateGroupName)
	local xmlChunk

	table.insert(xmlOutput, "<templates>\n")

	-- build a list of services, variables, and variable types used by all currently active devices
	local serviceList = {}
	for i, deviceData in pairs (statusData.devices) do
		for j, state in pairs(deviceData.states) do
			if (serviceList[state.service] == nil) then
				serviceList[state.service] = {}
			end
			-- assume any new value is numeric first
			if (serviceList[state.service][state.variable] == nil) then
				serviceList[state.service][state.variable] = 0
			end
			-- if we are unable to convert the value to a number, assume that
			-- the variable holds character values
			if (tonumber(state.value) == nil) then
				serviceList[state.service][state.variable] = 1
			end
		end
	end

	-- add a template for each service
	for service, variables in pairs (serviceList) do

		xmlChunk =
		[[
        <template>
            <template>__TEMPLATE_NAME__</template>
            <name>__TEMPLATE_DISPLAY_NAME__</name>
            <groups>
                <group>
                    <name>__TEMPLATE_GROUP_NAME__</name>
                </group>
            </groups>
            <discovery_rules/>
            <macros/>
            <templates/>
            <applications>
            	<application>
            		<name>__TEMPLATE_DISPLAY_NAME__</name>
            	</application>
            </applications>
            <screens/>
]]    
		xmlChunk = xmlChunk:gsub("__TEMPLATE_GROUP_NAME__", templateGroupName)
		xmlChunk = xmlChunk:gsub("__TEMPLATE_NAME__", service:gsub(":", "_"))
		xmlChunk = xmlChunk:gsub("__TEMPLATE_DISPLAY_NAME__", service)

		table.insert(xmlOutput, xmlChunk)
		table.insert(xmlOutput, "<items>\n")

		if (templateType == "full") then

			for variable, valueType in pairs(variables) do
				local xmlChunk =
				[[
                <item>
                    <name>__VARIABLE__</name>
                    <type>2</type>
                    <snmp_community/>
                    <multiplier>0</multiplier>
                    <snmp_oid/>
                    <key>__KEY__</key>
                    <delay>0</delay>
                    <history>90</history>
                    <trends>365</trends>
                    <status>0</status>
                    <value_type>__VALUE_TYPE__</value_type>
                    <allowed_hosts/>
                    <units/>
                    <delta>0</delta>
                    <snmpv3_securityname/>
                    <snmpv3_securitylevel>0</snmpv3_securitylevel>
                    <snmpv3_authpassphrase/>
                    <snmpv3_privpassphrase/>
                    <formula>1</formula>
                    <delay_flex/>
                    <params/>
                    <ipmi_sensor/>
                    <data_type>0</data_type>
                    <authtype>0</authtype>
                    <username/>
                    <password/>
                    <publickey/>
                    <privatekey/>
                    <port/>
                    <description/>
                    <inventory_link>0</inventory_link>
                    <valuemap/>
            		<applications>
            			<application>
            				<name>__TEMPLATE_DISPLAY_NAME__</name>
            			</application>
            		</applications>
			</item>
]]
				xmlChunk = xmlChunk:gsub("__VARIABLE__", variable)
				xmlChunk = xmlChunk:gsub("__KEY__", buildKey(service,variable))
				xmlChunk = xmlChunk:gsub("__VALUE_TYPE__", valueType)
				xmlChunk = xmlChunk:gsub("__TEMPLATE_DISPLAY_NAME__", service)
				table.insert(xmlOutput, xmlChunk)

			end
		end

		table.insert(xmlOutput, "</items>\n")
		table.insert(xmlOutput, "</template>\n")

	end

	table.insert(xmlOutput, "</templates>\n")

end

local function generateHosts(xmlOutput, statusData, hostGroupName, hostNamePrefix)
	table.insert(xmlOutput, "<hosts>\n")

	for i, deviceData in pairs (statusData.devices) do
		local deviceId = tonumber(deviceData.id)

		local xmlChunk =
		[[
			<host>
            <host>__DEVICE_HOST_NAME_</host>
            <name>__DEVICE_DISPLAY_NAME__</name>
            <proxy/>
            <status>0</status>
            <ipmi_authtype>-1</ipmi_authtype>
            <ipmi_privilege>2</ipmi_privilege>
            <ipmi_username/>
            <ipmi_password/>
            <groups>
                <group>
                    <name>__HOST_GROUP_NAME__</name>
                </group>
            </groups>
            <interfaces>
                <interface>
                    <default>1</default>
                    <type>1</type>
                    <useip>1</useip>
                    <ip>127.0.0.1</ip>
                    <dns/>
                    <port>10050</port>
                    <interface_ref>if1</interface_ref>
                </interface>
            </interfaces>
            <applications/>
            <items/>
            <discovery_rules/>
            <macros/>
            <inventory/>
]]

		xmlChunk = xmlChunk:gsub("__HOST_GROUP_NAME__", hostGroupName)
		xmlChunk = xmlChunk:gsub("__DEVICE_HOST_NAME_", hostNamePrefix .. "_" .. deviceId)
		xmlChunk = xmlChunk:gsub("__DEVICE_DISPLAY_NAME__", hostNamePrefix .. " - " ..
		luup.devices[deviceId].description .. " (#" .. deviceId .. ")")
		table.insert(xmlOutput, xmlChunk)

		-- build list of services for this device
		local serviceList = {}
		for j, state in pairs(deviceData.states) do
			serviceList[state.service] = true
		end

		table.insert(xmlOutput, "<templates>\n")
		-- output a template entry for each service
		for service, flag in pairs (serviceList) do
			table.insert(xmlOutput, "<template><name>" .. service:gsub(":", "_") .. "</name></template>\n")
		end

		table.insert(xmlOutput, "</templates>\n")
		table.insert(xmlOutput, "</host>\n")

	end

	table.insert(xmlOutput, "</hosts>\n")
end

--- Generate a Zabbix XML host file that can be imported directly into Zabbix
function generateZabbixImportFile (lul_request, lul_parameters, lul_outputformat)
	log.info ("Generating Zabbix import file, lul_request = ", lul_request, ", lul_parameters = ", lul_parameters, ", lul_outputformat = ", lul_outputformat)

	local templateType = "none"

	if (lul_parameters.templates ~= nil) then
		templateType = lul_parameters.templates
	end

	local hostNamePrefix  = util.getLuupVariable(SID.ZABBIX, "HostNamePrefix", g_deviceId, util.T_STRING)
	local hostGroupName = util.getLuupVariable(SID.ZABBIX, "HostGroupName", g_deviceId, util.T_STRING)
	local templateGroupName = util.getLuupVariable(SID.ZABBIX, "TemplateGroupName", g_deviceId, util.T_STRING)

	local statusData = util.httpGetJSON(g_statusUrl)

	local xmlOutput = {}

	--
	-- Output Header
	--

	local xmlChunk =
	[[
<?xml version="1.0" encoding="UTF-8"?>
<zabbix_export>
    <version>2.0</version>
    <date>__DATE__</date>
    <groups>
        <group>
            <name>__HOST_GROUP_NAME__</name>
        </group>
		<group>
			<name>__TEMPLATE_GROUP_NAME__</name>
		</group>
    </groups>
]]

	xmlChunk = xmlChunk:gsub("__DATE__", os.date("%Y-%m-%dT%H:%M:%S", os.time()))
	xmlChunk = xmlChunk:gsub("__HOST_GROUP_NAME__", hostGroupName)
	xmlChunk = xmlChunk:gsub("__TEMPLATE_GROUP_NAME__", templateGroupName)
	table.insert(xmlOutput, xmlChunk)

	--
	-- Output Placeholder Template Definitions (in case they are not already defined in Zabbix)
	--

	if (templateType ~= "none") then
		generateTemplates(xmlOutput, statusData, templateType, templateGroupName)
	end

	--
	-- Output Host Configurations
	--
	generateHosts(xmlOutput, statusData, hostGroupName, hostNamePrefix)


	table.insert(xmlOutput, "</zabbix_export>\n")

	log.info ("Done generating import file")

	return table.concat(xmlOutput)
end



------------------------------------------
-------- Initialization Functions --------
------------------------------------------

-- Register variable_watch listeners for every service of every device
local function registerListeners ()
	log.info ("Registering listeners")

	local statusData = util.httpGetJSON(g_statusUrl)

	-- for each Vera device ...
	for i, deviceData in pairs(statusData.devices) do
		local services = {}
		-- build unique services list for each device
		for j, state in pairs(deviceData.states) do
			services[state.service] = true
		end
		-- add listeners for each service in the list
		for service, data in pairs(services) do
			log.debug ("Adding watch for deviceId ", deviceData.id,", service ", service)
			luup.variable_watch("variableWatchCallback", service, nil, tonumber(deviceData.id))
		end
	end
	log.info ("Done registering listeners")
end

--- init Luup variables if they don't have values
local function initLuupVariables()
	util.initVariableIfNotSet(SID.ZABBIX, "ZabbixServer", "0.0.0.0", g_deviceId)
	util.initVariableIfNotSet(SID.ZABBIX, "AgentHostName", "vera", g_deviceId)
	util.initVariableIfNotSet(SID.ZABBIX, "HostNamePrefix", "vera", g_deviceId)
	util.initVariableIfNotSet(SID.ZABBIX, "HostGroupName", "Vera Devices", g_deviceId)
	util.initVariableIfNotSet(SID.ZABBIX, "TemplateGroupName", "MiOS Templates", g_deviceId)
end

local function startZabbixSender()
	executeCommand("chmod a+rx " .. SENDER_PATH)

	local senderCommandLine = SENDER_PATH .. " -c " .. CONFIG_FILE .. " -r -i - 1>" .. SENDER_STDOUT_FILE .. " 2>&1"
	log.info ("senderCommandLine = ", senderCommandLine)

	g_sender = io.popen(senderCommandLine, "w")
	g_sender:flush ()
end

local function startZabbixAgent()
	-- kill any existing zabbix agent processes
	executeCommand("killall " .. AGENT_BIN)

	-- Even after the kill command has executed, we need to sleep
	-- a little more to give enough time for all zabbix_agentd
	-- subprocesses to stop
	luup.sleep(2000)

	local configFile = io.open(CONFIG_FILE, "w")
	configFile:write ("AllowRoot=1\n")
	configFile:write ("PidFile="..AGENT_PID_FILE .. "\n")
	configFile:write ("LogFile="..AGENT_LOG_FILE .. "\n")
	configFile:write ("Server=" .. util.getLuupVariable(SID.ZABBIX, "ZabbixServer", g_deviceId, util.T_STRING) .. "\n")
	configFile:write ("Hostname=".. util.getLuupVariable(SID.ZABBIX, "AgentHostName", g_deviceId, util.T_STRING) .. "\n")
	configFile:close ()

	executeCommand("chmod a+rx " .. AGENT_PATH)
	executeCommand(AGENT_PATH .. " -c " .. CONFIG_FILE .. " 1>" .. AGENT_STDOUT_FILE .. " 2>&1 &")
end

--- Initialize the  plugin
function initialize(lul_device)
	local success = false
	local errorMsg = nil

	g_deviceId = tonumber(lul_device)

	util.initLogging(LOG_PREFIX, DEFAULT_LOG_CONFIG, SID.ZABBIX, g_deviceId)

	log.info ("Initializing Zabbix plugin for device " , g_deviceId)

	-- set plugin version number
	luup.variable_set(SID.ZABBIX, "PluginVersion", PLUGIN_VERSION, g_deviceId)

	initLuupVariables()

	startZabbixAgent()

	startZabbixSender()

	registerListeners()

	luup.register_handler("generateZabbixImportFile","generateZabbixImportFile")

	log.info("Done with initialization")

	return success, errorMsg, "Zabbix"
end


-- RETURN GLOBAL FUNCTIONS
return {
	initialize=initialize
}