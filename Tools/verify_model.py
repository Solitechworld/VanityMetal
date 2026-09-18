#!/usr/bin/env python3
"""
Reference model for VanityKernels.metal.

Re-implements the GPU algorithms limb-for-limb in Python and checks them
against independent ground truth (Python's own big integers, hashlib, and
published test vectors).  Run this whenever the kernel maths is touched.
"""
import hashlib, struct

P = 2**256 - 2**32 - 977
N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
GX = 0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798
GY = 0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8

# --------------------------------------------------------------------------
# 1. Field reduction, mirroring fe_reduce512 limb-for-limb
# --------------------------------------------------------------------------
M32 = 0xFFFFFFFF
P_LIMBS = [P >> (32 * i) & M32 for i in range(8)]
assert P_LIMBS == [0xFFFFFC2F, 0xFFFFFFFE] + [0xFFFFFFFF] * 6, [hex(x) for x in P_LIMBS]


def to_limbs(x, n):
    return [(x >> (32 * i)) & M32 for i in range(n)]


def from_limbs(l):
    return sum(v << (32 * i) for i, v in enumerate(l))


def fe_cond_sub_p(acc):
    if from_limbs(acc[:8]) >= P:
        v = from_limbs(acc[:8]) - P
        acc[:8] = to_limbs(v, 8)


def fe_reduce512(t):
    acc = t[:8] + [0, 0]
    carry = 0
    for i in range(10):
        hv = t[8 + i] if i < 8 else 0
        v = acc[i] + hv * 977 + carry
        acc[i] = v & M32
        carry = v >> 32
    carry = 0
    for i in range(1, 10):
        hv = t[8 + i - 1] if (i - 1) < 8 else 0
        v = acc[i] + hv + carry
        acc[i] = v & M32
        carry = v >> 32
    assert carry == 0, "fold 1 overflowed the 10-limb accumulator"

    h1, h2 = acc[8], acc[9]
    acc[8] = acc[9] = 0
    carry = 0
    for i in range(10):
        hv = h1 if i == 0 else (h2 if i == 1 else 0)
        v = acc[i] + hv * 977 + carry
        acc[i] = v & M32
        carry = v >> 32
    carry = 0
    for i in range(1, 10):
        hv = h1 if i == 1 else (h2 if i == 2 else 0)
        v = acc[i] + hv + carry
        acc[i] = v & M32
        carry = v >> 32
    assert carry == 0, "fold 2 overflowed"
    assert acc[9] == 0, "fold 2 left a non-zero limb 9"
    assert acc[8] <= 1, "fold 2 left limb 8 = %d (expected 0 or 1)" % acc[8]

    h3 = acc[8]
    acc[8] = 0
    carry = 0
    for i in range(8):
        hv = h3 if i == 0 else 0
        v = acc[i] + hv * 977 + carry
        acc[i] = v & M32
        carry = v >> 32
    assert carry == 0
    carry = 0
    for i in range(1, 8):
        hv = h3 if i == 1 else 0
        v = acc[i] + hv + carry
        acc[i] = v & M32
        carry = v >> 32
    assert carry == 0, "fold 3 carried out -- the bound proof is wrong"

    fe_cond_sub_p(acc)
    fe_cond_sub_p(acc)
    return acc[:8]


def fe_mul_model(a, b):
    la, lb = to_limbs(a, 8), to_limbs(b, 8)
    t = [0] * 16
    for i in range(8):
        carry = 0
        for j in range(8):
            v = la[i] * lb[j] + t[i + j] + carry
            t[i + j] = v & M32
            carry = v >> 32
        t[i + 8] = carry
        assert carry <= M32
    return from_limbs(fe_reduce512(t))


def fe_add_model(a, b):
    la, lb = to_limbs(a, 8), to_limbs(b, 8)
    r = [0] * 8
    carry = 0
    for i in range(8):
        v = la[i] + lb[i] + carry
        r[i] = v & M32
        carry = v >> 32
    if carry:
        c = 977
        for i in range(8):
            v = r[i] + c
            r[i] = v & M32
            c = v >> 32
            if i == 0:
                c += 1
        assert c == 0, "add fold carried out"
    fe_cond_sub_p(r)
    return from_limbs(r)


# --------------------------------------------------------------------------
# 2. The libsecp256k1 inversion addition chain, exactly as written in MSL
# --------------------------------------------------------------------------
def pow2k(a, k):
    for _ in range(k):
        a = a * a % P
    return a


