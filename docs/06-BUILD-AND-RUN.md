# Running and tuning

---

## Installing

Requirements, the install walkthrough, Gatekeeper, updating and a safe
uninstall all live in **`00-INSTALL.md`**. They are not repeated here — two
copies of an install guide drift apart, and the stale one is always the one
someone reads.

The short version:

```bash
xcode-select --install
./build.sh --test     # build + the 57-check suite
open VanityMetal.app
```

This document picks up from there: running it, tuning it, and what to do when
throughput is not what you expected.

---

## Running the verifiers directly

```bash
python3 Tools/verify_model.py      # kernel reference model, no GPU needed
python3 Tools/verify_targets.py    # prefix ranges, both directions
swift run -c release VanityMetalVerify
```

`./build.sh --test` tees the last one to `verify-log.txt` so a long run
survives terminal scrollback.

---

## Using it

Type a prefix. The app infers the kind:

| Type | Gets you |
|---|---|
| `1Love` | Bitcoin P2PKH |
| `3Cyber` | Bitcoin P2SH-P2WPKH |
| `bc1qne0n` | Bitcoin Bech32 SegWit v0 |
| `0xdecaf` | Ethereum, EIP-55 checksummed |

Several prefixes can run at once; the combined difficulty updates as you type.
Remember that difficulty is an expectation, not a schedule — see the caveat at
the end of `03-ADDRESS-MATH.md`.

---

## Tuning

**Walkers** — leave on `AUTO` first. More walkers means more parallelism but
more per-thread private memory, and past a point the GPU starts spilling.
A few thousand is usually the sweet spot on Apple silicon. The benchmark in the
control panel sweeps this for you.

Recorded on an AMD Radeon Pro 5500M, showing that more is not monotonically
better:

```
18.52 Mkey/s at 1024 walkers (2 steps/dispatch)
78.98 Mkey/s at 4096 walkers (3 steps/dispatch)
28.14 Mkey/s at 1536 walkers (5 steps/dispatch)
```

**Steps per dispatch** — `AUTO-TUNE` targets a short wall-clock window per
dispatch so the interface stays responsive. Raising it manually buys a few
percent throughput at the cost of a laggier UI, because the GPU cannot be
preempted mid-dispatch.

**Thermal guard** — on by default. On a fanless MacBook it eases off when the
system reports thermal pressure. Counter-intuitively this is usually *faster*
over an hour than letting the machine hit its own throttle, which is blunter.

**Backdrop** — the animated background costs GPU time that could be searching.
Turn it off in the Visuals card for a dedicated machine.

**Engine** — GPU by default, CPU as fallback or quiet mode. The CPU engine runs
the identical algorithm, just slower.

---

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `Swift not found` | `xcode-select --install` |
| `macOS 12 or newer is required` | the Metal features used are not in earlier releases |
| First launch pauses ~1 s | the Metal kernels compile at launch from embedded source; cached afterwards |
| `swift test` fails, CLT only | XCTest ships with full Xcode. Use `./build.sh --test` |
| App says the GPU self-test failed | the launch-time known-answer tests disagreed; it has fallen back to CPU. Please report it with your device name from `session.log` |
| No Metal device found | CPU engine only. Expected on a VM or a CI runner |
| Throughput lower than expected | turn the backdrop off, try `AUTO` walkers, check for thermal pressure |
| Edited the kernel, nothing changed | you skipped `Tools/embed_kernels.sh`. The app runs the embedded copy |

---

## Layout

```
Package.swift                     SwiftPM manifest — no dependencies
build.sh                          builds VanityMetal.app
Kernels/VanityKernels.metal       the GPU source of truth
Sources/VanityMetalCore/          the engine (see 01-ARCHITECTURE.md)
Sources/VanityMetalApp/           SwiftUI interface
Sources/VanityMetalVerify/        the 57-check suite, no XCTest needed
Tools/                            reference models, icon generator, embed script
Tests/                            XCTest suite
docs/                             this documentation
```

Files written outside the tree at runtime:

```
~/Library/Application Support/VanityMetal/found-keys.json   0600
~/Library/Application Support/VanityMetal/session.log
```
