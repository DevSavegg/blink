--!strict
--> Fork: a minimal stand-in for the Roblox services a generated module touches, so its runtime behaviour
--> can be tested in Lune. It covers Players, ReplicatedStorage, RunService, RemoteEvent and
--> UnreliableRemoteEvent: signals fire synchronously, and every remote send is logged instead of sent.
--> Not a Roblox emulator: Instance-typed schema fields, Vector3, CFrame and so on are not supported.

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local task = require("@lune/task")

export type Signal = {
	Connect: (self: Signal, (...any) -> ()) -> { Disconnect: () -> () },
	Fire: (self: Signal, ...any) -> (),
}

local function Signal(): Signal
	local Connections: { (...any) -> () } = {}
	local self = {} :: any
	function self:Connect(Callback)
		table.insert(Connections, Callback)
		return {
			Disconnect = function()
				local Index = table.find(Connections, Callback)
				if Index then
					table.remove(Connections, Index)
				end
			end,
		}
	end
	function self:Fire(...)
		for _, Callback in table.clone(Connections) do
			Callback(...)
		end
	end
	return self
end

local function Container(Name: string)
	local self = { Name = Name, Children = {} :: { [string]: any } }
	function self:FindFirstChild(ChildName: string)
		return self.Children[ChildName]
	end
	function self:WaitForChild(ChildName: string)
		local Child = self.Children[ChildName]
		assert(Child, `Mock WaitForChild: "{ChildName}" does not exist (the mock does not wait)`)
		return Child
	end
	return self
end

export type World = {
	Module: any,
	Players: { any },
	Warnings: { string },
	ToServer: { { Remote: string, Args: { any } } },
	ToClient: { { Remote: string, Player: any?, Args: { any } } },
	AddPlayer: (Name: string) -> any,
	RemovePlayer: (Player: any) -> (),
	ClientSends: (Player: any, Buffer: any, Instances: { any }?) -> (),
	ClientSendsUnreliable: (Player: any, Buffer: any, Instances: { any }?) -> (),
	ServerSends: (Buffer: any, Instances: { any }?) -> (),
	Heartbeat: () -> (),
}

export type Options = {
	Running: boolean?,
	MaxPlayers: number?,
	Scope: string?, --> RemoteScope of the module, to find its remotes
}

local Mock = {}