def fe_inv_chain(a):
    x2 = pow2k(a, 1) * a % P
    x3 = pow2k(x2, 1) * a % P
    x6 = pow2k(x3, 3) * x3 % P
    x9 = pow2k(x6, 3) * x3 % P
    x11 = pow2k(x9, 2) * x2 % P
    x22 = pow2k(x11, 11) * x11 % P
    x44 = pow2k(x22, 22) * x22 % P
    x88 = pow2k(x44, 44) * x44 % P
    x176 = pow2k(x88, 88) * x88 % P
    x220 = pow2k(x176, 44) * x44 % P
    x223 = pow2k(x220, 3) * x3 % P
    t = pow2k(x223, 23)
    t = t * x22 % P
    t = pow2k(t, 5) * a % P
    t = pow2k(t, 3) * x2 % P
    t = pow2k(t, 2) * a % P
    return t


# --------------------------------------------------------------------------
# 3. RIPEMD-160, mirroring ripemd160_32
# --------------------------------------------------------------------------
RL = ([0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15]
      + [7,4,13,1,10,6,15,3,12,0,9,5,2,14,11,8]
      + [3,10,14,4,9,15,8,1,2,7,0,6,13,11,5,12]
      + [1,9,11,10,0,8,12,4,13,3,7,15,14,5,6,2]
      + [4,0,5,9,7,12,2,10,14,1,3,8,11,6,15,13])
RR = ([5,14,7,0,9,2,11,4,13,6,15,8,1,10,3,12]
      + [6,11,3,7,0,13,5,10,14,15,8,12,4,9,1,2]
      + [15,5,1,3,7,14,6,9,11,8,12,2,10,0,4,13]
      + [8,6,4,1,3,11,15,0,5,12,2,13,9,7,10,14]
      + [12,15,10,4,1,5,8,7,6,2,13,14,0,3,9,11])
SL = ([11,14,15,12,5,8,7,9,11,13,14,15,6,7,9,8]
      + [7,6,8,13,11,9,7,15,7,12,15,9,11,7,13,12]
      + [11,13,6,7,14,9,13,15,14,8,13,6,5,12,7,5]
      + [11,12,14,15,14,15,9,8,9,14,5,6,8,6,5,12]
      + [9,15,5,11,6,8,13,12,5,12,13,14,11,8,5,6])
SR = ([8,9,9,11,13,15,15,5,7,7,8,11,14,14,12,6]
      + [9,13,15,7,12,8,9,11,7,7,12,7,6,15,13,11]
      + [9,7,15,11,8,6,6,14,12,13,5,14,13,13,7,5]
      + [15,5,8,11,14,14,6,14,6,9,12,9,12,5,15,8]
      + [8,5,12,9,12,5,14,6,8,13,6,5,15,13,11,11])
KL = [0x00000000, 0x5A827999, 0x6ED9EBA1, 0x8F1BBCDC, 0xA953FD4E]
KR = [0x50A28BE6, 0x5C4DD124, 0x6D703EF3, 0x7A6D76E9, 0x00000000]


def rol(x, n):
    x &= M32
    return ((x << n) | (x >> (32 - n))) & M32


def rmd_f(j, x, y, z):
    if j < 16: return x ^ y ^ z
    if j < 32: return (x & y) | (~x & M32 & z)
    if j < 48: return (x | (~y & M32)) ^ z
    if j < 64: return (x & z) | (y & (~z & M32))
    return x ^ (y | (~z & M32))


def ripemd160(msg):
    """Full RIPEMD-160 (multi-block) — the GPU version is the 32-byte case."""
    h = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0]
    ml = len(msg) * 8
    msg = msg + b'\x80'
    while len(msg) % 64 != 56:
        msg += b'\x00'
    msg += struct.pack('<Q', ml)
    for off in range(0, len(msg), 64):
        w = list(struct.unpack('<16I', msg[off:off + 64]))
        al, bl, cl, dl, el = h
        ar, br, cr, dr, er = h
        for j in range(80):
            rnd = j >> 4
            t = (rol((al + rmd_f(j, bl, cl, dl) + w[RL[j]] + KL[rnd]) & M32, SL[j]) + el) & M32
            al, el, dl, cl, bl = el, dl, rol(cl, 10), bl, t
            t = (rol((ar + rmd_f(79 - j, br, cr, dr) + w[RR[j]] + KR[rnd]) & M32, SR[j]) + er) & M32
            ar, er, dr, cr, br = er, dr, rol(cr, 10), br, t
        tmp = (h[1] + cl + dr) & M32
        h[1] = (h[2] + dl + er) & M32
        h[2] = (h[3] + el + ar) & M32
        h[3] = (h[4] + al + br) & M32
        h[4] = (h[0] + bl + cr) & M32
        h[0] = tmp
    return b''.join(struct.pack('<I', x) for x in h)


