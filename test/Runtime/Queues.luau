--> Fork: what the server keeps when a client floods events nobody listens to yet.
--> lune run test/Runtime/Queues.luau [path to a generated Server.luau]
--> Without a path it compiles test/Runtime/Queues.blink with this repository first.
local Mock = require("./Mock")
local process = require("@lune/process")

local Path = process.args[1]
if not Path then
	Mock.Compile(process.cwd, "test/Runtime/Queues.blink")
	Path = "test/Runtime/out/Queues/Server.luau"
end

local Failures = 0
local function Check(Label: string, Ok: boolean, Detail: string)
	print(`{Ok and "PASS" or "FAIL"} {Label}: {Detail}`)
	Failures += Ok and 0 or 1
end

local World = Mock.Load(Path, "Server", { MaxPlayers = 2 })
local Player = World.AddPlayer("Flooder")

--> 1. 2000 Ping events (index 0) before anything listens, 200 to a packet.
for Packet = 1, 10 do
	World.ClientSends(Player, Mock.Repeat(Mock.Bytes({ 0, Packet }), 200))
end
local Delivered = 0
World.Module.Ping.On(function()
	Delivered += 1
end)
Check(
	"event queue is capped",
	Delivered == 256,
	`{Delivered} of 2000 queued events delivered once a listener connected`
)
local PingWarnings = #World.Warnings
Check("event queue warnings are bounded", PingWarnings <= 3, `{PingWarnings} warnings`)

--> 2. 300 calls to Ask (index 1) with no listener: [1, invocation id, data]. The ones past the cap must be
--> answered with a failure, [1, id, 0], so the client does not wait for them.
local Calls = {}
for Call = 0, 299 do
	table.insert(Calls, Mock.Bytes({ 1, Call % 255, 5 }))
end
local Packet = buffer.create(3 * #Calls)
for Index, Call in Calls do
	buffer.copy(Packet, (Index - 1) * 3, Call)
end
World.ClientSends(Player, Packet)
World.Module.StepReplication()

local Failed = 0
for _, Sent in World.ToClient do
	local Buffer = Sent.Args[1]
	local Cursor = 0
	while Cursor + 3 <= buffer.len(Buffer) do
		if buffer.readu8(Buffer, Cursor) == 1 and buffer.readu8(Buffer, Cursor + 2) == 0 then
			Failed += 1
		end
		Cursor += 3
	end
end
Check("calls past the cap are refused", Failed == 44, `{Failed} of 300 calls answered with a failure right away`)

local Answered = 0
World.Module.Ask.On(function(_, Value)
	Answered += 1
	return Value
end)
Check("queued calls are answered once a listener connects", Answered == 256, `{Answered} queued calls answered`)

--> 3. 600 polled Feed events (index 2). The cap for polled events is per player slot: 256 x MaxPlayers (2).
World.ClientSends(Player, Mock.Repeat(Mock.Bytes({ 2, 9 }), 600))
local Polled = 0
for _ in World.Module.Feed.Iter() do
	Polled += 1
end
Check("polled queue is capped", Polled == 512, `{Polled} of 600 polled events kept`)

--> 4. Once drained, the polled queue accepts again.
World.ClientSends(Player, Mock.Repeat(Mock.Bytes({ 2, 9 }), 10))
Polled = 0
for _ in World.Module.Feed.Iter() do
	Polled += 1
end
Check("polled queue refills after draining", Polled == 10, `{Polled} of 10`)

print(`warnings printed: {#World.Warnings}`)
for Index = 1, math.min(#World.Warnings, 3) do
	print("  " .. string.sub(World.Warnings[Index], 1, 160))
end
process.exit(Failures)
