--!strict
--[[
	Client Socket:
	The client half of a service's socket. One controller connects to one socket.
	It listens on both the reliable RemoteEvent and the UnreliableRemoteEvent and
	dispatches both to the same per-event listeners, so the receiver never has to
	care which reliability the server chose — only the sender decides that.

	The server never invokes the client.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local RemotesContainer = ReplicatedStorage:WaitForChild("_remotes")

type Method = (...any) -> ...any

type ClientSocketProperties = {
	event: RemoteEvent,
	unreliable: UnreliableRemoteEvent,
	func: RemoteFunction,
	remotes: Folder,
	_listeners: { [string]: Method },
}

local ClientSocket = {}
ClientSocket.__index = ClientSocket

export type ClientSocket = typeof(setmetatable({} :: ClientSocketProperties, ClientSocket))

--[=[
	Constructs a new client socket for a service (whose server socket must exist).
	@param id string -- Service name; matches the server socket's id.
	@return ClientSocket -- The constructed socket.
]=]
function ClientSocket.new(id: string): ClientSocket
	assert(not RunService:IsServer(), "ClientSocket can only be created on the client")
	assert(RemotesContainer:FindFirstChild(id), `No server socket with id "{id}" exists`)

	local self = setmetatable({}, ClientSocket) :: ClientSocket
	self._listeners = {}

	local remotes = RemotesContainer:WaitForChild(id) :: Folder
	self.remotes = remotes
	self.event = remotes:WaitForChild("RemoteEvent") :: RemoteEvent
	self.unreliable = remotes:WaitForChild("UnreliableRemoteEvent") :: UnreliableRemoteEvent
	self.func = remotes:WaitForChild("RemoteFunction") :: RemoteFunction

	local function dispatch(eventName: string, ...: any)
		local callback = self._listeners[eventName]
		if not callback then
			warn(`No client listener for "{eventName}" on socket "{id}"`)
			return
		end
		callback(...)
	end

	self.event.OnClientEvent:Connect(dispatch)
	self.unreliable.OnClientEvent:Connect(dispatch)

	remotes.Destroying:Once(function()
		self:Destroy()
	end)

	return self
end

--[=[
	Registers the single listener for an event name (received from the server on
	either the reliable or unreliable channel).
	@param eventName string -- Event to listen for.
	@param callback Method -- Called as callback(...).
	@return () -- No return value.
]=]
function ClientSocket:Connect(eventName: string, callback: Method)
	local self = self :: ClientSocket
	if self._listeners[eventName] then
		error(`Event "{eventName}" already has a listener`)
	end
	self._listeners[eventName] = callback
end

--[=[
	Fires an event to the server (always reliable; the server never invokes back).
	@param eventName string -- Event to fire.
	@param ... any -- Arguments passed to the server listener.
	@return () -- No return value.
]=]
function ClientSocket:Fire(eventName: string, ...: any)
	local self = self :: ClientSocket
	if RunService:IsRunning() then
		self.event:FireServer(eventName, ...)
	end
end

--[=[
	Invokes a remote function on the server and waits for its return.
	@param funcName string -- Function name to invoke.
	@param ... any -- Arguments passed to the server handler.
	@return any -- Whatever the server handler returns.
]=]
function ClientSocket:Invoke(funcName: string, ...: any): ...any
	local self = self :: ClientSocket
	if RunService:IsRunning() then
		return self.func:InvokeServer(funcName, ...)
	end
	return nil
end

--[=[
	Destroys the socket (and its remotes reference).
	@return () -- No return value.
]=]
function ClientSocket:Destroy()
	local self = self :: ClientSocket
	self.remotes:Destroy()
end

return ClientSocket