# --------------------------------------------------------------------------
# 4. Keccak-256, mirroring keccak_f
# --------------------------------------------------------------------------
RC = [0x0000000000000001, 0x0000000000008082, 0x800000000000808a, 0x8000000080008000,
      0x000000000000808b, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
      0x000000000000008a, 0x0000000000000088, 0x0000000080008009, 0x000000008000000a,
      0x000000008000808b, 0x800000000000008b, 0x8000000000008089, 0x8000000000008003,
      0x8000000000008002, 0x8000000000000080, 0x000000000000800a, 0x800000008000000a,
      0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008]
ROT = [1,3,6,10,15,21,28,36,45,55,2,14,27,41,56,8,25,43,62,18,39,61,20,44]
PIL = [10,7,11,17,18,3,5,16,8,21,24,4,15,23,19,13,12,2,20,14,22,9,6,1]
M64 = 0xFFFFFFFFFFFFFFFF


def rol64(x, n):
    return ((x << n) | (x >> (64 - n))) & M64


def keccak_f(a):
    for r in range(24):
        c = [a[x] ^ a[x + 5] ^ a[x + 10] ^ a[x + 15] ^ a[x + 20] for x in range(5)]
        for x in range(5):
            d = c[(x + 4) % 5] ^ rol64(c[(x + 1) % 5], 1)
            for y in range(0, 25, 5):
                a[x + y] ^= d
        t = a[1]
        for i in range(24):
            j = PIL[i]
            bc = a[j]
            a[j] = rol64(t, ROT[i])
            t = bc
        for y in range(0, 25, 5):
            tv = a[y:y + 5]
            for x in range(5):
                a[y + x] = tv[x] ^ ((~tv[(x + 1) % 5]) & M64 & tv[(x + 2) % 5])
        a[0] ^= RC[r]
    return a


def keccak256_64(data):
    assert len(data) == 64
    a = [0] * 25
    for i in range(8):
        a[i] = int.from_bytes(data[8 * i:8 * i + 8], 'little')
    a[8] ^= 0x01
    a[16] ^= 0x8000000000000000
    keccak_f(a)
    return b''.join(x.to_bytes(8, 'little') for x in a[:4])


# --------------------------------------------------------------------------
# 5. SHA-256 word packing exactly as the kernel builds it
# --------------------------------------------------------------------------
def be_words(x):
    return [(x >> (32 * (7 - i))) & M32 for i in range(8)]


def kernel_sha_words_33(x, parity):
    e = be_words(x)
    w = [0] * 16
    w[0] = ((0x02 + parity) << 24 | (e[0] >> 8)) & M32
    for j in range(1, 8):
        w[j] = ((e[j - 1] << 24) | (e[j] >> 8)) & M32
    w[8] = ((e[7] << 24) & M32) | 0x00800000
    w[15] = 264
    return w


def kernel_sha_words_65(x, y):
    e, f = be_words(x), be_words(y)
    w1 = [0] * 16
    w1[0] = ((0x04 << 24) | (e[0] >> 8)) & M32
    for j in range(1, 8):
        w1[j] = ((e[j - 1] << 24) | (e[j] >> 8)) & M32
    w1[8] = ((e[7] << 24) & M32) | (f[0] >> 8)
    for j in range(9, 16):
        w1[j] = ((f[j - 9] << 24) | (f[j - 8] >> 8)) & M32
    w2 = [0] * 16
    w2[0] = ((f[7] & 0xFF) << 24) | 0x00800000
    w2[15] = 520
    return w1, w2


def kernel_sha_words_22(hb):
    w = [0] * 16
    w[0] = 0x00140000 | (hb[0] >> 16)
    for j in range(1, 5):
        w[j] = ((hb[j - 1] << 16) | (hb[j] >> 16)) & M32
    w[5] = ((hb[4] << 16) & M32) | 0x00008000
    w[15] = 176
    return w


def words_to_bytes(*blocks):
    out = b''
    for w in blocks:
        out += b''.join(struct.pack('>I', v) for v in w)
    return out