--> Loads a generated module as the given side would see it. Returns the module's table and the world
--> around it. A client module needs the server's remotes to exist, so they are created first.
function Mock.Load(Path: string, Context: "Server" | "Client", Options: Options?): World
	local Options = Options or {}
	local Running = if Options.Running == nil then true else Options.Running
	local Prefix = if Options.Scope then `{Options.Scope}_BLINK` else "BLINK"

	local World = {} :: any
	World.Players = {}
	World.Warnings = {}
	World.ToServer = {}
	World.ToClient = {}

	local ReplicatedStorage = Container("ReplicatedStorage")
	local Players = Container("Players") :: any
	Players.PlayerRemoving = Signal()
	Players.MaxPlayers = Options.MaxPlayers or 1
	function Players:GetPlayers()
		return table.clone(World.Players)
	end

	local Heartbeat = Signal()
	local RunService = {
		Heartbeat = Heartbeat,
		IsServer = function()
			return Context == "Server"
		end,
		IsClient = function()
			return Context == "Client"
		end,
		IsRunning = function()
			return Running
		end,
	}

	local function NewInstance(ClassName: string): any
		local State: { [string]: any } = {
			ClassName = ClassName,
			Name = ClassName,
			OnServerEvent = Signal(),
			OnClientEvent = Signal(),
		}
		local Proxy = {}
		local Methods = {
			IsA = function(_, Class: string)
				return Class == ClassName
			end,
			FireServer = function(_, ...)
				table.insert(World.ToServer, { Remote = State.Name, Args = table.pack(...) })
			end,
			FireClient = function(_, Player, ...)
				table.insert(World.ToClient, { Remote = State.Name, Player = Player, Args = table.pack(...) })
			end,
			FireAllClients = function(_, ...)
				table.insert(World.ToClient, { Remote = State.Name, Args = table.pack(...) })
			end,
		}
		return setmetatable(Proxy, {
			__index = function(_, Key)
				return if Methods[Key] ~= nil then Methods[Key] else State[Key]
			end,
			__newindex = function(_, Key, Value)
				State[Key] = Value
				if Key == "Parent" and Value and Value.Children then
					Value.Children[State.Name] = Proxy
				end
			end,
		})
	end

	if Context == "Client" then
		for _, Suffix in { { "_RELIABLE_REMOTE", "RemoteEvent" }, { "_UNRELIABLE_REMOTE", "UnreliableRemoteEvent" } } do
			local Remote = NewInstance(Suffix[2])
			Remote.Name = Prefix .. Suffix[1]
			Remote.Parent = ReplicatedStorage
		end
	end

	local Services = { Players = Players, ReplicatedStorage = ReplicatedStorage, RunService = RunService }
	local Game = {
		GetService = function(_, Name: string)
			return assert(Services[Name], `Mock has no service "{Name}"`)
		end,
	}

	local Environment = setmetatable({
		game = Game,
		Instance = { new = NewInstance },
		task = task,
		warn = function(...)
			local Parts = {}
			for Index = 1, select("#", ...) do
				table.insert(Parts, tostring((select(Index, ...))))
			end
			table.insert(World.Warnings, table.concat(Parts, " "))
		end,
	}, { __index = _G })

	local Chunk = luau.load(fs.readFile(Path), { debugName = Path, environment = Environment :: any })
	World.Module = Chunk()

	local function Remote(Suffix: string)
		return assert(ReplicatedStorage.Children[Prefix .. Suffix], `no remote {Prefix .. Suffix}`)
	end

	function World.AddPlayer(Name: string)
		local Player = { Name = Name, Parent = Players, UserId = #World.Players + 1 }
		table.insert(World.Players, Player)
		return Player
	end

	function World.RemovePlayer(Player)
		local Index = table.find(World.Players, Player)
		if Index then
			table.remove(World.Players, Index)
		end
		Player.Parent = nil
		Players.PlayerRemoving:Fire(Player)
	end

	function World.ClientSends(Player, Buffer, Instances)
		Remote("_RELIABLE_REMOTE").OnServerEvent:Fire(Player, Buffer, Instances or {})
	end

	function World.ClientSendsUnreliable(Player, Buffer, Instances)
		Remote("_UNRELIABLE_REMOTE").OnServerEvent:Fire(Player, Buffer, Instances or {})
	end

	function World.ServerSends(Buffer, Instances)
		Remote("_RELIABLE_REMOTE").OnClientEvent:Fire(Buffer, Instances or {})
	end

	function World.Heartbeat()
		Heartbeat:Fire(1 / 60)
	end

	return World
end

--> A buffer holding exactly these bytes.
function Mock.Bytes(Values: { number }): buffer
	local Buffer = buffer.create(#Values)
	for Index, Value in Values do
		buffer.writeu8(Buffer, Index - 1, Value)
	end
	return Buffer
end

--> Concatenates buffers, or one buffer repeated Count times.
function Mock.Repeat(Buffer: buffer, Count: number): buffer
	local Length = buffer.len(Buffer)
	local Result = buffer.create(Length * Count)
	for Index = 0, Count - 1 do
		buffer.copy(Result, Index * Length, Buffer)
	end
	return Result
end

--> Compiles a schema with this repository's compiler and returns the directory it was written to.
function Mock.Compile(Repository: string, Schema: string)
	local process = require("@lune/process")
	local Result = process.exec("lune", { "run", "src/CLI/init.luau", Schema, "-y", "-q" }, { cwd = Repository })
	assert(Result.ok, `compiling {Schema} failed:\n{Result.stderr}\n{Result.stdout}`)
end

return Mock
