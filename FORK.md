# Thaiban City fork of Blink

This is a maintained fork of [1Axen/blink](https://github.com/1Axen/blink) 0.18.x, the IDL compiler Thaiban City
uses for its networking (`JobManagerNetwork.blink`). Upstream's 0.18 line is in maintenance only: 0.18.9 on
2026-09-19 was its first release since April. Upstream's effort is going into the 1.0 rewrite, which uses a
different schema dialect. The server-DOS issue [#45](https://github.com/1Axen/blink/issues/45) is still open.
This fork exists to close that gap without changing the language or the wire format.

- **Personal fork.** Changes live only in this repository: no pull requests, issues or other requests go to
  upstream. `git fetch upstream` is used read-only, to pull in 0.18.x fixes.
- **Base:** `v0.18.9` (`86b04ef`), upstream `main`.
- **Schema language:** identical to 0.18.9. Any `.blink` file that compiles upstream compiles here.
- **Wire format:** identical to 0.18.9 unless a change is explicitly marked **[wire]** below. A wire-compatible
  change needs only the *server* module regenerated; clients built by upstream 0.18.9 keep working.

## Roadmap

The order comes from the measurements in `Thaiban-City/netbench/results/BlinkBlox-vs-Blink-2026-11-24.md`.

### Tier 1: inbound hardening (wire-compatible)
1. ✅ Cap the packet size, the number of events and the number of Instances per packet before decoding starts.
2. ✅ An array never pre-allocates more slots than there are bytes left in the packet. Reads past the end already throw, and now that's caught.
3. ✅ `pcall` around the receive loop, so a malformed event drops only the rest of its own packet and no error escapes into the remote's connection. An error inside a Sync listener is the game's error: it is re-raised on its own thread, and decoding continues with the next event. An unknown event index is a decode error, instead of reading on.
4. ✅ Per-player inbound byte budget (token bucket, 64-byte minimum cost per packet). ⏳ Per-event `Rate` is still to do (schema syntax).
5. ✅ `SetDropHandler` and `SetDecodeErrorHandler`. Without them, warnings print at most once a second per player and kind, with a count.

Measured (`Thaiban-City/netbench/results/raw-2026-11-25-fork-tier1.txt`):
- honest traffic decodes identically to stock, with no refusals and no measurable decode overhead;
- a crafted 1 MB packet costs 0.016 ms instead of 65 ms;
- 100 KB of one-entity events stops at 1,024 events instead of 11,111 listener calls.

### Tier 2: decode speed (wire-compatible)
6. Build each struct with a pre-shaped constructor (`{a = false, b = false, …}`) instead of `{}` followed by field writes. This is most of BlinkBlox's 2–5× struct-array decode win.

### Tier 3: optional **[wire]**
7. Bit-packed `boolean[]` (8 per byte).
8. Batched unreliable events.

### Not planned
Run framing, streams/stamps, converters. They add a lot of code for little gain in our game.

## Inbound options (server only, wire-compatible)

| Option | Default | What it does |
|---|---|---|
| `MaxPacketSize` | `262144` | Largest inbound packet in bytes. Larger packets are refused before decoding (`Oversized`). |
| `MaxEventsPerPacket` | `1024` | Events decoded from one packet. The rest are dropped (`Events`). |
| `MaxInstancesPerPacket` | `1024` | Instances one packet may carry (`Instances`). |
| `InboundBytesPerSecond` | `1048576` | Per-player byte budget. Each packet costs its size, at least 64 bytes (`Budget`). `0` turns it off. |
| `InboundBurst` | larger of the two above | The most budget a player can bank. Must be at least `MaxPacketSize` (error E3017). |

The defaults are deliberately generous: an honest client sends one batched packet per frame. Measure a game's
real per-player upload before tightening them in its schema. (Thaiban City's hasn't been measured yet.)

Server API added next to `StepReplication` (casing follows `option Casing`):

```luau
Net.SetDropHandler(function(Player, Reason, Count, Detail) end)    -- "Malformed" | "Oversized" | "Instances" | "Events" | "Budget"
Net.SetDecodeErrorHandler(function(Player, Channel, Message, Count) end)
```

Handlers run in their own thread, at most once a second per player and kind. `Count` is how many refusals the
call stands for. Nobody is kicked automatically.

## Credits and sources

- Upstream: Blink © 1Axen, MIT (`LICENSE`).
- Some ideas are re-implemented after [XopoIII/BlinkBlox](https://github.com/XopoIII/BlinkBlox) (MIT), measured
  in the netbench report above. Any code copied from it must carry its MIT notice in the file it lands in.

## Working on the fork

```bash
git fetch upstream            # 1Axen/blink
git merge upstream/main       # pull upstream 0.18.x fixes into main
```

- `main` is the fork's product branch. Changes land through feature branches and pull requests.
- Fork releases are tagged `v0.18.9-tb.N`.
- **Don't publish a GitHub Release yet.** `.github/workflows/release.yml` is upstream's, and it runs
  `pesde publish` under upstream's package name. Rework it before the first fork release.

### Toolchain
`rokit.toml` pins Lune 0.10.4 (runs the compiler CLI), StyLua, darklua (release bundles), Rojo and
run-in-roblox. Compile a schema with:

```bash
lune run src/CLI/init.luau path/to/schema.blink
```

The compiler is pure Luau, so it can also run inside Studio, the way the plugin does.

### Testing
Upstream's `test/` compiles the sample sources and needs a Roblox run. The regression suite for this fork is
the netbench harness (`Thaiban-City/netbench/harness/BB*.luau`):
- hostile-packet probes (`BBHostile.luau`)
- server decode replay
- wire bytes and send cost against stock 0.18.9

Every change in tiers 1–2 should leave the wire bytes byte-identical, and should improve or keep the hostile-probe numbers.
