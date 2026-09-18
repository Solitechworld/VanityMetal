# Installation

There is no prebuilt download. You build it from source, which takes one
command and a few minutes. That is deliberate for a program that generates
private keys: a binary someone else compiled is a binary you are trusting
blindly.

---

## Requirements

| | Needed for | Notes |
|---|---|---|
| **macOS 12 (Monterey) or newer** | everything | `build.sh` refuses to run on anything older and tells you so |
| **Xcode Command Line Tools** | building | Provides `swift`, `clang`, `codesign`, `iconutil`. ~2 GB |
| **Swift 5.7 or newer** | building | `Package.swift` declares `swift-tools-version:5.7`. Ships with Command Line Tools 14+ / Xcode 14+ |
| **~600 MB free disk** | building | `.build` reaches about 578 MB. The finished app is 3 MB |
| **A Metal-capable GPU** | the fast path | Optional. Without one the CPU engine runs anyway |
| **Full Xcode** | `swift test` only | **Not required.** `./build.sh --test` covers the same ground without it |
| **Python 3** | `Tools/` verifiers only | Ships with the Command Line Tools. Not needed to build or run the app |

**No Homebrew. No CUDA. No package manager. No Swift dependencies.** The whole
supply chain is this repository plus Apple's SDK — see the supply-chain section
of `05-SECURITY.md` for why that is a security property and not just tidiness.

### Hardware

| | |
|---|---|
| Apple silicon (M-series) | Unified memory path. The fast case |
| Intel Mac with T2 | Supported — Intel Iris and AMD Radeon GPUs both work |
| Intel Mac without a Metal GPU | CPU engine only, which still works |

The kernel uses eight 32-bit limbs rather than four 64-bit ones specifically so
the older Intel and AMD GPUs behave identically to Apple silicon. See
`02-GPU-KERNEL.md`.

---

## 1. Check what you already have

```bash
sw_vers -productVersion      # want 12.0 or higher
swift --version              # want 5.7 or higher
```

If `swift` prints a version, you already have the Command Line Tools and can
skip to step 3.

---

## 2. Install the Xcode Command Line Tools

```bash
xcode-select --install
```

A dialog appears; accept it and wait. This is around a 2 GB download and takes
a few minutes on a decent connection.

**If you already have full Xcode installed**, you have everything — but make
sure the command line points at it:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
swift --version
```

A common failure is having Xcode installed while `xcode-select` still points at
a stale or missing toolchain. The symptom is `swift` not being found, or a
version older than 5.7.

---

## 3. Get the source

```bash
git clone https://github.com/Solitechworld/VanityMetal.git
cd VanityMetal
```

---

## 4. Build

```bash
./build.sh
```

That checks your toolchain, compiles in release mode, assembles
`VanityMetal.app`, builds the icon with `iconutil`, and applies an ad-hoc
signature.

Expect **2–5 minutes** on a first build. Subsequent builds are much faster
because SwiftPM caches everything under `.build`.

Useful variants:

```bash
./build.sh --test     # run the 57-check verification suite first (recommended)
./build.sh --run      # build, then launch
./build.sh --xctest   # also run the XCTest suite (needs full Xcode)
./build.sh --clean    # remove .build and the app bundle
./build.sh --help     # the same list
```

**Run `./build.sh --test` at least once.** It takes a couple of minutes and it
confirms the curve arithmetic, the hashes, the address encoders and — if you
have a GPU — that the shader agrees with the CPU engine hit for hit. On a
program that produces private keys, that is worth two minutes.

---

## 5. First launch

```bash
open VanityMetal.app
```

Or move it wherever you keep applications:

```bash
mv VanityMetal.app /Applications/
```

### The first launch is slow, and that is normal

The Metal kernels are compiled from embedded source at launch, not shipped
precompiled. Measured times:

```
Apple Paravirtual device      kernels compiled in  5.39s
AMD Radeon Pro 5500M          kernels compiled in 23.35s
```

So on a T2 Mac the first launch can sit for **twenty-odd seconds** before the
window becomes responsive. It is compiling, not hung. The result is cached, so
later launches are immediate.

### If macOS refuses to open it

`build.sh` ad-hoc signs the bundle and clears the quarantine attribute, so a
build you made yourself should just open. If you obtained the `.app` some other
way — a zip from a browser, an AirDrop — macOS will quarantine it:

**Right-click the app → Open → Open.** Once per app.

If it still refuses:

```bash
xattr -dr com.apple.quarantine /Applications/VanityMetal.app
codesign --force --sign - /Applications/VanityMetal.app
```

**Do not disable Gatekeeper system-wide** (`spctl --master-disable`) to run
this or anything else. It weakens every app on the machine to fix one, and
this app does not need it.

Note that ad-hoc signing is not notarisation. Distributing the app to other
people properly would need a Developer ID and a notarisation run; for your own
machine it is enough.

---

## 6. Verify it yourself (optional, recommended)

```bash
python3 Tools/verify_model.py      # kernel reference model, no GPU needed
python3 Tools/verify_targets.py    # prefix range maths, both directions
```

Stdlib only — no `pip install`. See `04-VERIFICATION.md` for what each layer
proves.

---

## 7. Updating

```bash
git pull
./build.sh
```

If you have edited `Kernels/VanityKernels.metal`, run `Tools/embed_kernels.sh`
before building or you will keep running the previous shader.

---

## 8. Uninstalling — read this first

The app itself is one bundle; delete it and it is gone.

```bash
rm -rf /Applications/VanityMetal.app
```

**Your found keys are stored elsewhere, and they are real private keys.**

```
~/Library/Application Support/VanityMetal/found-keys.json
~/Library/Application Support/VanityMetal/session.log
```

Deleting that directory destroys every key you have found, permanently and
with no way to recover them. If any of those addresses hold funds, or might
ever, **export or back them up before you delete anything**:

```bash
open ~/Library/Application\ Support/VanityMetal/
```

Only once you are certain:

```bash
rm -rf ~/Library/Application\ Support/VanityMetal/
```

---

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `Swift not found` | `xcode-select --install` |
| `swift` is older than 5.7 | Update the Command Line Tools, or `sudo xcode-select -s` at a current Xcode |
| `VanityMetal builds on macOS only` | It is a Metal and AppKit program; there is no Linux or Windows path |
| `macOS 12 (Monterey) or newer is required` | The Metal features used are not present in earlier releases |
| `swift test` fails, only CLT installed | XCTest ships with full Xcode. Use `./build.sh --test` |
| Build fails, out of disk | `.build` needs ~578 MB. `./build.sh --clean` frees it |
| Window unresponsive for ~20 s on first launch | Kernels compiling. Expected, especially on T2 Macs. Cached afterwards |
| "App is damaged" or won't open | Quarantine. Right-click → Open, or the `xattr` command in section 5 |
| GPU self-test failed, fell back to CPU | The launch-time known-answer tests disagreed. Please report it with your device name from `session.log` |
| No Metal device found | CPU engine only. Expected in a VM |
| Edited the kernel, nothing changed | You skipped `Tools/embed_kernels.sh` |

More on tuning and day-to-day use: `06-BUILD-AND-RUN.md`.
