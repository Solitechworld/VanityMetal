# Security and key handling

This program produces real Bitcoin and Ethereum private keys. This document
says exactly what it does with them, what it protects against, and what it
does not.

---

## Where keys come from

Every run draws a fresh **256-bit base key from the system CSPRNG**
(`SecRandomCopyBytes` / `getentropy`). Nothing is derived from the clock, the
prefix, the device, or a user-supplied seed.

Each walker is then placed **2¹²⁸ keys apart** from its neighbours. Two
consequences:

- No two walkers in a run can ever collide, however long it runs. A walker
  advances 129 keys per step; exhausting a 2¹²⁸ stride is not a thing that
  happens.
- No run repeats a previous run, because the base is fresh each time.

The search space is 2²⁵⁶. Scanning at 100 Mkey/s for a century covers about
2⁵⁸ of it. Reuse is not a practical concern; the spacing is there so it is not
a theoretical one either.

---

## Where keys go

| | |
|---|---|
| Directory | `~/Library/Application Support/VanityMetal/` — **outside the repository** |
| File | `found-keys.json` |
| Directory mode | `0700` (owner only) |
| File mode | `0600` (owner only) |
| When written | the moment a hit is verified, before it is displayed |
| Exports | text, CSV or JSON — also written `0600` |

Writing before displaying is deliberate: a crash or a power loss between
finding a key and saving it would lose it permanently, and there is no way to
find it again.

`.gitignore` carries patterns for `found-keys.json`, `*.wif` and `exports/`.
Those exist purely so a stray export dropped into the working copy cannot be
committed by accident — the default storage location is already outside the
tree.

---

## In the interface

- Private keys and WIF are **masked until you press REVEAL**.
- The session log (`session.log`) records device selection, throughput and hit
  counts. **It never records private material.**
- Auto-save can be turned off; the keys are then held only in memory for the
  session, which is a legitimate choice if you intend to copy one out
  immediately and want nothing on disk.

---

## The supply chain

`Package.swift` declares **zero dependencies**. The whole of it is this
repository plus Apple's SDK.

This is the single most important security property of the project and the main
reason it was built the way it was. A vanity generator is a natural target: a
malicious dependency that biases the RNG, or quietly exfiltrates a found key,
would be very hard to notice and very profitable. There is no third-party code
here to audit, because there is none.

The Metal kernels ship as source embedded in the binary and are compiled at
launch, so what runs on the GPU is what is in `Kernels/VanityKernels.metal` —
readable, diffable, and checked against a Python reference model in CI.

---

## What this protects against

- **A shader bug producing a wrong key.** Structurally impossible to reach the
  user: every hit is re-derived on the CPU from the private key and the address
  rebuilt from scratch before anything is shown or saved. See
  `04-VERIFICATION.md`.
- **A faulty or exotic GPU.** Known-answer tests run on the GPU at launch; a
  disagreement falls back to the CPU engine automatically.
- **Losing a key to a crash.** Written `0600` at the moment of verification.
- **Walker collisions or repeated runs.** Fresh CSPRNG base, 2¹²⁸ spacing.
- **Shoulder-surfing.** Masked until REVEAL.

## What this does **not** protect against

Stated plainly, because a security section that only lists wins is marketing.

- **A compromised machine.** Malware with your user privileges can read
  `~/Library/Application Support/VanityMetal/` exactly as you can. `0600` stops
  other users, not other processes running as you.
- **Backups and sync.** Application Support is included in Time Machine and may
  be synced by some tools. Your keys may exist in more places than you think.
- **Memory.** Keys live in process memory while the app runs and are not
  guaranteed to be wiped; macOS may page memory to encrypted swap.
- **Screen capture.** REVEAL puts a key on screen. Screen recorders, screen
  sharing and screenshot tools will happily capture it.
- **Physical access to an unlocked machine.** Nothing here is a substitute for
  disk encryption. Turn on FileVault.
- **You pasting a key somewhere.** No program can help with this one.

---

## Rules for using a vanity address

**A vanity address is exactly as secure as any other address — provided you
generated it yourself and control the key.** The vanity part is cosmetic; it
constrains the hash, not the key's entropy, which remains a full 256-bit random
draw.

Two rules follow, and both have cost people real money:

1. **Never accept a vanity private key from someone else.** Whoever generated
   it can spend from it, forever, whatever they promise. Services offering to
   "generate a vanity address for you" are handing you an address someone else
   can empty. There is a variant where they hand you a *split-key* contribution
   that is safe — but if you are not certain that is what is happening, assume
   it is not.
2. **Never paste a private key into a website to "check" it.** Every such site
   is either a phishing page or one bug away from being one.

And one piece of practical advice: move funds to a newly generated vanity
address only once you are satisfied with how you are storing its key. Generate
it, back it up, verify the backup restores, *then* send money. In that order.

---

## Reporting a problem

If you find a flaw that could produce an incorrect key, a biased key, or leak
key material, please report it privately to the repository owner rather than
opening a public issue.
