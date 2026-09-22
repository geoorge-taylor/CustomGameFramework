--!strict
--[[
	Server Socket:
	Networking abstraction — one socket per service. A socket owns a reliable
	RemoteEvent, a RemoteFunction, and an UnreliableRemoteEvent, and multiplexes
	many named events over them (the event name is the first argument).

	- Reliable, ordered delivery via :Fire / :FireAll / :FireAllExcept
	- Fire-and-forget, unordered delivery via :FireUnreliable (server -> client),
	  for high-frequency latest-wins data where a dropped packet doesn't matter
	- One listener per event name (enforces the one-socket-per-service model)

	Every send is gated on Loader:IsPlayerReady. A client registers its listeners in
	its Start pass and only then signals ready, so anything fired at it before that
	point cannot be received — it would arrive as a "No client listener" warning and
	be silently dropped by the client anyway. Gating here makes that impossible to
	get wrong: services send freely, and each player's real state arrives through the
	snapshot they register on Loader:OnPlayerReady.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local Loader = require(script.Parent:WaitForChild("Loader"))

-- Container that holds every service's socket folder.
local RemotesContainer: Folder
if RunService:IsRunning() and RunService:IsServer() then
	RemotesContainer = Instance.new("Folder")
	RemotesContainer.Name = "_remotes"
	RemotesContainer.Parent = ReplicatedStorage
end

type PlayerGroup = Player | { Player }
type Method = (...any) -> ...any

type ServerSocketProperties = {
	event: RemoteEvent,
	unreliable: UnreliableRemoteEvent,
	func: RemoteFunction,
	remotes: Folder,
	_eventListeners: { [string]: Method },
	_funcListeners: { [string]: Method },
}

local ServerSocket = {}
ServerSocket.__index = ServerSocket

export type ServerSocket = typeof(setmetatable({} :: ServerSocketProperties, ServerSocket))

--[=[
	Normalises a Player or list of Players into the list of recipients that can
	actually receive right now.
	@param players Player | { Player } -- The requested recipient(s).
	@return { Player } -- The ready subset (may be empty).
]=]
local function readyRecipients(players: PlayerGroup): { Player }
	if typeof(players) == "Instance" then
		return if Loader:IsPlayerReady(players) then { players } else {}
	end

	local ready = {}
	for _, player in players :: { Player } do
		if Loader:IsPlayerReady(player) then
			table.insert(ready, player)
		end
	end
	return ready
end

--[=[
	Constructs a new server socket for a service.
	@param id string -- Service name; also the socket folder's name (must be unique).
	@return ServerSocket -- The constructed socket.
]=]
function ServerSocket.new(id: string): ServerSocket
	assert(RunService:IsServer(), "ServerSocket can only be created on the server")
	assert(not RemotesContainer:FindFirstChild(id), `A socket with id "{id}" already exists`)

	local self = setmetatable({}, ServerSocket) :: ServerSocket
	self._eventListeners = {}
	self._funcListeners = {}

	local remotes = Instance.new("Folder")
	local event = Instance.new("RemoteEvent")
	local unreliable = Instance.new("UnreliableRemoteEvent")
	local func = Instance.new("RemoteFunction")
	event.Parent = remotes
	unreliable.Parent = remotes
	func.Parent = remotes

	self.remotes = remotes
	self.event = event
	self.unreliable = unreliable
	self.func = func

	remotes.Name = id

	event.OnServerEvent:Connect(function(player: Player, eventName: string, ...: any)
		local callback = self._eventListeners[eventName]
		if not callback then
			warn(`No server listener for "{eventName}" (fired by {player.Name})`)
			return
		end
		callback(player, ...)
	end)

	func.OnServerInvoke = function(player: Player, funcName: string, ...: any): ...any
		local callback = self._funcListeners[funcName]
		if not callback then
			warn(`No server function "{funcName}" (invoked by {player.Name})`)
			return
		end
		return callback(player, ...)
	end

	remotes.Parent = RemotesContainer
	return self
end

--[=[
	Registers the single listener for an event name (client -> server).
	@param eventName string -- Event to listen for.
	@param callback Method -- Called as callback(player, ...).
	@return () -- No return value.
]=]
function ServerSocket:Connect(eventName: string, callback: Method)
	local self = self :: ServerSocket
	if self._eventListeners[eventName] then
		error(`Event "{eventName}" already has a listener`)
	end
	self._eventListeners[eventName] = callback
end

--[=[
	Registers the single handler for a remote function (client invokes, server returns).
	@param funcName string -- Function name to handle.
	@param callback Method -- Called as callback(player, ...); its return is sent back.
	@return () -- No return value.
]=]
function ServerSocket:Function(funcName: string, callback: Method)
	local self = self :: ServerSocket
	if self._funcListeners[funcName] then
		error(`Remote function "{funcName}" already has a handler`)
	end
	self._funcListeners[funcName] = callback
end

--[=[
	Reliably fires an event to one player or a list of players.
	@param players Player | { Player } -- Recipient(s).
	@param eventName string -- Event to fire.
	@param ... any -- Arguments passed to the client listener.
	@return () -- No return value.
]=]
function ServerSocket:Fire(players: PlayerGroup, eventName: string, ...: any)
	local self = self :: ServerSocket
	for _, player in readyRecipients(players) do
		self.event:FireClient(player, eventName, ...)
	end
end

--[=[
	Unreliably fires an event to one player or a list of players. Fire-and-forget:
	no delivery or ordering guarantee. Use for high-frequency, latest-wins data
	(e.g. streamed positions) where a dropped packet is harmless.
	@param players Player | { Player } -- Recipient(s).
	@param eventName string -- Event to fire.
	@param ... any -- Arguments passed to the client listener.
	@return () -- No return value.
]=]
function ServerSocket:FireUnreliable(players: PlayerGroup, eventName: string, ...: any)
	local self = self :: ServerSocket
	for _, player in readyRecipients(players) do
		self.unreliable:FireClient(player, eventName, ...)
	end
end

--[=[
	Reliably fires an event to every player.
	@param eventName string -- Event to fire.
	@param ... any -- Arguments passed to the client listener.
	@return () -- No return value.
]=]
function ServerSocket:FireAll(eventName: string, ...: any)
	local self = self :: ServerSocket
	for _, player in Players:GetPlayers() do
		if Loader:IsPlayerReady(player) then
			self.event:FireClient(player, eventName, ...)
		end
	end
end

--[=[
	Reliably fires an event to every player except the excluded one(s).
	@param excluded Player | { Player } -- Recipient(s) to skip.
	@param eventName string -- Event to fire.
	@param ... any -- Arguments passed to the client listener.
	@return () -- No return value.
]=]
function ServerSocket:FireAllExcept(excluded: PlayerGroup, eventName: string, ...: any)
	local self = self :: ServerSocket
	local excludedList: { Player } = if typeof(excluded) == "Instance" then { excluded } else excluded
	for _, player in Players:GetPlayers() do
		if not table.find(excludedList, player) and Loader:IsPlayerReady(player) then
			self.event:FireClient(player, eventName, ...)
		end
	end
end

--[=[
	Destroys the socket and its remotes.
	@return () -- No return value.
]=]
function ServerSocket:Destroy()
	local self = self :: ServerSocket
	self.remotes:Destroy()
end

return ServerSocket
