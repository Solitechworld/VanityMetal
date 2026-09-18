# VanityMetal

A GPU vanity-address engine for the Mac, written from scratch in Swift and
Metal. Where [VanitySearch](https://github.com/JeanLucPons/VanitySearch) needs
CUDA and an NVIDIA card, VanityMetal runs the same class of search on Apple's
own GPU stack — Apple silicon (M-series) and the Intel Iris / AMD Radeon GPUs
found in T2 Macs.

**Standalone by design.** One `swift build`, one `.app`. No CUDA, no Homebrew,
no Python at runtime, no third-party Swift packages, no shell scripts to babysit.
The Metal kernels are embedded in the binary and compiled at launch.

![icon](Resources/icon-preview.png)

---

## Build

```bash
./build.sh            # produces VanityMetal.app
./build.sh --test     # run the test suite first
./build.sh --run      # build and launch
```

Requirements: **macOS 12 or newer** and the Xcode Command Line Tools
(`xcode-select --install`). That is the entire dependency list.

The script checks your toolchain, compiles in release mode, assembles the app
bundle, builds the icon with `iconutil` and applies an ad-hoc signature so
Gatekeeper does not nag. Drop the resulting `VanityMetal.app` anywhere.

---

## What it does

| | |
|---|---|
| **Bitcoin P2PKH** | `1…` — compressed and, optionally, uncompressed keys |
| **Bitcoin P2SH-P2WPKH** | `3…` |
| **Bitcoin Bech32 SegWit v0** | `bc1q…` (and `tb1q…` for testnet) |
| **Ethereum** | `0x…`, with EIP-55 checksummed output |

Type a prefix and the app works out which kind it is. Several prefixes can be
hunted at once, and the combined difficulty updates as you type.

Everything else lives in the control panel: GPU device picker, walker count,
CPU worker count, steps per dispatch, case sensitivity, uncompressed-key
search, thermal guard, stop-on-first-hit, auto-save, a live hashrate trace, a
probability meter, an on-demand benchmark, an on-demand GPU self-test, and a
backdrop you can dial down or switch off when you would rather spend the
cycles on the search.

---

## How the search works

Each GPU thread holds a point on secp256k1 and walks it forward through the key
space. Naively, generating the next public key means one modular inversion —
the single most expensive operation in the whole pipeline, roughly 270
multiplications.

Instead, every thread generates **129 public keys per step**: the centre point,
plus 64 on each side, obtained by adding ±1G … ±64G. Points at `+iG` and `-iG`
share the same *x* coordinate, so they share a denominator, and a Montgomery
batch inversion turns 65 inversions into one inversion and a chain of
multiplications. The 130th slot in the batch carries the jump to the next
centre, so the walk advances by exactly 129 keys with no extra inverse.

All of it runs on the GPU: 256-bit field arithmetic on eight 32-bit limbs
(chosen so the code behaves identically on Apple silicon and on the older Intel
and AMD GPUs in T2 Macs), the curve arithmetic, SHA-256, RIPEMD-160 and
Keccak-256. The CPU only wakes up for hits.

### The GPU is a filter, never an oracle

Every hit the GPU reports is re-derived on the CPU from the private key, the
address is rebuilt from scratch, and the prefix is string-compared before
anything reaches the screen. A numerical bug in the shader could cost
throughput; it cannot hand you a key that does not work.

On top of that, the shader carries known-answer tests for field addition, the
modular-inverse addition chain, SHA-256, RIPEMD-160 and Keccak-256. They run on
the GPU at launch, and if the GPU disagrees with the reference values the app
says so and falls back to the multi-core CPU engine automatically.

---

## Why the difficulty number looks different

Most vanity tools quote **58ⁿ** for an *n*-character Base58 prefix. That figure
is wrong, and usually pessimistic.

A Bitcoin address is Base58Check over a 25-byte payload, and Base58 digits do
not line up with the 160-bit hash. The consequence is that the leading
characters of an address are **not uniformly distributed** — about 97% of P2PKH
addresses have a second character drawn from only the first 24 Base58 digits.

VanityMetal converts a prefix into exact inclusive **ranges** over the 20-byte
hash — sometimes more than one, because an address can be 33 or 34 characters
long — and the GPU does a range comparison rather than a bit-mask test. So the
difficulty shown is the real one:

| prefix | naive 58ⁿ | actual |
|---|---|---|
| `1A` | 58 | **22.9** |
| `1Love` | 11,320,000 | **4,476,000** |
| `3Cy` | 3,364 | **1,354** |
| `bc1qne0n` | — | **1,048,576** (exactly 32⁴) |
| `0xdecaf` | — | **1,048,576** (exactly 16⁵) |

The bit-aligned formats come out as clean powers, which is a good sign the
range maths is right. The Base58 numbers were verified empirically against
400,000 random hashes; predicted and observed hit rates agree within Poisson
noise (`Tools/verify_targets.py`).

---

## Verification

The maths was not written and hoped for. Three independent layers check it:

1. **`Tools/verify_model.py`** re-implements the Metal kernel limb-for-limb in
   Python and checks it against Python's own big integers, `hashlib`, and
   published test vectors — including the batch-inversion walk, where all 387
   keys generated over three batches are confirmed to equal *k·G*.
2. **`Tools/verify_targets.py`** checks the prefix parser in both directions:
   every address falls inside the ranges built from its own prefix, and every
   hash inside a range really does produce that prefix.
3. **`swift test`** covers the shipping Swift: field arithmetic, the comb
   ladder against a plain double-and-add reference, hash vectors, known
   addresses and WIF for a fixed key, the target parser, and an end-to-end run
   of the CPU engine that confirms the walk covers a contiguous block of keys
   with no gaps and no repeats.

```bash
python3 Tools/verify_model.py
python3 Tools/verify_targets.py
swift test
```

---

## Layout

```
Package.swift                     SwiftPM manifest — no dependencies
build.sh                          builds VanityMetal.app
Kernels/VanityKernels.metal       the GPU source of truth
Sources/VanityMetalCore/
    Secp256k1.swift               U256, field & scalar arithmetic, curve, comb ladder
    Hashing.swift                 SHA-256 (CryptoKit), RIPEMD-160, Keccak-256
    Encoding.swift                Base58Check, Bech32, WIF, EIP-55
    AddressTarget.swift           prefix → exact hash ranges + true difficulty
    MetalEngine.swift             device management, buffers, dispatch, self-test
    CPUEngine.swift               same algorithm on CPU cores (fallback / quiet mode)
    SearchController.swift        run loop, verification, statistics
    Persistence.swift             crash-safe result storage and export
    MetalShaderSource.swift       generated — embeds the .metal file
Sources/VanityMetalApp/           SwiftUI interface
Tools/                            verification models, icon generator, embed script
Tests/                            swift test suite
```

Editing the kernel means editing `Kernels/VanityKernels.metal` and then running
`Tools/embed_kernels.sh` to regenerate the embedded copy.

---

## Tuning

- **Walkers** — leave on `AUTO` first. More walkers means more parallelism but
  more per-thread private memory; the sweet spot on Apple silicon is usually a
  few thousand.
- **Steps per dispatch** — `AUTO-TUNE` targets a quarter-second per dispatch,
  which keeps the interface responsive. Raise it manually for a few percent
  more throughput at the cost of a laggier UI.
- **Thermal guard** — on by default. On a fanless MacBook it eases off when the
  system reports thermal pressure, which is usually *faster* over an hour than
  letting the machine throttle itself.
- **Backdrop** — the animated background costs a little GPU. Turn it off in the
  Visuals card for a pure-search machine.

---

## Keeping the keys safe

Anything this app finds is a real private key.

- Found keys are written to `~/Library/Application Support/VanityMetal/` with
  owner-only (`0600`) permissions, the moment they are verified, so a crash
  cannot lose one.
- Private material is masked in the interface until you press **REVEAL**.
- Exports (text, CSV or JSON) are written `0600` too.
- Every start-up draws a fresh 256-bit random base key from the system CSPRNG,
  and each walker is spaced 2¹²⁸ keys apart, so two walkers can never collide
  and no run repeats a previous one.

A vanity address is exactly as secure as any other address **provided you
generated it yourself and control the key**. Never accept a vanity private key
from someone else, and never paste a private key into a website to "check" it.
Move funds to a newly generated vanity address only once you are satisfied with
how you are storing its key.

---

## Documentation

| | |
|---|---|
| `docs/01-ARCHITECTURE.md` | The modules, the dispatch loop, and why there are two engines |
| `docs/02-GPU-KERNEL.md` | The Metal kernel: limbs, batch inversion, buffer layout, editing it |
| `docs/03-ADDRESS-MATH.md` | Why 58ⁿ is wrong, what is computed instead, how that was checked |
| `docs/04-VERIFICATION.md` | The four layers, what each covers, and what CI cannot cover |
| `docs/05-SECURITY.md` | Key handling, the supply chain, and what this does *not* protect against |
| `docs/06-BUILD-AND-RUN.md` | Requirements, build, tuning, troubleshooting |
| `CONTRIBUTING.md` | The two rules, paired constants, adding an address kind |

---

## Licence

MIT — see `LICENSE`.

---

## Credit

The batch-inversion group-generation strategy is the one popularised by Jean-Luc
Pons' VanitySearch; the modular-inverse addition chain is the one from
libsecp256k1. Everything here — the Metal kernels, the Swift core, the range
based prefix maths and the interface — is an independent implementation.
