# The GPU kernel

`Kernels/VanityKernels.metal`, ~900 lines. This is the source of truth; the
Swift copy in `MetalShaderSource.swift` is generated from it.

---

## The problem

Generating the next public key from the current one costs a modular inversion.
On secp256k1 that is the most expensive operation in the pipeline by a wide
margin — roughly 270 field multiplications through the addition chain. Do it
once per key and the inversion *is* your throughput.

## The trick

Every thread generates **129 public keys per step** and pays for **one**
inversion.

Hold a centre point *P*. The batch is:

```
P-64G, P-63G, … , P-1G, P, P+1G, … , P+63G, P+64G      129 points
```

Two things make this cheap:

1. **±iG share a denominator.** The points at *P+iG* and *P−iG* have the same
   *x* coordinate for the denominator term, so 129 points need only 65
   distinct inversions, not 129.
2. **Montgomery batch inversion** turns those 65 inversions into **one**
   inversion plus a chain of multiplications. Multiply all denominators
   together, invert the product once, then walk backwards multiplying out.

The 130th slot in the inversion batch carries the jump `P → P + 129G`, so the
walk advances to the next centre with no extra inverse. A thread therefore
covers a contiguous block of 129 keys per step, and blocks are contiguous with
each other: no gaps, no repeats. The verification suite asserts exactly that.

```
step 0:  [k-64 … k … k+64]     centre k
step 1:  [k+65 … k+129 … k+193]  centre k+129
step 2:  [k+194 … k+258 … k+322] centre k+258
```

---

## Field arithmetic

*p* = 2²⁵⁶ − 2³² − 977, held as `struct FE { uint d[8]; }` — eight 32-bit
limbs, least-significant first.

```
constant uint P_LIMBS[8] = {
    0xFFFFFC2F, 0xFFFFFFFE, 0xFFFFFFFF, 0xFFFFFFFF,
    0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF
};
```

**Why 32-bit limbs on a 64-bit GPU?** Portability beats elegance here. Apple
silicon handles 64-bit integers natively; the Intel Iris and AMD Radeon GPUs in
T2 Macs emulate them, slowly and with enough behavioural difference to make a
shader that is correct on one wrong on the other. Eight 32-bit limbs behave
identically on every Metal device Apple has shipped.

Reduction exploits the shape of *p*: the folded high word is multiplied by
2³² + 977 rather than divided, which is a multiply-and-add rather than a
division.

Inversion uses the addition chain from libsecp256k1 — a fixed sequence of
squarings and multiplications computing *a*^(p−2), with no data-dependent
branching.

---

## Kernels

| Entry point | Purpose |
|---|---|
| `vanity_search` | the walk. One thread = one walker |
| `vanity_dump` | reads back the generator table and jump point so the host can assert the GPU received *1G … 64G* and *129G* correctly |
| `vanity_selftest` | known-answer tests for field add, the inverse chain, SHA-256, RIPEMD-160 and Keccak-256, run at launch |

`vanity_dump` exists because "the constants uploaded correctly" is exactly the
kind of assumption that fails silently and produces a search that can never
hit. It is cheap to check and expensive not to.

---

## Buffer layout

Three structs cross the boundary. Their Swift-side word counts live in
`KernelConstants` and **must** match:

```c
struct VMParams {              // 8 words
    uint targetCount;
    uint hashPaths;            // bit flags: which hash pipelines to run
    uint batchIterations;
    uint maxResults;
    uint threadCount;
    uint iterationBase;
    uint _r0, _r1;
};

struct VMTarget {              // 12 words
    uint lo[5];                // inclusive low bound, big-endian 32-bit words
    uint hi[5];                // inclusive high bound
    uint kind;
    uint _pad;
};

struct VMResult {              // 16 words
    uint threadId;
    int  offset;               // -64 … +64 within the group
    uint iteration;
    uint targetIndex;
    uint kind;
    uint parity;               // 0 = even Y, 1 = odd Y
    uint h[5];
    uint _pad[5];
};
```

`offset` and `iteration` are what let the host reconstruct the exact private
key: `k = startKey + walkerStride·threadId + 129·iteration + offset`. The GPU
never sends a private key back — it sends coordinates into the walk.

`parity` carries the sign of *Y* so the host can rebuild the compressed public
key without recomputing the point.

---

## Hash paths

Selected by bit flag so a search for only `bc1q…` does not pay for Keccak:

| Flag | Path |
|---|---|
| `1 << 0` | compressed pubkey → SHA-256 → RIPEMD-160 (P2PKH and Bech32 share this) |
| `1 << 1` | uncompressed pubkey → SHA-256 → RIPEMD-160 |
| `1 << 2` | P2SH-P2WPKH: hash160 → witness script → SHA-256 → RIPEMD-160 |
| `1 << 3` | Keccak-256 of the uncompressed pubkey, low 20 bytes (Ethereum) |

P2PKH and Bech32 are the same 20 bytes — they differ only in how the host
encodes them, so one hash serves both.

---

## The comparison

Each candidate hash is compared against every `VMTarget` as a **range**:
`lo ≤ h ≤ hi`, big-endian, word by word with early exit. Not a mask. The
reason is in `03-ADDRESS-MATH.md`, and it is the difference between a
difficulty figure that is right and one that is off by a factor of two or more.

---

## Editing the kernel

```bash
$EDITOR Kernels/VanityKernels.metal
Tools/embed_kernels.sh          # regenerate MetalShaderSource.swift
python3 Tools/verify_model.py   # reference model, no GPU needed
./build.sh --test               # full suite, including GPU vs CPU
```

Skipping step 2 leaves the app running the previous shader while the repository
shows the new one. CI fails the build if the two have drifted, which is the
only reliable way to catch it.

If you change `GRP_HALF`, change `KernelConstants.groupHalf` in
`MetalEngine.swift` in the same commit. They are two halves of one constant.
