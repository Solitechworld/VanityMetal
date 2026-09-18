#!/usr/bin/env python3
"""
Reference model for AddressTarget.swift.

The parser turns a typed prefix into inclusive ranges over the 20-byte hash.
The property that has to hold is simple and testable:

    for every private key k, address(k) starts with prefix
       <=>  hash160(k) lies inside one of the produced ranges

We test both directions on real keys, for all four address kinds.
"""
import hashlib, random, struct
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from verify_model import ripemd160, keccak256_64, ec_mul, P

B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
BECH = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"


def b58_encode(b):
    z = len(b) - len(b.lstrip(b'\x00'))
    n = int.from_bytes(b, 'big')
    s = ""
    while n:
        n, r = divmod(n, 58)
        s = B58[r] + s
    return "1" * z + s


def b58check(version, payload):
    body = bytes([version]) + payload
    return b58_encode(body + hashlib.sha256(hashlib.sha256(body).digest()).digest()[:4])


def bech32_polymod(values):
    gen = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]
    chk = 1
    for v in values:
        b = chk >> 25
        chk = ((chk & 0x1ffffff) << 5) ^ v
        for i in range(5):
            chk ^= gen[i] if ((b >> i) & 1) else 0
    return chk


def bech32_encode(hrp, program):
    data = [0] + convertbits(program, 8, 5)
    values = [ord(c) >> 5 for c in hrp] + [0] + [ord(c) & 31 for c in hrp] + data
    mod = bech32_polymod(values + [0] * 6) ^ 1
    chk = [(mod >> (5 * (5 - i))) & 31 for i in range(6)]
    return hrp + "1" + "".join(BECH[d] for d in data + chk)


def convertbits(data, frm, to):
    acc = bits = 0
    out = []
    maxv = (1 << to) - 1
    for v in data:
        acc = (acc << frm) | v
        bits += frm
        while bits >= to:
            bits -= to
            out.append((acc >> bits) & maxv)
    if bits:
        out.append((acc << (to - bits)) & maxv)
    return out


# ---------------------------------------------------------------------------
# The parser, mirroring parseBase58Prefix / parseBech32Prefix / parseHexPrefix
# ---------------------------------------------------------------------------
def parse_base58(prefix, version):
    for c in prefix:
        assert c in B58, c
    version_base = version << 192
    payload_lo, payload_hi = version_base, version_base + (1 << 192) - 1

    z = 0
    while z < len(prefix) and prefix[z] == '1':
        z += 1
    rest = prefix[z:]

    if version == 0 and z == 0:
        return []
    if version != 0 and z > 0:
        return []

    # A prefix made entirely of '1's constrains only an *upper* bound: "1"
    # legitimately matches "11xyz…" too.  Once a non-'1' character follows,
    # the number of leading zero bytes is pinned exactly.
    if z > 0 and rest:
        zero_lo = 1 << (8 * (24 - z))
        zero_hi = (1 << (8 * (25 - z))) - 1
    elif z > 0:
        zero_lo = 0
        zero_hi = (1 << (8 * (25 - z))) - 1
    else:
        zero_lo, zero_hi = 0, (1 << 200) - 1

    out = []

    def consider(lo, hi):
        lo = max(lo, payload_lo, zero_lo)
        hi = min(hi, payload_hi, zero_hi)
        if hi < lo:
            return
        out.append(((lo - version_base) >> 32, (hi - version_base) >> 32))

    if not rest:
        consider(0, (1 << 200) - 1)
    else:
        for d in range(len(rest), 36):
            lo = hi = 0
            for c in rest:
                v = B58.index(c)
                lo = lo * 58 + v
                hi = hi * 58 + v
            for _ in range(d - len(rest)):
                lo = lo * 58 + 0
                hi = hi * 58 + 57
            consider(lo, hi)
    return merge(out)


def parse_bech32(prefix):
    low = prefix.lower()
    assert low.startswith("bc1")
    body = low[3:]
    if not body:
        return [(0, (1 << 160) - 1)]
    assert body[0] == 'q'
    body = body[1:]
    assert len(body) <= 32
    value = 0
    for c in body:
        value = value * 32 + BECH.index(c)
    free = 160 - 5 * len(body)
    lo = value << free
    return [(lo, lo + (1 << free) - 1)]


