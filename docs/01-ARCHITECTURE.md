# Architecture

What the pieces are, how a key gets from a GPU thread to the screen, and which
decisions were deliberate.

---

## The shape of it

```
                    ┌──────────────────────────────────────┐
   target text ───► │ AddressTarget                        │
   address/prefix   │   parse → exact inclusive hash ranges │
                    └──────────────┬───────────────────────┘
                                   │ [HashRange]
                                   ▼
   ┌───────────────────────────────────────────────────────┐
   │ SearchController          run loop · stats · policy    │
   └───────┬───────────────────────────────┬───────────────┘
           │ dispatch
           ▼
   ┌────────────────────┐
   │ MetalEngine        │
   │ range + stride walk│
   │ buffers, self-test │
   └────────┬───────────┘
            │ RawHit
            ▼
              ┌─────────────────────────────┐
              │ VERIFY on the CPU           │
              │  k → k·G → hash → address   │
              │  string-compare the prefix  │
              └──────────────┬──────────────┘
                             │ FoundKey
              ┌──────────────┴──────────────┐
              ▼                             ▼
      ┌───────────────┐            ┌────────────────┐
      │ Persistence   │            │ SwiftUI        │
      │ 0600, atomic  │            │ masked until   │
      │ written first │            │ REVEAL         │
      └───────────────┘            └────────────────┘
```

The important arrow is the one in the middle. **Nothing the GPU says is
trusted.** It reports candidates; the CPU decides whether they are real.

---

## Modules

### `VanityMetalCore` — the library

| File | Responsibility |
|---|---|
| `Secp256k1.swift` | `U256`, field and scalar arithmetic mod *p* and mod *n*, curve points, the comb ladder for *k·G* |
| `Hashing.swift` | SHA-256 (via CryptoKit), RIPEMD-160, Keccak-256 — the last two implemented here because Apple ships neither |
| `Encoding.swift` | Base58Check, Bech32, WIF, EIP-55 checksummed hex |
| `AddressTarget.swift` | prefix → `[HashRange]` + true difficulty. See `03-ADDRESS-MATH.md` |
| `MetalEngine.swift` | device enumeration, bounded strided key walk, buffer layout, dispatch sizing, kernel self-test |
| `MetalShaderSource.swift` | **generated.** The `.metal` file embedded as a Swift string |
| `CPUEngine.swift` | CPU reference engine used by the verification executable; not used for app searches |
| `SearchController.swift` | run loop, verification, statistics, thermal policy, logging |
| `Persistence.swift` | result store, session log, preferences |

### `VanityMetalApp` — the interface

SwiftUI. `ContentView` composes `ControlPanel`, `StatsPanel`, `ResultsPanel`
and `CyberBackground`; `Theme.swift` holds the palette and type scale. The
interface owns no search logic — it observes `SearchController`, which is an
`ObservableObject`.

### `VanityMetalVerify` — the check that needs no Xcode

A plain executable rather than an XCTest bundle, and that is deliberate:
XCTest ships with full Xcode, not with the Command Line Tools, and requiring a
multi-gigabyte download to check a 7,000-line project would be absurd. It
covers the same ground as `swift test` and adds the GPU-versus-CPU
cross-check, which XCTest cannot do portably.

---

## CPU verification

`CPUEngine` remains as an independent reference for the verification
executable. The application uses the GPU for searches and verifies each result
on the CPU before displaying or saving it.

---

## The dispatch loop

One iteration of the loop, per dispatch:

1. `SearchController` picks `batchIterations` — auto-tuned to keep a dispatch
   near a target wall-clock window (default 100 ms) so the interface stays
   responsive.
2. `MetalEngine` encodes `vanity_search` with `threadCount` threads.
3. GPU walkers partition the selected arithmetic progression. A candidate is
   `minimum + index × step`; the final dispatch masks indices beyond the
   inclusive maximum.
4. Hits are appended to a device buffer via an atomic counter, capped at
   `maxResults` per dispatch.
5. The CPU reads the result buffer, re-derives each hit from scratch, and
   discards anything that does not match.
6. Statistics update; the walk state stays on the GPU. Nothing is copied back
   except results.

The walk state never round-trips. That matters: at tens of millions of keys
per second, moving 129 points per thread per step across the bus would dominate
the runtime.

---

## Decisions worth knowing about

**Eight 32-bit limbs, not four 64-bit.** Apple silicon would be happy with
64-bit limbs. The Intel Iris and AMD GPUs in T2 Macs would not — their 64-bit
integer support is emulated and slow, and in places subtly different. Eight
32-bit limbs behave identically everywhere, which is worth more than the
arithmetic saved.

**The shader is embedded, not bundled.** `Tools/embed_kernels.sh` turns
`Kernels/VanityKernels.metal` into a Swift string constant, compiled at launch
with `makeLibrary(source:)`. One file to load, works identically under SwiftPM,
inside an `.app`, or dropped into an Xcode project. The cost is about a second
on first launch. **`Kernels/VanityKernels.metal` is the source of truth** —
edit it, then re-run the script. CI fails if the two drift.

**No dependencies.** Not asceticism: a vanity generator handles private keys,
and every dependency is another party who could ship a compromised release.
The entire supply chain is this repository plus Apple's SDK.

**Ranges, not bit-masks.** See `03-ADDRESS-MATH.md`. This is the one place
where the obvious implementation is quietly wrong.
