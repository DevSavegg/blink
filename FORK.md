# Thaiban City fork of Blink

This is a maintained fork of [1Axen/blink](https://github.com/1Axen/blink) 0.18.x, the IDL compiler Thaiban City
uses for its networking (`JobManagerNetwork.blink`). Upstream's 0.18 line is in maintenance only: 0.18.9 on
2026-09-19 was its first release since April. Upstream's effort is going into the 1.0 rewrite, which uses a
different schema dialect. The server-DOS issue [#45](https://github.com/1Axen/blink/issues/45) is still open.
This fork exists to close that gap without changing the language or the wire format.

- **Base:** `v0.18.9` (`86b04ef`), upstream `main`.
- **Schema language:** identical to 0.18.9. Any `.blink` file that compiles upstream compiles here.
- **Wire format:** identical to 0.18.9 unless a change is explicitly marked **[wire]** below. A wire-compatible
  change needs only the *server* module regenerated; clients built by upstream 0.18.9 keep working.

## Roadmap

The order comes from the measurements in `Thaiban-City/netbench/results/BlinkBlox-vs-Blink-2026-11-24.md`.

### Tier 1: inbound hardening (wire-compatible)
1. Cap the packet size and the number of events per packet before decoding starts (new options, with conservative defaults).
2. Check every length against the bytes left *before* the `table.create`, the read, or the allocation it pays for.
3. `pcall` around the receive loop, so a malformed event drops only the rest of its own packet and no error escapes into the remote's connection.
4. Per-player inbound byte budget, with optional per-event `Rate`.
5. Drop, decode-error and rate-limit handlers, plus warnings rate-limited per player, so a client can't flood the output.

### Tier 2: decode speed (wire-compatible)
6. Build each struct with a pre-shaped constructor (`{a = false, b = false, …}`) instead of `{}` followed by field writes. This is most of BlinkBlox's 2–5× struct-array decode win.

### Tier 3: optional **[wire]**
7. Bit-packed `boolean[]` (8 per byte).
8. Batched unreliable events.

### Not planned
Run framing, streams/stamps, converters. They add a lot of code for little gain in our game.

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
