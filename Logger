--!strict
--[=[
	Console logger singleton. Formats console output consistently as
	"[Level - trace]: message" and drops anything below the current logging level,
	so verbosity is one setting rather than scattered prints. The level defaults to
	Debug (most verbose) so the logger is usable without setup; call SetLevel to
	tighten it.
]=]

-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Data
local Enums = ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Data"):WaitForChild("Enums")
local LoggingLevels = require(Enums:WaitForChild("LoggingLevels"))

type ConsoleLoggerProperties = {
	_level: number,
}

local ConsoleLogger = {}
ConsoleLogger.__index = ConsoleLogger
ConsoleLogger._level = LoggingLevels.Debug

export type ConsoleLogger = typeof(setmetatable({} :: ConsoleLoggerProperties, ConsoleLogger))

--[=[
	Sets the minimum level a message must meet to be printed.
	@param level number -- A LoggingLevels value.
	@return () -- No return value.
]=]
function ConsoleLogger:SetLevel(level: number)
	local self = self :: ConsoleLogger
	self._level = level
end

--[=[
	Prints a debug message, if the current level allows it.
	@param trace string -- Where the message came from (module/method).
	@param message string -- The message to print.
	@return () -- No return value.
]=]
function ConsoleLogger:Debug(trace: string, message: string)
	local self = self :: ConsoleLogger
	if self._level < LoggingLevels.Debug then
		return
	end
	print(string.format("[Debug - %s]: %s", trace, message))
end

--[=[
	Warns, if the current level allows it.
	@param trace string -- Where the message came from (module/method).
	@param message string -- The message to warn with.
	@return () -- No return value.
]=]
function ConsoleLogger:Warn(trace: string, message: string)
	local self = self :: ConsoleLogger
	if self._level < LoggingLevels.Warn then
		return
	end
	warn(string.format("[Warning - %s]: %s", trace, message))
end

--[=[
	Raises an error, if the current level allows it.
	@param trace string -- Where the message came from (module/method).
	@param message string -- The message to raise.
	@return () -- No return value.
]=]
function ConsoleLogger:Error(trace: string, message: string)
	local self = self :: ConsoleLogger
	if self._level < LoggingLevels.Error then
		return
	end
	error(string.format("[Error - %s]: %s", trace, message))
end

return ConsoleLogger

