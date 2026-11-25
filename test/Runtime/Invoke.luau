--> Fork: client calls that get answered, fail, or never get a reply.
--> lune run test/Runtime/Invoke.luau [path to a generated Client.luau]
--> Without a path it compiles test/Runtime/Invoke.blink (InvocationTimeout = 1) with this repository first.
local Mock = require("./Mock")
local process = require("@lune/process")
local task = require("@lune/task")

local Path = process.args[1]
if not Path then
	Mock.Compile(process.cwd, "test/Runtime/Invoke.blink")
	Path = "test/Runtime/out/Invoke/Client.luau"
end

local Failures = 0
local function Check(Label: string, Ok: boolean, Detail: string)
	print(`{Ok and "PASS" or "FAIL"} {Label}: {Detail}`)
	Failures += Ok and 0 or 1
end

local World = Mock.Load(Path, "Client")
local Net = World.Module

--> Starts a call on its own thread and returns its state table and the invocation id it was sent with.
local function Call(Value: number)
	local State = { Done = false, Ok = nil :: boolean?, Result = nil :: any }
	task.spawn(function()
		State.Ok, State.Result = pcall(Net.Ask.Invoke, Value)
		State.Done = true
	end)
	Net.StepReplication()
	local Sent = World.ToServer[#World.ToServer].Args[1]
	return State, buffer.readu8(Sent, 1) --> [index 0][invocation id][data]
end

--> 1. An answered call returns the server's value.
local Answered, Id = Call(7)
World.ServerSends(Mock.Bytes({ 0, Id, 1, 42 }))
Check(
	"answered call returns",
	Answered.Done and Answered.Ok == true and Answered.Result == 42,
	`done={Answered.Done} result={tostring(Answered.Result)}`
)

--> 2. A failure reply followed by another event in the same packet: the call fails and the event after it
--> must still be decoded. [0, id, 0] is the 3-byte failure reply; [1, 5] is Note(5).
local Notes = {}
Net.Note.On(function(Value)
	table.insert(Notes, Value)
end)
local Failing, FailId = Call(8)
World.ServerSends(Mock.Bytes({ 0, FailId, 0, 1, 5 }))
Check(
	"failure reply fails the call",
	Failing.Done and Failing.Ok == false,
	`done={Failing.Done} ok={tostring(Failing.Ok)}`
)
Check(
	"event after a failure reply is decoded",
	Notes[1] == 5,
	`Note received {#Notes > 0 and tostring(Notes[1]) or "nothing"}`
)

--> 3. A call that never gets a reply fails after the timeout instead of waiting forever.
local Lost, LostId = Call(9)
task.wait(1.3)
Check(
	"unanswered call times out",
	Lost.Done and Lost.Ok == false and string.find(tostring(Lost.Result), "1 second") ~= nil,
	`done={Lost.Done} error={tostring(Lost.Result)}`
)

--> 4. Its late reply is discarded, not delivered to anyone, and the next call still works.
World.ServerSends(Mock.Bytes({ 0, LostId, 1, 99, 1, 6 }))
Check(
	"late reply is discarded and decoding continues",
	Notes[2] == 6,
	`Note after the late reply: {tostring(Notes[2])}`
)
local Next, NextId = Call(10)
World.ServerSends(Mock.Bytes({ 0, NextId, 1, 11 }))
Check("next call after a timeout works", Next.Done and Next.Result == 11, `result={tostring(Next.Result)}`)

process.exit(Failures)