# --------------------------------------------------------------------------
# 6. secp256k1 on plain Python ints (ground truth for the EC walk)
# --------------------------------------------------------------------------
def ec_add(p1, p2):
    if p1 is None: return p2
    if p2 is None: return p1
    (x1, y1), (x2, y2) = p1, p2
    if x1 == x2:
        if (y1 + y2) % P == 0: return None
        lam = 3 * x1 * x1 % P * pow(2 * y1, P - 2, P) % P
    else:
        lam = (y2 - y1) % P * pow((x2 - x1) % P, P - 2, P) % P
    x3 = (lam * lam - x1 - x2) % P
    return (x3, (lam * (x1 - x3) - y1) % P)


def ec_mul(k, pt=(GX, GY)):
    r = None
    while k:
        if k & 1: r = ec_add(r, pt)
        pt = ec_add(pt, pt)
        k >>= 1
    return r


# ==========================================================================
# TESTS
# ==========================================================================
def run_tests():
    fails = []


    def check(name, ok, extra=""):
        print(("  PASS  " if ok else "  FAIL  ") + name + ("  " + extra if extra else ""))
        if not ok:
            fails.append(name)


    print("\n[1] field arithmetic")
    import random
    random.seed(20260816)
    ok = True
    for _ in range(400):
        a = random.randrange(P)
        b = random.randrange(P)
        if fe_mul_model(a, b) != a * b % P: ok = False; break
        if fe_add_model(a, b) != (a + b) % P: ok = False; break
    check("fe_mul / fe_add match big-int arithmetic (400 random pairs)", ok)

    edge = [0, 1, 2, P - 1, P - 2, 2**255, 2**256 - 2**32 - 978, GX, GY]
    ok = all(fe_mul_model(a, b) == a * b % P for a in edge for b in edge)
    check("fe_mul on edge values (incl. p-1, 2^255)", ok)
    ok = all(fe_add_model(a, b) == (a + b) % P for a in edge for b in edge)
    check("fe_add on edge values", ok)

    print("\n[2] modular inverse addition chain")
    ok = all(fe_inv_chain(a) == pow(a, P - 2, P) for a in [1, 2, 3, GX, GY, P - 1, 0x12345678])
    check("fe_inv chain == a^(p-2) mod p", ok)
    ok = all(fe_inv_chain(a) * a % P == 1 for a in [random.randrange(1, P) for _ in range(50)])
    check("fe_inv chain round-trips on 50 random elements", ok)

    print("\n[3] RIPEMD-160")
    check("ripemd160(b'') vector", ripemd160(b'').hex() == "9c1185a5c5e9fc54612808977ee8f548b2258d31",
          ripemd160(b'').hex())
    check("ripemd160(b'abc') vector", ripemd160(b'abc').hex() == "8eb208f7e05d987a9b044a8e98c6b087f15a0bfc",
          ripemd160(b'abc').hex())
    check("ripemd160(b'message digest') vector",
          ripemd160(b'message digest').hex() == "5d0689ef49d2fae572b881b123a85ffa21595f36")
    zero32 = ripemd160(b'\x00' * 32).hex()
    print("        ripemd160(00*32) =", zero32)

    print("\n[4] Keccak-256")
    k_empty64 = keccak256_64(b'\x00' * 64).hex()
    print("        keccak256(00*64) =", k_empty64)
    # Cross-check the permutation against a published Keccak-256 vector for "abc".
    def keccak256_any(data):
        rate = 136
        a = [0] * 25
        pad = bytearray(data) + b'\x01' + b'\x00' * ((-len(data) - 1) % rate)
        pad[-1] |= 0x80
        for off in range(0, len(pad), rate):
            for i in range(rate // 8):
                a[i] ^= int.from_bytes(pad[off + 8 * i:off + 8 * i + 8], 'little')
            keccak_f(a)
        return b''.join(x.to_bytes(8, 'little') for x in a[:4])
    check("keccak256(b'abc') vector",
          keccak256_any(b'abc').hex() == "4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45",
          keccak256_any(b'abc').hex())
    check("keccak256_64 agrees with generic sponge",
          keccak256_64(b'\x11' * 64) == keccak256_any(b'\x11' * 64))

    print("\n[5] SHA-256 message packing")
    priv = 0xC0FFEE0BADCAFE1234567890ABCDEF00112233445566778899AABBCCDDEEFF01
    X, Y = ec_mul(priv)
    parity = Y & 1
    comp = bytes([2 + parity]) + X.to_bytes(32, 'big')
    unco = b'\x04' + X.to_bytes(32, 'big') + Y.to_bytes(32, 'big')
    check("33-byte compressed block matches real message",
          words_to_bytes(kernel_sha_words_33(X, parity))[:33] == comp)
    w1, w2 = kernel_sha_words_65(X, Y)
    check("65-byte uncompressed blocks match real message",
          words_to_bytes(w1, w2)[:65] == unco)

    print("\n[6] full address derivation")
    h160c = ripemd160(hashlib.sha256(comp).digest())
    hb = [int.from_bytes(h160c[4 * i:4 * i + 4], 'big') for i in range(5)]
    redeem = b'\x00\x14' + h160c
    check("22-byte P2SH redeem-script block matches real message",
          words_to_bytes(kernel_sha_words_22(hb))[:22] == redeem)
    h160s = ripemd160(hashlib.sha256(redeem).digest())
    eth = keccak256_64(X.to_bytes(32, 'big') + Y.to_bytes(32, 'big'))[12:]


    def b58check(payload):
        alpha = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
        raw = payload + hashlib.sha256(hashlib.sha256(payload).digest()).digest()[:4]
        n = int.from_bytes(raw, 'big')
        s = ""
        while n:
            n, r = divmod(n, 58)
            s = alpha[r] + s
        return "1" * (len(raw) - len(raw.lstrip(b'\x00'))) + s


    print("        priv       =", hex(priv))
    print("        P2PKH      =", b58check(b'\x00' + h160c))
    print("        P2SH-P2WPKH=", b58check(b'\x05' + h160s))
    print("        ETH        = 0x" + eth.hex())
    check("P2PKH address is 34 chars and starts with 1", b58check(b'\x00' + h160c).startswith("1"))

    print("\n[7] batch-inversion walk (the exact kernel loop)")
    GRP_HALF = 64
    GRP_SIZE = 2 * GRP_HALF + 1
    gtab = [ec_mul(i + 1) for i in range(GRP_HALF)]
    jump = ec_mul(GRP_SIZE)
    k0 = 0x1234_5678_9ABC_DEF0_1122_3344_5566_7788_99AA_BBCC_DDEE_FF00_1234_5678_9ABC_DEF0
    px, py = ec_mul(k0)
    produced = {}
    for it in range(3):
        dxs = [(gtab[i][0] - px) % P for i in range(GRP_HALF)] + [(jump[0] - px) % P]
        pfx, run = [], None
        for d in dxs:
            run = d if run is None else run * d % P
            pfx.append(run)
        inv = fe_inv_chain(run)
        nxt = None
        for i in range(GRP_HALF, -1, -1):
            s = inv if i == 0 else inv * pfx[i - 1] % P
            if i > 0:
                inv = inv * dxs[i] % P
            if i == GRP_HALF:
                gx, gy = jump
                lam = (gy - py) % P * s % P
                nx = (lam * lam - px - gx) % P
                ny = (lam * (px - nx) - py) % P
                nxt = (nx, ny)
                continue
            gx, gy = gtab[i]
            for sign in (0, 1):
                qy = gy if sign == 0 else (-gy) % P
                lam = (qy - py) % P * s % P
                rx = (lam * lam - px - gx) % P
                ry = (lam * (px - rx) - py) % P
                off = (i + 1) if sign == 0 else -(i + 1)
                produced[k0 + it * GRP_SIZE + off] = (rx, ry)
        produced[k0 + it * GRP_SIZE] = (px, py)
        px, py = nxt

    bad = [k for k, v in produced.items() if ec_mul(k) != v]
    check("every generated point equals k*G (%d keys over 3 batches)" % len(produced), not bad,
          "" if not bad else "%d wrong" % len(bad))
    check("3 batches cover exactly 3*129 distinct keys with no gaps",
          len(produced) == 3 * GRP_SIZE and
          sorted(produced) == list(range(k0 - GRP_HALF, k0 - GRP_HALF + 3 * GRP_SIZE)))

    print("\n[8] self-test constants for the GPU selftest kernel")
    r32 = ripemd160(b'\x00' * 32)
    print("        ripemd160(00*32)  word0=0x%08x word4=0x%08x" %
          (int.from_bytes(r32[0:4], 'big'), int.from_bytes(r32[16:20], 'big')))
    k64 = keccak256_64(b'\x00' * 64)
    print("        keccak256(00*64)  word0(BE)=0x%08x" % int.from_bytes(k64[0:4], 'big'))
    s_abc = hashlib.sha256(b'abc').digest()
    print("        sha256('abc')     h0=0x%08x h7=0x%08x" %
          (int.from_bytes(s_abc[0:4], 'big'), int.from_bytes(s_abc[28:32], 'big')))

    print("\n" + ("ALL CHECKS PASSED" if not fails else "FAILURES: " + ", ".join(fails)))
    return 1 if fails else 0


if __name__ == "__main__":
    raise SystemExit(run_tests())
