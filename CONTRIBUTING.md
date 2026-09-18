# Contributing

## Before you change anything

Two rules carry most of the weight here.

**1. The GPU is a filter, never an oracle.** Every hit is re-derived on the CPU
before it reaches the user. Do not "optimise" that away, and do not add a path
that reports a result the CPU has not confirmed. It is the reason a shader bug
here costs throughput rather than money.

**2. `Kernels/VanityKernels.metal` is the source of truth.**
`Sources/VanityMetalCore/MetalShaderSource.swift` is generated. Edit the
kernel, then run `Tools/embed_kernels.sh`. CI fails if the two have drifted —
otherwise you get an app running the old shader while the diff shows the new
one, which is a miserable afternoon.

## The loop

```bash
$EDITOR Kernels/VanityKernels.metal
Tools/embed_kernels.sh
python3 Tools/verify_model.py        # fast, no GPU
./build.sh --test                    # full 57 checks, needs a real GPU
```

## Paired constants

Change one, change the other in the same commit:

| | |
|---|---|
| `GRP_HALF` in the kernel | `KernelConstants.groupHalf` |
| `VMParams` / `VMTarget` / `VMResult` fields | `paramWords` / `targetWords` / `resultWords` |

These are two halves of one definition living in two languages. Nothing will
warn you.

## Adding an address kind

1. A case in `AddressKind`, with its `hashPath` bit flag and version byte
2. The hash path in the kernel, behind that flag
3. Range construction in `AddressTarget.swift`
4. Encoding in `Encoding.swift`
5. Tests in **both** `Tools/verify_targets.py` and `VanityMetalVerify`

For step 5, the strongest check available is the one used for Bech32 and
Ethereum: if the format is bit-aligned, assert the difficulty comes out as an
exact power. An off-by-one in the range maths shows up immediately.

## Dependencies

`Package.swift` declares none, and that is a design decision rather than an
oversight — see the supply-chain section of `docs/05-SECURITY.md`. A pull
request adding a dependency needs to argue the case first.

## Style

Follow what is there. Comments explain *why*, particularly where the obvious
implementation is wrong — the 32-bit limbs, the range comparison, the CPU
re-derivation. Those comments are load-bearing; please keep them current rather
than deleting them when you touch the code beneath.

## Security issues

If you find something that could produce an incorrect key, a biased key, or
leak key material, report it privately to the repository owner rather than
opening a public issue.
