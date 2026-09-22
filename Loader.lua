--[=[
	Module loader:

	Ordering is fully automatic and needs no configuration:
	- Load order is handled by require (a required module loads before the module
	  that requires it), so the loader can load modules in any order.
	- Init/Start order does not matter, as long as each module sets up its own
	  state in Init and only calls OTHER modules in Start. Because every Init runs
	  before any Start, a Start can safely use any other module's Init-time state.
	  Keep to that discipline and there is nothing to order — no priority numbers.

	Other responsibilities:
	- Every lifecycle call is wrapped in xpcall so one bad module can't halt the
	  rest; failures are warned, successes printed only when verbose. A module whose
	  Init errors is skipped for Start.
	- The client waits for the server (Workspace "ServerLoaded") before loading, so
	  every server socket exists first.
	- Handshake (Option B): after the client finishes Start (every listener now
	  registered) it fires "_ClientReady"; the server marks that player ready, sets
	  their "ClientLoaded" attribute, and runs OnPlayerReady callbacks. Per player,
	  so late joiners are covered too.
	- Dependency access via :Get(name) — see the method doc for the typed pattern.
]=]

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local IS_SERVER = RunService:IsServer()
local VERBOSE_LOADING = script:GetAttribute("VerboseLoading") == true

local SERVER_LOADED_ATTRIBUTE = "ServerLoaded"
local CLIENT_READY_ATTRIBUTE = "ClientLoaded"
local CLIENT_READY_REMOTE = "_ClientReady"

local Loader = {}
Loader._started = false
Loader._loaded = {} -- name -> loaded module (singleton)
Loader._readyPlayers = {} -- player -> true
Loader._playerReadyCallbacks = {} -- { (player) -> () }

--[=[
	Collects the loadable ModuleScripts in a container (skipping any tagged
	IgnoreLoader), sorted by name for a deterministic, readable load order.
	@param container Instance -- Folder holding the service/controller modules.
	@return { ModuleScript } -- The modules to load, name-sorted.
]=]
local function getModules(container: Instance): { ModuleScript }
	local modules = {}
	for _, object in container:GetChildren() do
		if object:IsA("ModuleScript") and not object:GetAttribute("IgnoreLoader") then
			table.insert(modules, object)
		end
	end
	table.sort(modules, function(a, b)
		return a.Name < b.Name
	end)
	return modules
end

--[=[
	Requires a module and stores the result under its name. Errors are caught so a
	single failing module cannot halt the rest.
	@param module ModuleScript -- The module to require.
	@return () -- No return value.
]=]
function Loader:LoadModule(module: ModuleScript)
	local success, result = xpcall(require, function(err)
		return `{err}\n{debug.traceback()}`
	end, module)

	if not success then
		warn(`[Loader] Failed to load {module.Name}: {result}`)
		return
	end

	self._loaded[module.Name] = result
	if VERBOSE_LOADING then
		print(`[Loader] Loaded {module.Name}`)
	end
end

--[=[
	Runs one lifecycle method (Init or Start) on a loaded module, if it defines
	one, catching errors so a failure cannot halt the rest.
	@param module ModuleScript -- The module whose lifecycle method to run.
	@param methodName string -- "Init" or "Start".
	@return boolean -- True if safe to advance (no such method, or it succeeded).
]=]
function Loader:RunLifecycle(module: ModuleScript, methodName: string): boolean
	local instance = self._loaded[module.Name]
	if not instance or type(instance[methodName]) ~= "function" then
		return true
	end

	local success, err = xpcall(function()
		instance[methodName](instance)
	end, function(e)
		return `{e}\n{debug.traceback()}`
	end)

	if not success then
		warn(`[Loader] Failed to {methodName} {module.Name}: {err}`)
		return false
	end

	if VERBOSE_LOADING then
		print(`[Loader] {methodName} {module.Name}`)
	end
	return true
end

