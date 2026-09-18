# Address maths: why the difficulty number is different

Most vanity tools quote **58ⁿ** for an *n*-character Base58 prefix. That figure
is wrong. This document explains why, what VanityMetal computes instead, and
how that claim was checked.

Implementation: `Sources/VanityMetalCore/AddressTarget.swift`.

---

## The mistake

58ⁿ assumes each Base58 character is an independent uniform draw from 58
symbols. For a Bitcoin address, neither half of that is true.

A P2PKH address is Base58Check over a **25-byte payload**: one version byte
(`0x00`), the 20-byte hash160, and a 4-byte checksum. Base58 encoding treats
that payload as one big integer and repeatedly divides by 58. Two consequences
follow, and both break the naive count:

**1. The characters do not align to the hash.** There is no "second character
field" in the hash to constrain. A prefix constrains a *numeric range* of the
whole 25-byte integer, which maps back onto a range of the 20-byte hash — not
onto a set of bits.

**2. The leading digits are not uniform.** With a fixed `0x00` version byte, the
payload integer has a bounded magnitude, so the encoding does not reach the top
of its digit space. In practice about **97% of P2PKH addresses have a second
character drawn from only the first 24 Base58 digits** — not 58. Addresses are
also 33 or 34 characters long depending on leading zero bytes, and the two
lengths behave differently.

So `1A…` is not 1-in-58. It is 1-in-22.9. The naive figure is pessimistic here,
and it is not pessimistic by a constant factor you could just divide out.

---

## What VanityMetal does instead

For a given prefix, it computes the **exact set of 20-byte hashes whose address
starts with that prefix**, expressed as one or more inclusive ranges:

```
lo ≤ hash160 ≤ hi
```

Sometimes more than one range, because a prefix can be satisfied by both a
33-character and a 34-character address, and those are different regions of the
hash space.

The GPU then does a range comparison rather than a mask test — see
`02-GPU-KERNEL.md`. And the difficulty falls out exactly:

```
difficulty = 2^160 / Σ (hi_i - lo_i + 1)
```

No sampling, no estimate. A count.

---

## The numbers

| prefix | naive 58ⁿ | actual | ratio |
|---|---|---|---|
| `1A` | 58 | **22.9** | 2.5× easier |
| `1Love` | 11,320,000 | **4,476,000** | 2.5× easier |
| `3Cy` | 3,364 | **1,354** | 2.5× easier |
| `bc1qne0n` | — | **1,048,576** | exactly 32⁴ |
| `0xdecaf` | — | **1,048,576** | exactly 16⁵ |

The last two rows are the tell. Bech32 is base 32 and bit-aligned; Ethereum is
hex and bit-aligned. For those, the range maths *must* produce an exact power,
and it does — 32⁴ and 16⁵ on the nose. If the range construction had an
off-by-one anywhere, those would come out slightly wrong and obviously so.
They are a free correctness oracle, which is why they are in the test suite.

---

## How the Base58 figures were checked

The bit-aligned cases prove the machinery. The Base58 cases need a different
argument, because there is no closed form to compare against.

`Tools/verify_targets.py` checks the parser in **both directions**:

- **Soundness** — take an address, build the ranges from its own prefix, assert
  the address's hash falls inside them. Run over 960 prefixes in the suite.
- **Completeness** — take a hash inside a range, encode it, assert the
  resulting address really does start with the prefix.

Both directions matter. Soundness alone would pass for a range that is far too
wide; completeness alone would pass for one that is far too narrow.

Then an empirical check: **400,000 random hashes** were encoded and counted.
Predicted and observed hit rates agree within Poisson noise. That does not
prove the ranges are exact, but combined with the two-directional check and the
exact powers on the bit-aligned formats, it is a strong argument.

---

## Supported prefix forms

| Kind | Form | Notes |
|---|---|---|
| P2PKH | `1…` | compressed by default; uncompressed keys optional |
| P2SH-P2WPKH | `3…` | |
| Bech32 SegWit v0 | `bc1q…`, `tb1q…` | base 32, case-insensitive by definition |
| Ethereum | `0x…` | EIP-55 checksummed on output |

The kind is inferred from the prefix. Rejections are deliberate and tested:

- a P2PKH prefix not starting with `1`
- a P2SH prefix starting with `1`
- non-Base58 characters (`0`, `O`, `I`, `l` are not in the alphabet)
- `1` alone is *accepted* and matches every P2PKH hash — difficulty 1

---

## Case sensitivity

Case-sensitive by default for Base58, because that is what the user typed.
Turning it off widens the ranges — and the difficulty figure drops to match,
automatically, since it is derived from the same range set rather than
estimated separately.

Bech32 has no case to be sensitive about: the encoding is defined over a
single-case alphabet, so the option has no effect there.

---

## A caveat worth stating

Difficulty is the expected number of keys per hit, not a schedule. Search is a
Poisson process: at difficulty *D* you have about a 63% chance of a hit after
*D* keys, and a 1-in-*e* chance of still having nothing. The probability meter
in the interface shows the cumulative curve rather than an ETA, because an ETA
would be a lie dressed as a number.