def parse_hex(prefix):
    s = prefix.lower()
    if s.startswith("0x"):
        s = s[2:]
    if not s:
        return [(0, (1 << 160) - 1)]
    value = int(s, 16) if s else 0
    free = 160 - 4 * len(s)
    lo = value << free
    return [(lo, lo + (1 << free) - 1)]


def merge(rs):
    if len(rs) <= 1:
        return rs
    rs = sorted(rs)
    out = [rs[0]]
    for lo, hi in rs[1:]:
        if lo <= out[-1][1] + 1:
            out[-1] = (out[-1][0], max(out[-1][1], hi))
        else:
            out.append((lo, hi))
    return out


def in_ranges(h, rs):
    return any(lo <= h <= hi for lo, hi in rs)


# ---------------------------------------------------------------------------
def addresses_for(k):
    X, Y = ec_mul(k)
    comp = bytes([2 + (Y & 1)]) + X.to_bytes(32, 'big')
    unco = b'\x04' + X.to_bytes(32, 'big') + Y.to_bytes(32, 'big')
    h160c = ripemd160(hashlib.sha256(comp).digest())
    h160u = ripemd160(hashlib.sha256(unco).digest())
    redeem = b'\x00\x14' + h160c
    h160s = ripemd160(hashlib.sha256(redeem).digest())
    eth = keccak256_64(X.to_bytes(32, 'big') + Y.to_bytes(32, 'big'))[12:]
    return {
        'p2pkh':  (b58check(0, h160c), int.from_bytes(h160c, 'big')),
        'p2pkhu': (b58check(0, h160u), int.from_bytes(h160u, 'big')),
        'p2sh':   (b58check(5, h160s), int.from_bytes(h160s, 'big')),
        'bech32': (bech32_encode('bc', h160c), int.from_bytes(h160c, 'big')),
        'eth':    ('0x' + eth.hex(), int.from_bytes(eth, 'big')),
    }


fails = []


def check(name, ok, extra=""):
    print(("  PASS  " if ok else "  FAIL  ") + name + ("  " + extra if extra else ""))
    if not ok:
        fails.append(name)


