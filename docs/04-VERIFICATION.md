# Verification

A vanity generator that produces a key which does not control its address is
worse than useless — it loses money silently. So correctness here is not
asserted, it is checked, at four independent layers.

---

## Layer 0: the GPU is a filter, never an oracle

This is the structural guarantee, and it holds even if every other layer
missed something.

Every hit the GPU reports is **re-derived from scratch on the CPU**:

1. Reconstruct the private key from `threadId`, `iteration` and `offset`
2. Compute *k·G* with the Swift comb ladder — independent code from the shader
3. Hash and encode the address from that point
4. String-compare against the prefix the user typed

Only then does a result reach the screen or the disk. A numerical bug in the
shader can cost throughput or cause missed hits; **it cannot hand you a key
that does not work.**

---

## Layer 1: reference models in Python

Stdlib only. No GPU, no Swift, no macOS — they run anywhere, including CI.

### `Tools/verify_model.py`

Re-implements the Metal kernel **limb for limb** in Python and checks it
against Python's arbitrary-precision integers, `hashlib`, and published test
vectors. Because it mirrors the limb layout rather than using big integers
directly, it catches carry and reduction bugs that a high-level model would
paper over.

Covers field arithmetic, the inverse addition chain, curve operations, the
batch-inversion walk — including the assertion that all **387 keys generated
over three batches** equal *k·G* for the expected *k* — and the hashes.

### `Tools/verify_targets.py`

Checks the prefix parser in both directions, plus the empirical 400,000-hash
sample. See `03-ADDRESS-MATH.md`.

```bash
python3 Tools/verify_model.py
python3 Tools/verify_targets.py
```

---

## Layer 2: `VanityMetalVerify`

The main suite — **57 checks** — and the only layer that exercises the real
GPU. It is a plain executable rather than an XCTest bundle because XCTest ships
with full Xcode, not the Command Line Tools.

```bash
./build.sh --test               # builds it and tees to verify-log.txt
# or
swift run -c release VanityMetalVerify
```

What it covers:

| Group | Examples |
|---|---|
| Field arithmetic | `(p-1)+2 == 1`, `(p-1)² == 1`, inverse round trip, 2,000 random elements satisfying `(a+b)(a-b) == a²-b²` and `a·a⁻¹ == 1` |
| Curve | generator satisfies *y² = x³ + 7*; comb ladder matches plain double-and-add; G table holds 1G…64G; jump point is 129G |
| Hashes | SHA-256, RIPEMD-160 and Keccak-256 against published vectors |
| Addresses | P2PKH, P2PKH-uncompressed, P2SH, Bech32, ETH and both WIF forms for one fixed key; Base58Check round trip; corrupted checksum rejected |
| Prefix targets | 960 prefixes; the exact-power checks; every rejection case |
| CPU engine | 3 batches produce exactly 387 keys; the walk is contiguous with no gaps or repeats; reported hashes match keys re-derived from scratch |
| GPU kernel | see below |

### The GPU cross-check

The part worth the effort. Both engines run **from the same seed**, and the
suite asserts they report *identical* hits — not similar counts, the same set:

```
batch 0 — GPU and CPU report identical hits    GPU 122, CPU 122, shared 122
batch 1 — GPU and CPU report identical hits    GPU 112, CPU 112, shared 112
        256 walkers × 2 steps = 66048 keys on each engine
```

It also confirms the constants survived the trip to the GPU (`vanity_dump`
reads back 1·G, 64·G and the 129·G jump point), that the walk advances by
exactly 129 keys, that every offset in a batch maps to the right key, and that
GPU hits re-derive to the right private keys.

A recorded run on an AMD Radeon Pro 5500M: **ALL 57 CHECKS PASSED**.

---

## Layer 3: `swift test`

The XCTest suite, `Tests/VanityMetalCoreTests`. Needs full Xcode.

```bash
./build.sh --xctest
```

It covers the same shipping Swift as layer 2 and exists mainly so the project
is a good citizen in an Xcode workflow. If you only have the Command Line
Tools, layer 2 is strictly better — same ground plus the GPU.

---

## The launch-time self-test

Separate from all of the above, and it runs on the user's machine every time.

`vanity_selftest` executes known-answer tests on the GPU at startup for field
addition, the modular-inverse addition chain, SHA-256, RIPEMD-160 and
Keccak-256. If the GPU disagrees with the reference values, the app **says so
and falls back to the CPU engine automatically** rather than searching with
arithmetic it cannot trust.

This is not paranoia about Apple's drivers so much as about the long tail:
older T2 Macs, external GPUs, and whatever Metal does under memory pressure.

---

## What CI can and cannot cover

`.github/workflows/ci.yml` runs the Python models and the embedded-kernel sync
check on Linux, and builds plus runs `VanityMetalVerify` on macOS.

The macOS runner **does** expose a Metal device — an *Apple Paravirtual device*
— so CI runs the full suite, GPU cross-check included:

```
device: Apple Paravirtual device
PASS  batch 0 — GPU and CPU report identical hits   GPU 122, CPU 122, shared 122
PASS  GPU hits re-derive to the right private keys
      throughput:  55.27 Mkey/s at 4096 walkers
ALL 57 CHECKS PASSED
```

That is better coverage than you might expect, but note precisely what it is
and is not:

- **Covered:** the shader is correct on a paravirtualised Apple GPU, and agrees
  with the CPU engine hit-for-hit.
- **Not covered:** the **Intel Iris and AMD Radeon GPUs in T2 Macs.** That path
  is the entire reason the kernel uses eight 32-bit limbs instead of four
  64-bit ones (see `02-GPU-KERNEL.md`), and no CI runner exercises it.

So: **run `./build.sh --test` on a T2 Mac before a release** if you intend to
support one. A recorded run on an AMD Radeon Pro 5500M passed all 57. Nothing
in CI will tell you if that stops being true.

If a machine genuinely has no Metal device, the binary prints `no Metal device
found — GPU checks skipped` and exits 0 rather than failing.
