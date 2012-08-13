-- Main implementation file for Zabbix Plugin
--

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

local PLUGIN_VERSION = "0.1"
local LOG_PREFIX = "Zabbix"

local CONFIG_FILE = "/tmp/mios_zabbix_agentd.conf"
local SENDER_PATH = "/etc/cmh-ludl/mios_zabbix_sender"
local AGENT_PATH = "/etc/cmh-ludl/mios_zabbix_agentd"


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

local g_agentPath = "/etc/cmh-ludl/mios_zabbix_agentd"

-----------------------------------------
--------- Utility Functions -------------
-----------------------------------------

--- Build the Zabbix "Key" for a specific device / service / variable
local function buildKey(deviceId, service, variable)
	return "mios.upnp[" .. deviceId .. "," .. service .. "," .. variable .. "]"
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

	local hostName = util.getLuupVariable(SID.ZABBIX, "VeraHostName", g_deviceId, util.T_STRING)

	local outputData = {
		hostName,
		buildKey (lul_device, lul_service, lul_variable),
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

------------------------------------------------
---------- Zabbix Template Generation ----------
------------------------------------------------
--
local function generateApplicationXml(deviceId)
	return ("<application><name>MiOS - " .. luup.devices[tonumber(deviceId)].description .. "</name></application>")
end

local function generateItemXml(deviceId, state)
	log.trace ("Generating Zabbix template item: deviceId = ", deviceId, ", state = ", state)

	local itemXml = {}
	
	table.insert(itemXml, "<item>\n")
	table.insert (itemXml, "<name>" .. state.service .. " - " .. state.variable .. "</name>\n")
	table.insert (itemXml, "<key>" .. buildKey(deviceId, state.service, state.variable) .. "</key>\n")
	
	-- guess the Zabbix type of the variable based on its current value (Yuck - talk about a horrible hack!!!)
	-- Zabbix types:
	--  0 - float
	--  1 - character
	--  2 - log
	--  3 - unsigned
	--  4 - text
	
	if (tonumber(state.value) == nil) then
		table.insert(itemXml, "<value_type>4</value_type>\n")
	else
		table.insert(itemXml, "<value_type>0</value_type>\n")
	end

	table.insert(itemXml, "<applications>\n" .. generateApplicationXml(deviceId) .. "</applications>\n")

	table.insert (itemXml, 
[[
	<type>2</type><snmp_community/><multiplier>0</multiplier><snmp_oid/>
	<delay>0</delay><history>90</history>
	<trends>365</trends><status>0</status>
	<allowed_hosts/><units/><delta>0</delta>
	<snmpv3_securityname/><snmpv3_securitylevel>0</snmpv3_securitylevel><snmpv3_authpassphrase/><snmpv3_privpassphrase/>
	<formula>1</formula><delay_flex/><params/><ipmi_sensor/><data_type>0</data_type><authtype>0</authtype><username/>
	<password/><publickey/><privatekey/><port/><description/><inventory_link>0</inventory_link>
	<valuemap/>
	</item>
]]
	)

	return table.concat(itemXml)
end

--- Generate a Zabbix XML template that can be imported directly into Zabbix
function generateZabbixTemplate (lul_request, lul_parameters, lul_outputformat)
	log.info ("Generating Zabbix template, lul_request = ", lul_request, ", lul_paramters = ", lul_parameters, ", lul_outputformat = ", lul_outputformat)

	local statusData = util.httpGetJSON(g_statusUrl)

	local templateXml = {}

	local xmlChunk =
[[
<?xml version="1.0" encoding="UTF-8"?>
<zabbix_export>
    <version>2.0</version>
    <date>__DATE__</date>
    <groups>
        <group>
            <name>Templates</name>
        </group>
    </groups>
    <templates>
        <template>
            <template>__HOSTNAME__ Template</template>
            <name>Template For MiOS Host __HOSTNAME__</name>
            <groups>
                <group>
                    <name>Templates</name>
                </group>
            </groups>
   			 <applications>
]]

	xmlChunk = xmlChunk:gsub("__DATE__", os.date("%Y-%m-%dT%H:%M:%S", os.time()))
	xmlChunk = xmlChunk:gsub("__HOSTNAME__", util.getLuupVariable(SID.ZABBIX, "VeraHostName", g_deviceId, util.T_STRING))

	table.insert(templateXml, xmlChunk)

	for i, deviceData in pairs (statusData.devices) do
		table.insert (templateXml, generateApplicationXml(deviceData.id))
	end
	
	xmlChunk = 
[[
			</applications>
            <items>
]]

	table.insert(templateXml, xmlChunk)

	-- for each Vera device ...
	for i, deviceData in pairs (statusData.devices) do
		-- write each variable to the export file
		for j, state in pairs(deviceData.states) do
			table.insert(templateXml, generateItemXml(deviceData.id, state))
		end
	end

	local xmlChunk =
[[
            </items>
            <discovery_rules/>
            <macros/>
            <templates/>
            <screens/>
        </template>
    </templates>
</zabbix_export>
]]

	table.insert(templateXml, xmlChunk)

	log.info ("Done generating template file")

	return table.concat(templateXml)
end



------------------------------------------
-------- Initialization Functions --------
------------------------------------------

-- Register variable_watch listeners for every service of every device
local function registerListeners (statusData)
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
	util.initVariableIfNotSet(SID.ZABBIX, "VeraHostName", "Vera", g_deviceId)
end

local function startZabbixSender()
	local senderPath = util.getLuupVariable(SID.ZABBIX, "SenderPath", g_deviceId, util.T_STRING)
	local agentConfigFile = util.getLuupVariable(SID.ZABBIX, "AgentConfigFile", g_deviceId, util.T_STRING)
	
	local commandLine = "chmod a+rx " .. SENDER_PATH
	log.info ("commandLine = ", commandLine)
	local returnCode = os.execute (commandLine)
	log.info ("returnCode = ", returnCode)

	commandLine = SENDER_PATH .. " -c " .. CONFIG_FILE .. " -r -i - 1>/tmp/mios_zabbix_sender.out 2>&1"
	log.info ("commandLine = ", commandLine)
	
	g_sender = io.popen(commandLine, "w")
	g_sender:flush ()

end

local function startZabbixAgent()
	local commandLine = "killall " .. "mios_zabbix_agentd 1>/tmp/mios_zabbix_killall.out 2>&1"
	log.info ("commandLine = ", commandLine)
	local returnCode = os.execute (commandLine)
	log.info ("returnCode = ", returnCode)
	
	-- sleep to give enough time for all mios_zabbix_agentd subprocesses to stop
	luup.sleep(2500)
	
	local configFile = io.open(CONFIG_FILE, "w")
	configFile:write ("AllowRoot=1\n")
	configFile:write ("PidFile=/tmp/mios_zabbix_agentd.pid\n")
	configFile:write ("LogFile=/tmp/mios_zabbix_agentd.log\n")
	configFile:write ("Server=" .. util.getLuupVariable(SID.ZABBIX, "ZabbixServer", g_deviceId, util.T_STRING) .. "\n")
	configFile:write ("Hostname=".. util.getLuupVariable(SID.ZABBIX, "VeraHostName", g_deviceId, util.T_STRING) .. "\n")
	configFile:close ()
	
	local commandLine = "chmod a+rx " .. AGENT_PATH
	log.info ("commandLine = ", commandLine)
	local returnCode = os.execute (commandLine)
	log.info ("returnCode = ", returnCode)
	
	local commandLine = AGENT_PATH .. " -c " .. CONFIG_FILE .. " 1>/tmp/mios_zabbix_agentd.out 2>&1 &"
	log.info ("commandLine = ", commandLine)
	local returnCode = os.execute (commandLine)
	log.info ("returnCode = ", returnCode)
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
	
	registerListeners(statusData)

	luup.register_handler("generateZabbixTemplate","generateZabbixTemplate")

	log.info("Done with initialization")

	return success, errorMsg, "Zabbix"
end


-- RETURN GLOBAL FUNCTIONS
return {
	initialize=initialize
}