--[=[
	Client only: yields until the server has finished loading (signalled by the
	Workspace "ServerLoaded" attribute), so every server socket exists first.
	@return () -- No return value.
]=]
function Loader:_waitForServer()
	while not Workspace:GetAttribute(SERVER_LOADED_ATTRIBUTE) do
		Workspace:GetAttributeChangedSignal(SERVER_LOADED_ATTRIBUTE):Wait()
	end
end

--[=[
	Server only: records a player as ready, sets their "ClientLoaded" attribute,
	and runs every OnPlayerReady callback for them.
	@param player Player -- The player whose client has finished loading.
	@return () -- No return value.
]=]
function Loader:_markPlayerReady(player: Player)
	if self._readyPlayers[player] then
		return
	end
	self._readyPlayers[player] = true
	player:SetAttribute(CLIENT_READY_ATTRIBUTE, true)
	for _, callback in self._playerReadyCallbacks do
		task.spawn(callback, player)
	end
end

--[=[
	Server only: creates the client-ready remote and listens for clients signalling
	that they have finished loading and are safe to receive events.
	@return () -- No return value.
]=]
function Loader:_setupServerHandshake()
	local remote = Instance.new("RemoteEvent")
	remote.Name = CLIENT_READY_REMOTE
	remote.Parent = ReplicatedStorage

	remote.OnServerEvent:Connect(function(player: Player)
		self:_markPlayerReady(player)
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		self._readyPlayers[player] = nil
	end)
end

--[=[
	Client only: tells the server every listener is registered and the client is
	ready to receive events.
	@return () -- No return value.
]=]
function Loader:_signalClientReady()
	local remote = ReplicatedStorage:WaitForChild(CLIENT_READY_REMOTE)
	remote:FireServer()
end

--[=[
	Loads every module in the container, then Inits all of them, then Starts all of
	them. Load order is handled by require; Init/Start run in name order, which is
	safe as long as modules set state in Init and call other modules in Start.
	@param container Instance -- Folder of service/controller ModuleScripts.
	@return () -- No return value.
]=]
function Loader:Start(container: Instance)
	assert(not self._started, "[Loader] Already started the module loader")
	self._started = true

	-- Set up the handshake listener before announcing ServerLoaded, so a client
	-- can never fire "_ClientReady" before the server is listening.
	if IS_SERVER then
		self:_setupServerHandshake()
	else
		self:_waitForServer()
	end

	local modules = getModules(container)

	if VERBOSE_LOADING then
		warn("=== Loading Modules ===")
	end
	for _, module in modules do
		self:LoadModule(module)
	end

	if VERBOSE_LOADING then
		warn("=== Initializing Modules ===")
	end
	local initialized = {}
	for _, module in modules do
		if self._loaded[module.Name] and self:RunLifecycle(module, "Init") then
			table.insert(initialized, module)
		end
	end

	if VERBOSE_LOADING then
		warn("=== Starting Modules ===")
	end
	for _, module in initialized do
		self:RunLifecycle(module, "Start")
	end

	if VERBOSE_LOADING then
		warn("=== Loading Finished ===")
	end

	-- Server opens the gate for clients; client announces it is ready for events.
	if IS_SERVER then
		Workspace:SetAttribute(SERVER_LOADED_ATTRIBUTE, true)
	else
		self:_signalClientReady()
	end
end

--[=[
	Server only: returns whether a player's client has finished loading and can
	actually receive events. ServerSocket consults this before every send, so a send
	made before the client's listeners exist is dropped rather than lost mid-flight.
	@param player Player -- The player to check.
	@return boolean -- True once the player has signalled ready.
]=]
function Loader:IsPlayerReady(player: Player): boolean
	return self._readyPlayers[player] == true
end

--[=[
	Registers a callback run once for each player who has finished loading their
	client (fired immediately for players already ready). This is the hook game
	services use to gate participation on readiness (Option B).
	@param callback (player: Player) -> () -- Run per ready player.
	@return () -- No return value.
]=]
function Loader:OnPlayerReady(callback: (player: Player) -> ())
	for player in self._readyPlayers do
		task.spawn(callback, player)
	end
	table.insert(self._playerReadyCallbacks, callback)
end

return Loader
