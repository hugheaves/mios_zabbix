-- MiOS Plugin for Radio Thermostat Corporation of America, Inc. Wi-Fi Thermostats
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

luup = require ("LuupTestHarness")

luup.devices = { [0] = { ["ip"] = "10.23.45.1" } }
luup.variable_set("urn:schemas-hugheaves-com:serviceId:Zabbix1", "LogLevel", "30", "0")

luup._addFunctions(require("L_Zabbix_core"))

luup.call_delay("initialize", 1, "0", "0")

luup._callbackLoop()