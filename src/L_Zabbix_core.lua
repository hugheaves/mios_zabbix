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

local SID = {
	ZABBIX = "urn:hugheaves-com:serviceId:Zabbix1"
}

local LOG_FILTER = {
	["L_Zabbix_core.lua$"] = {
	},
	["L_Zabbix_util.lua$"] = {
	}
}

local SEND_INTERVAL = 30

-- GLOBALS
local g_deviceId = nil
local g_events = { [0] = {} }
local g_eventsIndex = 0
local g_statusUrl = "http://localhost:3480/data_request?id=lu_status2&output_format=json"

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

	local eventData = {}
	eventData.deviceId = tonumber(lul_device)
	eventData.service = lul_service
	eventData.variable = lul_variable
	eventData.value = lul_value_new
	eventData.timestamp = os.time()

	table.insert(g_events[g_eventsIndex], eventData)

	log.debug ("g_eventsIndex = ", g_eventsIndex, ", #g_events= ", #g_events, ", eventData = ", eventData)
end

--- Send the current set of events to Zabbix
function sendEvents (data)
	local currentEventsIndex = g_eventsIndex
	g_events[g_eventsIndex + 1] = {}
	g_eventsIndex = g_eventsIndex + 1

	if (#g_events[currentEventsIndex] > 0) then

		log.debug ("Writing events to zabbix_sender process")

		local hostName = util.getLuupVariable(SID.ZABBIX, "HostName", g_deviceId, util.T_STRING)
		local senderPath = util.getLuupVariable(SID.ZABBIX, "SenderPath", g_deviceId, util.T_STRING)
		local agentConfigFile = util.getLuupVariable(SID.ZABBIX, "AgentConfigFile", g_deviceId, util.T_STRING)

		local commandLine = senderPath .. " -vv -T -s " .. hostName .. " -c " .. agentConfigFile .. " -i - >> /tmp/crud"
		log.debug ("commandLine = ", commandLine)
		local output = io.popen(commandLine, "w")

		for index, eventData in pairs(g_events[currentEventsIndex]) do
			local outputLine  = hostName .. " " .. buildKey (eventData.deviceId, eventData.service, eventData.variable) .. " ".. eventData.timestamp.. " ".. eventData.value.. "\n"
			log.debug ("outputLine: [", outputLine, "]")
			output:write (outputLine)
		end

		output:close()
	else
		log.info ("No events to send to Zabbix")
	end

	g_events[currentEventsIndex] = nil

	luup.call_delay("sendEvents", util.getLuupVariable(SID.ZABBIX, "SendInterval", g_deviceId, util.T_NUMBER), "true", true)
end

------------------------------------------------
---------- Zabbix Template Generation ----------
------------------------------------------------

--- write an item to the template
local function generateItem(deviceId, state)
	log.trace ("Generating Zabbix template item: deviceId = ", deviceId, ", state = ", state)

	local item =
[[
<item><name>__NAME__</name><type>2</type><snmp_community/><multiplier>0</multiplier><snmp_oid/><key>__KEY__</key><delay>0</delay><history>90</history>
<trends>365</trends><status>0</status><value_type>__TYPE__</value_type><allowed_hosts/><units/><delta>0</delta>
<snmpv3_securityname/><snmpv3_securitylevel>0</snmpv3_securitylevel><snmpv3_authpassphrase/><snmpv3_privpassphrase/>
<formula>1</formula><delay_flex/><params/><ipmi_sensor/><data_type>0</data_type><authtype>0</authtype><username/>
<password/><publickey/><privatekey/><port/><description/><inventory_link>0</inventory_link><applications/><valuemap/></item>
]]
	item = item:gsub("__NAME__", buildKey(deviceId, state.service, state.variable))
	item = item:gsub("__KEY__", buildKey(deviceId, state.service, state.variable))

	-- guess the Zabbix type of the variable based on its current value (Yuck - talk about a horrible hack!!!)
	-- Zabbix types:
	--  0 - float
	--  1 - character
	--  2 - log
	--  3 - unsigned
	--  4 - text

	if (tonumber(state.value) == nil) then
		item = item:gsub("__TYPE__", "4")
	else
		item = item:gsub("__TYPE__", "0")
	end

	return item
end

--- Generate a Zabbix XML template that can be imported directly into Zabbix
function generateZabbixTemplate (lul_request, lul_parameters, lul_outputformat)
	log.info ("Generating Zabbix template, lul_request = ", lul_request, ", lul_paramters = ", lul_parameters, ", lul_outputformat = ", lul_outputformat)

	local statusData = util.httpGetJSON(g_statusUrl)

	local templateData = {}

	local header =
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
            <applications/>
            <items>
]]

	header = header:gsub("__DATE__", os.date("%y-%m-%dT%H:%M:%S", os.time()))
	header = header:gsub("__HOSTNAME__", util.getLuupVariable(SID.ZABBIX, "HostName", g_deviceId, util.T_STRING))

	table.insert(templateData, header)

	-- for each Vera device ...
	for i, deviceData in pairs (statusData.devices) do
		-- write each variable to the export file
		for j, state in pairs(deviceData.states) do
			table.insert(templateData, generateItem(tonumber(deviceData.id), state))
		end
	end

	local footer =
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

	table.insert(templateData, footer)

	log.info ("Done generating template file")
	
	return table.concat(templateData)
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
	util.initVariableIfNotSet(SID.ZABBIX, "HostName", "veralite", g_deviceId)
	util.initVariableIfNotSet(SID.ZABBIX, "SenderPath", "/usr/bin/zabbix_sender", g_deviceId)
	util.initVariableIfNotSet(SID.ZABBIX, "AgentConfigFile", "/etc/zabbix_agentd.conf", g_deviceId)
	util.initVariableIfNotSet(SID.ZABBIX, "TemplateFile", "/tmp/zabbix_template.xml", g_deviceId)
	util.initVariableIfNotSet(SID.ZABBIX, "SendInterval", 30, g_deviceId)
end

--- Initialize the  plugin
function initialize(lul_device)
	local success = false
	local errorMsg = nil

	g_deviceId = tonumber(lul_device)

	util.initLogging(LOG_PREFIX, LOG_FILTER, SID.ZABBIX, "LogLevel", g_deviceId)

	log.info ("Initializing Zabbix plugin for device " , g_deviceId)

	-- set plugin version number
	luup.variable_set(SID.ZABBIX, "PluginVersion", PLUGIN_VERSION, g_deviceId)

	initLuupVariables()

	luup.call_delay("sendEvents", util.getLuupVariable(SID.ZABBIX, "SendInterval", g_deviceId, util.T_NUMBER), "true", true)

	registerListeners(statusData)

	luup.register_handler("generateZabbixTemplate","generateZabbixTemplate")
	
	log.info("Done with initialization")

	return success, errorMsg, "Zabbix"
end


-- RETURN GLOBAL FUNCTIONS
return {
	initialize=initialize
}