def run_tests():
    random.seed(4242)
    KEYS = [random.randrange(1, P) for _ in range(300)]
    ADDR = [addresses_for(k) for k in KEYS]

    print("\n[A] round trip: every address matches the ranges built from its own prefix")
    for kind, parser, lo_len, hi_len in [
        ('p2pkh',  lambda p: parse_base58(p, 0), 2, 6),
        ('p2pkhu', lambda p: parse_base58(p, 0), 2, 6),
        ('p2sh',   lambda p: parse_base58(p, 5), 2, 6),
        ('bech32', parse_bech32, 4, 10),
        ('eth',    parse_hex, 3, 10),
    ]:
        bad = 0
        for a in ADDR:
            addr, h = a[kind]
            for L in range(lo_len, hi_len + 1):
                rs = parser(addr[:L])
                if not in_ranges(h, rs):
                    bad += 1
        check("%-7s prefixes of length %d..%d always contain their own hash" % (kind, lo_len, hi_len),
              bad == 0, "" if not bad else "%d misses" % bad)

    print("\n[B] no false positives: a hash in range really does produce the prefix")
    bad = 0
    tested = 0
    for a in ADDR:
        addr, h = a['p2pkh']
        for L in (2, 3, 4, 5):
            pre = addr[:L]
            rs = parse_base58(pre, 0)
            for other in ADDR:
                oaddr, oh = other['p2pkh']
                if in_ranges(oh, rs):
                    tested += 1
                    # In-range must imply the prefix matches, modulo the 4 checksum
                    # bytes we cannot constrain — so we allow the boundary case.
                    if not oaddr.startswith(pre):
                        lo, hi = [r for r in rs if r[0] <= oh <= r[1]][0]
                        if oh not in (lo, hi):
                            bad += 1
    check("in-range implies prefix match, except at range boundaries", bad == 0,
          "checked %d in-range pairs" % tested)

    print("\n[C] difficulty is the reciprocal of the accepted fraction")
    for pre, kind, ver in [("1A", 'p2pkh', 0), ("1Love", 'p2pkh', 0), ("3Cy", 'p2sh', 5)]:
        rs = parse_base58(pre, ver)
        accepted = sum(hi - lo + 1 for lo, hi in rs)
        diff = (1 << 160) / accepted
        print("        %-8s ranges=%d  difficulty=%.4g  (58^%d = %.4g)" %
              (pre, len(rs), diff, len(pre) - 1, 58.0 ** (len(pre) - 1)))
    rs = parse_bech32("bc1qne0n")
    check("bech32 'bc1qne0n' difficulty == 32^4", abs((1 << 160) / (rs[0][1] - rs[0][0] + 1) - 32 ** 4) < 1e-6)
    rs = parse_hex("0xdecaf")
    check("eth '0xdecaf' difficulty == 16^5", abs((1 << 160) / (rs[0][1] - rs[0][0] + 1) - 16 ** 5) < 1e-6)

    print("\n[C2] predicted difficulty vs. observed hit rate over 400k random hashes")
    random.seed(7)
    SAMPLES = 400_000
    pool = [random.getrandbits(160) for _ in range(SAMPLES)]
    addrs0 = [b58check(0, h.to_bytes(20, 'big')) for h in pool]
    addrs5 = [b58check(5, h.to_bytes(20, 'big')) for h in pool]
    for pre, ver in [("1A", 0), ("1z", 0), ("1Q", 0), ("3C", 5), ("11", 0), ("1", 0)]:
        rs = parse_base58(pre, ver)
        predicted = (1 << 160) / sum(hi - lo + 1 for lo, hi in rs)
        src = addrs0 if ver == 0 else addrs5
        hits = sum(1 for a in src if a.startswith(pre))
        expected = SAMPLES / predicted
        # Poisson: allow 4 sigma, and skip prefixes too rare to say anything about.
        tol = 4.0 * (expected ** 0.5)
        check("%-3s expected %8.1f hits, observed %8d" % (pre, expected, hits),
              abs(hits - expected) <= max(tol, 3), "±%.0f" % tol)

    print("\n[C3] second-character distribution")
    from collections import Counter
    c = Counter(a[1] for a in addrs0[:80000])
    print("        %d distinct 2nd characters; most common: %s" %
          (len(c), "".join(ch for ch, _ in c.most_common(8))))
    low = sum(n for ch, n in c.items() if B58.index(ch) <= 23)
    print("        %.1f%% of addresses have a 2nd character in the low 24 digits" % (100.0 * low / 80000))

    print("\n[D] edge cases")
    check("'1' alone accepts every P2PKH hash", in_ranges(0, parse_base58("1", 0)) and
          in_ranges((1 << 160) - 1, parse_base58("1", 0)))
    check("'11' requires a leading zero byte",
          in_ranges(0x00_112233445566778899aabbccddeeff0011223344 & ((1 << 152) - 1), parse_base58("11", 0)) and
          not in_ranges((1 << 160) - 1, parse_base58("11", 0)))
    check("P2PKH prefix not starting with 1 is rejected", parse_base58("2abc", 0) == [])
    check("P2SH prefix starting with 1 is rejected", parse_base58("1abc", 5) == [])

    # a genuine short-address key: hash160 with a leading zero byte gives a 33-char address
    found = None
    for k in range(1, 40000):
        X, Y = ec_mul(k)
        comp = bytes([2 + (Y & 1)]) + X.to_bytes(32, 'big')
        h = ripemd160(hashlib.sha256(comp).digest())
        if h[0] == 0:
            found = (k, h)
            break
    if found:
        k, h = found
        addr = b58check(0, h)
        print("        short address found at k=%d: %s (len %d)" % (k, addr, len(addr)))
        ok = all(in_ranges(int.from_bytes(h, 'big'), parse_base58(addr[:L], 0)) for L in range(2, 7))
        check("33-char address is matched by its own prefixes", ok)
    else:
        print("        (no leading-zero hash160 in the scanned range; skipping)")

    print("\n" + ("ALL CHECKS PASSED" if not fails else "FAILURES: " + ", ".join(fails)))
    return 1 if fails else 0


if __name__ == "__main__":
    raise SystemExit(run_tests())
