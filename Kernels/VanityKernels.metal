//
//  VanityKernels.metal
//  VanityMetal — GPU vanity address engine for Apple Silicon and T2 Macs
//
//  This is a from-scratch Metal implementation of the search core that CUDA
//  projects such as VanitySearch run on NVIDIA hardware.  Everything the GPU
//  needs lives in this one file:
//
//    * secp256k1 prime-field arithmetic on 8 x 32-bit limbs
//      (32-bit limbs are used deliberately: they run identically well on
//       Apple Silicon, on the Intel Iris / AMD Radeon GPUs found in T2 Macs,
//       and they avoid 64-bit multiply emulation on older drivers)
//    * incremental elliptic-curve point generation with Montgomery batch
//      inversion (one modular inverse per 129 generated public keys)
//    * SHA-256, RIPEMD-160 and Keccak-256
//    * prefix matching for P2PKH, P2SH-P2WPKH, Bech32 (v0) and Ethereum
//
//  Design note: the GPU is a *filter*, not an oracle.  Every hit it reports is
//  re-derived and re-verified on the CPU before it is ever shown to the user,
//  so a numerical bug here can cost throughput but can never produce a wrong
//  private key.
//

#include <metal_stdlib>
using namespace metal;

// ---------------------------------------------------------------------------
// Tunables — must stay in sync with VMKernelConstants in Swift.
// ---------------------------------------------------------------------------

#define GRP_HALF   64u                       // points generated each side of P
#define GRP_SIZE   (2u * GRP_HALF + 1u)      // 129 keys per batch, per thread
#define PFX_SLOTS  (GRP_HALF + 1u)           // +1 slot for the jump point

// Address kinds (must match AddressKind in Swift)
#define KIND_P2PKH_C   0u
#define KIND_P2PKH_U   1u
#define KIND_P2SH      2u
#define KIND_BECH32    3u
#define KIND_ETH       4u

// Hash paths the dispatch actually needs (bit flags, must match Swift)
#define PATH_H160_C    (1u << 0)
#define PATH_H160_U    (1u << 1)
#define PATH_P2SH      (1u << 2)
#define PATH_ETH       (1u << 3)

// ---------------------------------------------------------------------------
// Shared structures (mirrored byte-for-byte in Swift)
// ---------------------------------------------------------------------------

struct VMParams {
    uint targetCount;
    uint hashPaths;
    uint batchIterations;
    uint maxResults;
    uint threadCount;
    uint iterationBase;
    uint _r0;
    uint _r1;
};

// A target is an inclusive range over the 20-byte hash, held as big-endian
// 32-bit words.  Ranges rather than bit-masks: a Base58 prefix does not map
// onto a whole number of bits, so a mask would either miss valid addresses or
// admit invalid ones.  A range is exact, and it makes the difficulty figure
// exact too (2^160 / range size).
struct VMTarget {
    uint lo[5];
    uint hi[5];
    uint kind;
    uint _pad;
};

struct VMResult {
    uint threadId;
    int  offset;        // -GRP_HALF ... +GRP_HALF
    uint iteration;
    uint targetIndex;
    uint kind;
    uint parity;        // 0 = even Y, 1 = odd Y
    uint h[5];
    uint _pad[5];
};

// ===========================================================================
// MARK: - Prime field arithmetic, p = 2^256 - 2^32 - 977
// ===========================================================================

struct FE { uint d[8]; };

constant uint P_LIMBS[8] = {
    0xFFFFFC2Fu, 0xFFFFFFFEu, 0xFFFFFFFFu, 0xFFFFFFFFu,
    0xFFFFFFFFu, 0xFFFFFFFFu, 0xFFFFFFFFu, 0xFFFFFFFFu
};

static inline FE fe_zero() {
    FE r;
    for (uint i = 0; i < 8; i++) r.d[i] = 0u;
    return r;
}

static inline bool fe_is_zero(FE a) {
    uint acc = 0u;
    for (uint i = 0; i < 8; i++) acc |= a.d[i];
    return acc == 0u;
}

// Returns true when a >= p.
static inline bool fe_ge_p(thread const FE &a) {
    for (int i = 7; i >= 0; i--) {
        if (a.d[i] > P_LIMBS[i]) return true;
        if (a.d[i] < P_LIMBS[i]) return false;
    }
    return true;
}

static inline void fe_cond_sub_p(thread FE &a) {
    if (!fe_ge_p(a)) return;
    ulong borrow = 0;
    for (uint i = 0; i < 8; i++) {
        ulong v = (ulong)a.d[i] - (ulong)P_LIMBS[i] - borrow;
        a.d[i] = (uint)v;
        borrow = (v >> 63) & 1UL;   // borrow occurred iff the result went negative
    }
}

static inline FE fe_add(FE a, FE b) {
    FE r;
    ulong carry = 0;
    for (uint i = 0; i < 8; i++) {
        ulong v = (ulong)a.d[i] + (ulong)b.d[i] + carry;
        r.d[i] = (uint)v;
        carry = v >> 32;
    }
    // A carry out of 256 bits folds back in as +2^32+977.
    if (carry != 0) {
        ulong c = 977UL;
        for (uint i = 0; i < 8; i++) {
            ulong v = (ulong)r.d[i] + c;
            r.d[i] = (uint)v;
            c = v >> 32;
            if (i == 0) c += 1UL;   // the 2^32 part
        }
    }
    fe_cond_sub_p(r);
    return r;
}

static inline FE fe_sub(FE a, FE b) {
    FE r;
    ulong borrow = 0;
    for (uint i = 0; i < 8; i++) {
        ulong v = (ulong)a.d[i] - (ulong)b.d[i] - borrow;
        r.d[i] = (uint)v;
        borrow = (v >> 63) & 1UL;
    }
    if (borrow != 0) {   // add p back
        ulong carry = 0;
        for (uint i = 0; i < 8; i++) {
            ulong v = (ulong)r.d[i] + (ulong)P_LIMBS[i] + carry;
            r.d[i] = (uint)v;
            carry = v >> 32;
        }
    }
    return r;
}

static inline FE fe_neg(FE a) {
    if (fe_is_zero(a)) return a;
    FE r;
    ulong borrow = 0;
    for (uint i = 0; i < 8; i++) {
        ulong v = (ulong)P_LIMBS[i] - (ulong)a.d[i] - borrow;
        r.d[i] = (uint)v;
        borrow = (v >> 63) & 1UL;
    }
    return r;
}

// Folds a 512-bit product down to a canonical field element.
static inline FE fe_reduce512(thread const uint t[16]) {
    uint acc[10];
    for (uint i = 0; i < 8; i++) acc[i] = t[i];
    acc[8] = 0u; acc[9] = 0u;

    // acc += high * 977
    ulong carry = 0;
    for (uint i = 0; i < 10; i++) {
        ulong hv = (i < 8) ? (ulong)t[8 + i] : 0UL;
        ulong v = (ulong)acc[i] + hv * 977UL + carry;
        acc[i] = (uint)v;
        carry = v >> 32;
    }
    // acc += high << 32
    carry = 0;
    for (uint i = 1; i < 10; i++) {
        ulong hv = ((i - 1) < 8) ? (ulong)t[8 + i - 1] : 0UL;
        ulong v = (ulong)acc[i] + hv + carry;
        acc[i] = (uint)v;
        carry = v >> 32;
    }

    // Second fold: acc[8..9] is now < 2^33.
    uint h1 = acc[8], h2 = acc[9];
    acc[8] = 0u; acc[9] = 0u;
    carry = 0;
    for (uint i = 0; i < 10; i++) {
        ulong hv = (i == 0) ? (ulong)h1 : ((i == 1) ? (ulong)h2 : 0UL);
        ulong v = (ulong)acc[i] + hv * 977UL + carry;
        acc[i] = (uint)v;
        carry = v >> 32;
    }
    carry = 0;
    for (uint i = 1; i < 10; i++) {
        ulong hv = (i == 1) ? (ulong)h1 : ((i == 2) ? (ulong)h2 : 0UL);
        ulong v = (ulong)acc[i] + hv + carry;
        acc[i] = (uint)v;
        carry = v >> 32;
    }

    // Third fold: acc[8] is now 0 or 1 and acc[0..7] is tiny when it is 1,
    // so this pass provably cannot carry out again.
    uint h3 = acc[8];
    acc[8] = 0u;
    carry = 0;
    for (uint i = 0; i < 8; i++) {
        ulong hv = (i == 0) ? (ulong)h3 : 0UL;
        ulong v = (ulong)acc[i] + hv * 977UL + carry;
        acc[i] = (uint)v;
        carry = v >> 32;
    }
    carry = 0;
    for (uint i = 1; i < 8; i++) {
        ulong hv = (i == 1) ? (ulong)h3 : 0UL;
        ulong v = (ulong)acc[i] + hv + carry;
        acc[i] = (uint)v;
        carry = v >> 32;
    }

    FE r;
    for (uint i = 0; i < 8; i++) r.d[i] = acc[i];
    fe_cond_sub_p(r);
    fe_cond_sub_p(r);
    return r;
}

static inline FE fe_mul(FE a, FE b) {
    uint t[16];
    for (uint i = 0; i < 16; i++) t[i] = 0u;
    for (uint i = 0; i < 8; i++) {
        ulong carry = 0;
        uint ai = a.d[i];
        for (uint j = 0; j < 8; j++) {
            ulong v = (ulong)ai * (ulong)b.d[j] + (ulong)t[i + j] + carry;
            t[i + j] = (uint)v;
            carry = v >> 32;
        }
        t[i + 8] = (uint)carry;   // untouched by previous rounds, so a plain store is correct
    }
    return fe_reduce512(t);
}

static inline FE fe_sqr(FE a) { return fe_mul(a, a); }

static inline FE fe_pow2k(FE a, uint k) {
    for (uint i = 0; i < k; i++) a = fe_sqr(a);
    return a;
}

// Modular inverse via the libsecp256k1 addition chain: 255 squarings + 15
// multiplications, roughly 30% cheaper than plain square-and-multiply.
static inline FE fe_inv(FE a) {
    FE x2  = fe_mul(fe_sqr(a), a);
    FE x3  = fe_mul(fe_sqr(x2), a);
    FE x6  = fe_mul(fe_pow2k(x3, 3), x3);
    FE x9  = fe_mul(fe_pow2k(x6, 3), x3);
    FE x11 = fe_mul(fe_pow2k(x9, 2), x2);
    FE x22 = fe_mul(fe_pow2k(x11, 11), x11);
    FE x44 = fe_mul(fe_pow2k(x22, 22), x22);
    FE x88 = fe_mul(fe_pow2k(x44, 44), x44);
    FE x176 = fe_mul(fe_pow2k(x88, 88), x88);
    FE x220 = fe_mul(fe_pow2k(x176, 44), x44);
    FE x223 = fe_mul(fe_pow2k(x220, 3), x3);

    FE t = fe_pow2k(x223, 23);
    t = fe_mul(t, x22);
    t = fe_pow2k(t, 5);
    t = fe_mul(t, a);
    t = fe_pow2k(t, 3);
    t = fe_mul(t, x2);
    t = fe_pow2k(t, 2);
    t = fe_mul(t, a);
    return t;
}

// ===========================================================================
// MARK: - SHA-256
// ===========================================================================

constant uint SHA_K[64] = {
    0x428a2f98u,0x71374491u,0xb5c0fbcfu,0xe9b5dba5u,0x3956c25bu,0x59f111f1u,0x923f82a4u,0xab1c5ed5u,
    0xd807aa98u,0x12835b01u,0x243185beu,0x550c7dc3u,0x72be5d74u,0x80deb1feu,0x9bdc06a7u,0xc19bf174u,
    0xe49b69c1u,0xefbe4786u,0x0fc19dc6u,0x240ca1ccu,0x2de92c6fu,0x4a7484aau,0x5cb0a9dcu,0x76f988dau,
    0x983e5152u,0xa831c66du,0xb00327c8u,0xbf597fc7u,0xc6e00bf3u,0xd5a79147u,0x06ca6351u,0x14292967u,
    0x27b70a85u,0x2e1b2138u,0x4d2c6dfcu,0x53380d13u,0x650a7354u,0x766a0abbu,0x81c2c92eu,0x92722c85u,
    0xa2bfe8a1u,0xa81a664bu,0xc24b8b70u,0xc76c51a3u,0xd192e819u,0xd6990624u,0xf40e3585u,0x106aa070u,
    0x19a4c116u,0x1e376c08u,0x2748774cu,0x34b0bcb5u,0x391c0cb3u,0x4ed8aa4au,0x5b9cca4fu,0x682e6ff3u,
    0x748f82eeu,0x78a5636fu,0x84c87814u,0x8cc70208u,0x90befffau,0xa4506cebu,0xbef9a3f7u,0xc67178f2u
};

static inline uint rotr32(uint x, uint n) { return (x >> n) | (x << (32u - n)); }
static inline uint rotl32(uint x, uint n) { return (x << n) | (x >> (32u - n)); }
static inline uint bswap32(uint x) {
    return ((x >> 24) & 0x000000FFu) | ((x >> 8) & 0x0000FF00u) |
           ((x << 8) & 0x00FF0000u) | ((x << 24) & 0xFF000000u);
}

static inline void sha256_block(thread uint h[8], thread uint w[16]) {
    uint m[64];
    for (uint i = 0; i < 16; i++) m[i] = w[i];
    for (uint i = 16; i < 64; i++) {
        uint s0 = rotr32(m[i-15], 7) ^ rotr32(m[i-15], 18) ^ (m[i-15] >> 3);
        uint s1 = rotr32(m[i-2], 17) ^ rotr32(m[i-2], 19) ^ (m[i-2] >> 10);
        m[i] = m[i-16] + s0 + m[i-7] + s1;
    }
    uint a = h[0], b = h[1], c = h[2], d = h[3];
    uint e = h[4], f = h[5], g = h[6], hh = h[7];
    for (uint i = 0; i < 64; i++) {
        uint S1 = rotr32(e, 6) ^ rotr32(e, 11) ^ rotr32(e, 25);
        uint ch = (e & f) ^ ((~e) & g);
        uint t1 = hh + S1 + ch + SHA_K[i] + m[i];
        uint S0 = rotr32(a, 2) ^ rotr32(a, 13) ^ rotr32(a, 22);
        uint mj = (a & b) ^ (a & c) ^ (b & c);
        uint t2 = S0 + mj;
        hh = g; g = f; f = e; e = d + t1;
        d = c; c = b; b = a; a = t1 + t2;
    }
    h[0] += a; h[1] += b; h[2] += c; h[3] += d;
    h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
}

static inline void sha256_init(thread uint h[8]) {
    h[0] = 0x6a09e667u; h[1] = 0xbb67ae85u; h[2] = 0x3c6ef372u; h[3] = 0xa54ff53au;
    h[4] = 0x510e527fu; h[5] = 0x9b05688cu; h[6] = 0x1f83d9abu; h[7] = 0x5be0cd19u;
}

// ===========================================================================
// MARK: - RIPEMD-160
// ===========================================================================

constant uint RMD_RL[80] = {
     0, 1, 2, 3, 4, 5, 6, 7, 8, 9,10,11,12,13,14,15,
     7, 4,13, 1,10, 6,15, 3,12, 0, 9, 5, 2,14,11, 8,
     3,10,14, 4, 9,15, 8, 1, 2, 7, 0, 6,13,11, 5,12,
     1, 9,11,10, 0, 8,12, 4,13, 3, 7,15,14, 5, 6, 2,
     4, 0, 5, 9, 7,12, 2,10,14, 1, 3, 8,11, 6,15,13
};
constant uint RMD_RR[80] = {
     5,14, 7, 0, 9, 2,11, 4,13, 6,15, 8, 1,10, 3,12,
     6,11, 3, 7, 0,13, 5,10,14,15, 8,12, 4, 9, 1, 2,
    15, 5, 1, 3, 7,14, 6, 9,11, 8,12, 2,10, 0, 4,13,
     8, 6, 4, 1, 3,11,15, 0, 5,12, 2,13, 9, 7,10,14,
    12,15,10, 4, 1, 5, 8, 7, 6, 2,13,14, 0, 3, 9,11
};
constant uint RMD_SL[80] = {
    11,14,15,12, 5, 8, 7, 9,11,13,14,15, 6, 7, 9, 8,
     7, 6, 8,13,11, 9, 7,15, 7,12,15, 9,11, 7,13,12,
    11,13, 6, 7,14, 9,13,15,14, 8,13, 6, 5,12, 7, 5,
    11,12,14,15,14,15, 9, 8, 9,14, 5, 6, 8, 6, 5,12,
     9,15, 5,11, 6, 8,13,12, 5,12,13,14,11, 8, 5, 6
};
constant uint RMD_SR[80] = {
     8, 9, 9,11,13,15,15, 5, 7, 7, 8,11,14,14,12, 6,
     9,13,15, 7,12, 8, 9,11, 7, 7,12, 7, 6,15,13,11,
     9, 7,15,11, 8, 6, 6,14,12,13, 5,14,13,13, 7, 5,
    15, 5, 8,11,14,14, 6,14, 6, 9,12, 9,12, 5,15, 8,
     8, 5,12, 9,12, 5,14, 6, 8,13, 6, 5,15,13,11,11
};
constant uint RMD_KL[5] = { 0x00000000u, 0x5A827999u, 0x6ED9EBA1u, 0x8F1BBCDCu, 0xA953FD4Eu };
constant uint RMD_KR[5] = { 0x50A28BE6u, 0x5C4DD124u, 0x6D703EF3u, 0x7A6D76E9u, 0x00000000u };

static inline uint rmd_f(uint j, uint x, uint y, uint z) {
    if (j < 16) return x ^ y ^ z;
    if (j < 32) return (x & y) | ((~x) & z);
    if (j < 48) return (x | (~y)) ^ z;
    if (j < 64) return (x & z) | (y & (~z));
    return x ^ (y | (~z));
}

// RIPEMD-160 of exactly 32 bytes, supplied as little-endian words.
static inline void ripemd160_32(thread const uint msg[8], thread uint out[5]) {
    uint w[16];
    for (uint i = 0; i < 8; i++) w[i] = msg[i];
    w[8] = 0x00000080u;
    for (uint i = 9; i < 14; i++) w[i] = 0u;
    w[14] = 256u;   // bit length
    w[15] = 0u;

    uint h0 = 0x67452301u, h1 = 0xEFCDAB89u, h2 = 0x98BADCFEu, h3 = 0x10325476u, h4 = 0xC3D2E1F0u;
    uint al = h0, bl = h1, cl = h2, dl = h3, el = h4;
    uint ar = h0, br = h1, cr = h2, dr = h3, er = h4;

    for (uint j = 0; j < 80; j++) {
        uint round = j >> 4;
        uint t = rotl32(al + rmd_f(j, bl, cl, dl) + w[RMD_RL[j]] + RMD_KL[round], RMD_SL[j]) + el;
        al = el; el = dl; dl = rotl32(cl, 10); cl = bl; bl = t;

        t = rotl32(ar + rmd_f(79u - j, br, cr, dr) + w[RMD_RR[j]] + RMD_KR[round], RMD_SR[j]) + er;
        ar = er; er = dr; dr = rotl32(cr, 10); cr = br; br = t;
    }

    uint tmp = h1 + cl + dr;
    h1 = h2 + dl + er;
    h2 = h3 + el + ar;
    h3 = h4 + al + br;
    h4 = h0 + bl + cr;
    h0 = tmp;

    // Emit as big-endian words so comparisons against the target are byte-order
    // identical to how an address is decoded on the CPU.
    out[0] = bswap32((h0));
    out[1] = bswap32((h1));
    out[2] = bswap32((h2));
    out[3] = bswap32((h3));
    out[4] = bswap32((h4));
}

// ===========================================================================
// MARK: - Keccak-256 (Ethereum)
// ===========================================================================

constant ulong KECCAK_RC[24] = {
    0x0000000000000001UL, 0x0000000000008082UL, 0x800000000000808aUL, 0x8000000080008000UL,
    0x000000000000808bUL, 0x0000000080000001UL, 0x8000000080008081UL, 0x8000000000008009UL,
    0x000000000000008aUL, 0x0000000000000088UL, 0x0000000080008009UL, 0x000000008000000aUL,
    0x000000008000808bUL, 0x800000000000008bUL, 0x8000000000008089UL, 0x8000000000008003UL,
    0x8000000000008002UL, 0x8000000000000080UL, 0x000000000000800aUL, 0x800000008000000aUL,
    0x8000000080008081UL, 0x8000000000008080UL, 0x0000000080000001UL, 0x8000000080008008UL
};
constant uint KECCAK_ROT[24] = { 1,3,6,10,15,21,28,36,45,55,2,14,27,41,56,8,25,43,62,18,39,61,20,44 };
constant uint KECCAK_PIL[24] = { 10,7,11,17,18,3,5,16,8,21,24,4,15,23,19,13,12,2,20,14,22,9,6,1 };

static inline ulong rotl64(ulong x, uint n) { return (x << n) | (x >> (64u - n)); }

static inline void keccak_f(thread ulong a[25]) {
    for (uint r = 0; r < 24; r++) {
        ulong c[5], d[5];
        for (uint x = 0; x < 5; x++)
            c[x] = a[x] ^ a[x+5] ^ a[x+10] ^ a[x+15] ^ a[x+20];
        for (uint x = 0; x < 5; x++) {
            d[x] = c[(x + 4) % 5] ^ rotl64(c[(x + 1) % 5], 1);
            for (uint y = 0; y < 25; y += 5) a[x + y] ^= d[x];
        }
        ulong t = a[1];
        for (uint i = 0; i < 24; i++) {
            uint j = KECCAK_PIL[i];
            ulong bc = a[j];
            a[j] = rotl64(t, KECCAK_ROT[i]);
            t = bc;
        }
        for (uint y = 0; y < 25; y += 5) {
            ulong tv[5];
            for (uint x = 0; x < 5; x++) tv[x] = a[y + x];
            for (uint x = 0; x < 5; x++)
                a[y + x] = tv[x] ^ ((~tv[(x + 1) % 5]) & tv[(x + 2) % 5]);
        }
        a[0] ^= KECCAK_RC[r];
    }
}

// ===========================================================================
// MARK: - Public-key serialisation helpers
// ===========================================================================

// Big-endian 32-bit words of a field element (e[0] is the most significant).
// This is a limb REVERSAL, not a byte swap.  Limb d[7] already holds bits
// 255..224 as a native value, which is exactly the big-endian word SHA-256
// wants for the first four bytes.  Byte-swapping here as well hashes a
// permuted X — and does it consistently enough to produce plausible-looking
// output, which is why the self-test now checks this path end-to-end against
// the generator point rather than trusting the primitives alone.
static inline void fe_to_be_words(FE a, thread uint e[8]) {
    for (uint i = 0; i < 8; i++)
        e[i] = a.d[7 - i];
}

// HASH160 of the 33-byte compressed public key.
static inline void hash160_compressed(thread const uint ex[8], uint parity, thread uint out[5]) {
    uint h[8]; sha256_init(h);
    uint w[16];
    uint prefix = 0x02u + parity;
    w[0] = (prefix << 24) | (ex[0] >> 8);
    for (uint j = 1; j < 8; j++) w[j] = (ex[j-1] << 24) | (ex[j] >> 8);
    w[8] = (ex[7] << 24) | 0x00800000u;
    for (uint j = 9; j < 15; j++) w[j] = 0u;
    w[15] = 264u;   // 33 bytes
    sha256_block(h, w);

    uint le[8];
    for (uint i = 0; i < 8; i++) le[i] = bswap32((h[i]));
    ripemd160_32(le, out);
}

// HASH160 of the 65-byte uncompressed public key.
static inline void hash160_uncompressed(thread const uint ex[8], thread const uint ey[8], thread uint out[5]) {
    uint h[8]; sha256_init(h);
    uint w[16];
    w[0] = (0x04u << 24) | (ex[0] >> 8);
    for (uint j = 1; j < 8; j++) w[j] = (ex[j-1] << 24) | (ex[j] >> 8);
    w[8] = (ex[7] << 24) | (ey[0] >> 8);
    for (uint j = 9; j < 16; j++) w[j] = (ey[j-9] << 24) | (ey[j-8] >> 8);
    sha256_block(h, w);

    // Second block: one trailing Y byte, then padding.
    w[0] = ((ey[7] & 0xFFu) << 24) | 0x00800000u;
    for (uint j = 1; j < 15; j++) w[j] = 0u;
    w[15] = 520u;   // 65 bytes
    sha256_block(h, w);

    uint le[8];
    for (uint i = 0; i < 8; i++) le[i] = bswap32((h[i]));
    ripemd160_32(le, out);
}

// HASH160 of the 22-byte P2WPKH redeem script 0x0014 || hash160(compressed).
static inline void hash160_p2sh(thread const uint hb[5], thread uint out[5]) {
    uint h[8]; sha256_init(h);
    uint w[16];
    w[0] = 0x00140000u | (hb[0] >> 16);
    for (uint j = 1; j < 5; j++) w[j] = (hb[j-1] << 16) | (hb[j] >> 16);
    w[5] = (hb[4] << 16) | 0x00008000u;
    for (uint j = 6; j < 15; j++) w[j] = 0u;
    w[15] = 176u;   // 22 bytes
    sha256_block(h, w);

    uint le[8];
    for (uint i = 0; i < 8; i++) le[i] = bswap32((h[i]));
    ripemd160_32(le, out);
}

// Ethereum address = last 20 bytes of keccak256(X || Y).
static inline void eth_address(thread const uint ex[8], thread const uint ey[8], thread uint out[5]) {
    ulong a[25];
    for (uint i = 0; i < 25; i++) a[i] = 0UL;

    // Absorb 64 bytes into lanes 0..7 (Keccak lanes are little-endian).
    for (uint i = 0; i < 4; i++) {
        uint lo = ex[2*i + 1], hi = ex[2*i];
        a[i] = ((ulong)bswap32((lo)) << 32) | (ulong)bswap32((hi));
    }
    for (uint i = 0; i < 4; i++) {
        uint lo = ey[2*i + 1], hi = ey[2*i];
        a[4 + i] = ((ulong)bswap32((lo)) << 32) | (ulong)bswap32((hi));
    }
    a[8] ^= 0x01UL;                    // domain padding byte at offset 64
    a[16] ^= 0x8000000000000000UL;     // final padding bit at offset 135
    keccak_f(a);

    // Digest bytes 12..31 are the address.  Lane 1 holds bytes 8..15.
    uint d[8];
    for (uint i = 0; i < 4; i++) {
        d[2*i]     = (uint)(a[i] & 0xFFFFFFFFUL);
        d[2*i + 1] = (uint)(a[i] >> 32);
    }
    // d[k] holds digest bytes 4k..4k+3 in little-endian order; convert to BE words.
    uint be[8];
    for (uint i = 0; i < 8; i++) be[i] = bswap32((d[i]));
    for (uint i = 0; i < 5; i++) out[i] = be[3 + i];
}

// ===========================================================================
// MARK: - Target matching
// ===========================================================================

static inline void emit(device VMResult *results,
                        device atomic_uint *counter,
                        constant VMParams &params,
                        uint tid, int offset, uint iteration,
                        uint targetIndex, uint kind, uint parity,
                        thread const uint h[5]) {
    uint slot = atomic_fetch_add_explicit(counter, 1u, memory_order_relaxed);
    if (slot >= params.maxResults) return;
    device VMResult &r = results[slot];
    r.threadId = tid;
    r.offset = offset;
    r.iteration = iteration;
    r.targetIndex = targetIndex;
    r.kind = kind;
    r.parity = parity;
    for (uint i = 0; i < 5; i++) r.h[i] = h[i];
}

// Returns true when the 160-bit big-endian value a is >= b.
static inline bool ge160(thread const uint a[5], device const uint b[5]) {
    for (uint i = 0; i < 5; i++) {
        if (a[i] > b[i]) return true;
        if (a[i] < b[i]) return false;
    }
    return true;
}
static inline bool le160(thread const uint a[5], device const uint b[5]) {
    for (uint i = 0; i < 5; i++) {
        if (a[i] < b[i]) return true;
        if (a[i] > b[i]) return false;
    }
    return true;
}

static inline void match_kind(device const VMTarget *targets,
                              constant VMParams &params,
                              device VMResult *results,
                              device atomic_uint *counter,
                              uint kindA, uint kindB,
                              thread const uint h[5],
                              uint tid, int offset, uint iteration, uint parity) {
    for (uint t = 0; t < params.targetCount; t++) {
        uint k = targets[t].kind;
        if (k != kindA && k != kindB) continue;
        if (ge160(h, targets[t].lo) && le160(h, targets[t].hi))
            emit(results, counter, params, tid, offset, iteration, t, k, parity, h);
    }
}

// ===========================================================================
// MARK: - Main search kernel
// ===========================================================================

// The batch-inversion scratch lives in an explicitly managed device buffer
// rather than a thread-private array.
//
// A `FE pfx[65]` local is 2 KB per thread; Metal places that in device memory
// laid out per thread, so a 32-wide SIMD group reading pfx[i] touches 32
// locations 2 KB apart — 32 separate cache lines for one logical access. Laid
// out as [slot][limb][thread] instead, the same access is 32 consecutive
// 32-bit words: one coalesced transaction. Same arithmetic, a fraction of the
// memory traffic.
#define PFX_AT(slot, limb) scratch[(((slot) * 8u + (limb)) * nThreads) + tid]

kernel void vanity_search(constant VMParams        &params   [[buffer(0)]],
                          device const VMTarget    *targets  [[buffer(1)]],
                          device uint              *startX   [[buffer(2)]],
                          device uint              *startY   [[buffer(3)]],
                          device const uint        *gTabX    [[buffer(4)]],
                          device const uint        *gTabY    [[buffer(5)]],
                          device const uint        *jumpPt   [[buffer(6)]],
                          device VMResult          *results  [[buffer(7)]],
                          device atomic_uint       *counter  [[buffer(8)]],
                          device uint              *scratch  [[buffer(9)]],
                          uint tid [[thread_position_in_grid]])
{
    if (tid >= params.threadCount) return;

    FE px, py;
    for (uint i = 0; i < 8; i++) {
        px.d[i] = startX[tid * 8 + i];
        py.d[i] = startY[tid * 8 + i];
    }

    FE jx, jy;
    for (uint i = 0; i < 8; i++) { jx.d[i] = jumpPt[i]; jy.d[i] = jumpPt[8 + i]; }

    uint paths = params.hashPaths;
    uint nThreads = params.threadCount;

    for (uint iter = 0; iter < params.batchIterations; iter++) {
        uint iteration = params.iterationBase + iter;

        // ---- forward pass: running products of the 65 dx values ------------
        FE run = fe_zero(); run.d[0] = 1u;
        for (uint i = 0; i < PFX_SLOTS; i++) {
            FE gx;
            if (i < GRP_HALF) {
                for (uint k = 0; k < 8; k++) gx.d[k] = gTabX[i * 8 + k];
            } else {
                gx = jx;
            }
            FE dx = fe_sub(gx, px);
            if (fe_is_zero(dx)) dx.d[0] = 1u;   // degenerate, astronomically unlikely
            run = fe_mul(run, dx);
            for (uint k = 0; k < 8; k++) PFX_AT(i, k) = run.d[k];
        }

        FE inv = fe_inv(run);
        FE nextX = px, nextY = py;

        // ---- backward pass: recover each 1/dx and use it immediately -------
        for (int i = (int)PFX_SLOTS - 1; i >= 0; i--) {
            FE gx, gy;
            bool isJump = ((uint)i == GRP_HALF);
            if (isJump) {
                gx = jx; gy = jy;
            } else {
                for (uint k = 0; k < 8; k++) {
                    gx.d[k] = gTabX[(uint)i * 8 + k];
                    gy.d[k] = gTabY[(uint)i * 8 + k];
                }
            }
            FE dx = fe_sub(gx, px);
            if (fe_is_zero(dx)) dx.d[0] = 1u;

            FE s;
            if (i == 0) {
                s = inv;
            } else {
                FE prev;
                uint slot = (uint)i - 1u;
                for (uint k = 0; k < 8; k++) prev.d[k] = PFX_AT(slot, k);
                s = fe_mul(inv, prev);
            }
            if (i > 0) inv = fe_mul(inv, dx);

            if (isJump) {
                // Advance the walk by (2*GRP_HALF + 1) * G.
                FE lam = fe_mul(fe_sub(gy, py), s);
                FE nx = fe_sub(fe_sub(fe_sqr(lam), px), gx);
                FE ny = fe_sub(fe_mul(lam, fe_sub(px, nx)), py);
                nextX = nx; nextY = ny;
                continue;
            }

            int mag = i + 1;   // gTab[i] == (i+1) * G

            for (uint sign = 0; sign < 2; sign++) {
                FE qy = (sign == 0) ? gy : fe_neg(gy);
                FE lam = fe_mul(fe_sub(qy, py), s);
                FE rx = fe_sub(fe_sub(fe_sqr(lam), px), gx);
                FE ry = fe_sub(fe_mul(lam, fe_sub(px, rx)), py);
                int offset = (sign == 0) ? mag : -mag;

                uint ex[8], ey[8];
                fe_to_be_words(rx, ex);
                fe_to_be_words(ry, ey);
                uint parity = ry.d[0] & 1u;

                uint hc[5];
                if ((paths & (PATH_H160_C | PATH_P2SH)) != 0u) {
                    hash160_compressed(ex, parity, hc);
                    if ((paths & PATH_H160_C) != 0u)
                        match_kind(targets, params, results, counter,
                                   KIND_P2PKH_C, KIND_BECH32, hc, tid, offset, iteration, parity);
                    if ((paths & PATH_P2SH) != 0u) {
                        uint hs[5];
                        hash160_p2sh(hc, hs);
                        match_kind(targets, params, results, counter,
                                   KIND_P2SH, KIND_P2SH, hs, tid, offset, iteration, parity);
                    }
                }
                if ((paths & PATH_H160_U) != 0u) {
                    uint hu[5];
                    hash160_uncompressed(ex, ey, hu);
                    match_kind(targets, params, results, counter,
                               KIND_P2PKH_U, KIND_P2PKH_U, hu, tid, offset, iteration, parity);
                }
                if ((paths & PATH_ETH) != 0u) {
                    uint he[5];
                    eth_address(ex, ey, he);
                    match_kind(targets, params, results, counter,
                               KIND_ETH, KIND_ETH, he, tid, offset, iteration, parity);
                }
            }
        }

        // ---- the centre point itself (offset 0) ----------------------------
        {
            uint ex[8], ey[8];
            fe_to_be_words(px, ex);
            fe_to_be_words(py, ey);
            uint parity = py.d[0] & 1u;
            uint hc[5];
            if ((paths & (PATH_H160_C | PATH_P2SH)) != 0u) {
                hash160_compressed(ex, parity, hc);
                if ((paths & PATH_H160_C) != 0u)
                    match_kind(targets, params, results, counter,
                               KIND_P2PKH_C, KIND_BECH32, hc, tid, 0, iteration, parity);
                if ((paths & PATH_P2SH) != 0u) {
                    uint hs[5];
                    hash160_p2sh(hc, hs);
                    match_kind(targets, params, results, counter,
                               KIND_P2SH, KIND_P2SH, hs, tid, 0, iteration, parity);
                }
            }
            if ((paths & PATH_H160_U) != 0u) {
                uint hu[5];
                hash160_uncompressed(ex, ey, hu);
                match_kind(targets, params, results, counter,
                           KIND_P2PKH_U, KIND_P2PKH_U, hu, tid, 0, iteration, parity);
            }
            if ((paths & PATH_ETH) != 0u) {
                uint he[5];
                eth_address(ex, ey, he);
                match_kind(targets, params, results, counter,
                           KIND_ETH, KIND_ETH, he, tid, 0, iteration, parity);
            }
        }

        px = nextX;
        py = nextY;
    }

    for (uint i = 0; i < 8; i++) {
        startX[tid * 8 + i] = px.d[i];
        startY[tid * 8 + i] = py.d[i];
    }
}

// ===========================================================================
// MARK: - Table dump kernel (diagnostics)
//
// Echoes one G-table entry and the jump point straight back, so the host can
// confirm the table arrived intact rather than inferring it from results.
// ===========================================================================

kernel void vanity_dump(device const uint *gTabX  [[buffer(0)]],
                        device const uint *gTabY  [[buffer(1)]],
                        device const uint *jumpPt [[buffer(2)]],
                        constant uint    &index   [[buffer(3)]],
                        device uint      *out     [[buffer(4)]],
                        uint tid [[thread_position_in_grid]])
{
    if (tid != 0) return;
    for (uint k = 0; k < 8; k++) {
        out[k]      = gTabX[index * 8 + k];
        out[8 + k]  = gTabY[index * 8 + k];
        out[16 + k] = jumpPt[k];
        out[24 + k] = jumpPt[8 + k];
    }
}

// ===========================================================================
// MARK: - Self-test kernel
//
// Runs known-answer tests for every primitive on the GPU itself.  The app runs
// this once at start-up; if any lane reports a mismatch the Metal engine is
// disabled and the CPU engine takes over automatically.
// ===========================================================================

kernel void vanity_selftest(device uint *out [[buffer(0)]],
                            uint tid [[thread_position_in_grid]])
{
    if (tid != 0) return;
    uint fails = 0u;

    // --- field arithmetic: (p-1) + 2 == 1 -------------------------------
    {
        FE a; for (uint i = 0; i < 8; i++) a.d[i] = P_LIMBS[i];
        a.d[0] -= 1u;                       // p - 1
        FE b = fe_zero(); b.d[0] = 2u;
        FE c = fe_add(a, b);
        if (!(c.d[0] == 1u && c.d[1] == 0u && c.d[7] == 0u)) fails |= 1u;
    }
    // --- multiplication and inversion round-trip -------------------------
    {
        FE a = fe_zero();
        a.d[0] = 0x12345678u; a.d[1] = 0x9ABCDEF0u; a.d[3] = 0xDEADBEEFu; a.d[7] = 0x00000042u;
        FE inv = fe_inv(a);
        FE one = fe_mul(a, inv);
        if (!(one.d[0] == 1u && one.d[1] == 0u && one.d[2] == 0u && one.d[3] == 0u &&
              one.d[4] == 0u && one.d[5] == 0u && one.d[6] == 0u && one.d[7] == 0u)) fails |= 2u;
    }
    // --- SHA-256("abc") --------------------------------------------------
    {
        uint h[8]; sha256_init(h);
        uint w[16];
        w[0] = 0x61626380u;
        for (uint i = 1; i < 15; i++) w[i] = 0u;
        w[15] = 24u;
        sha256_block(h, w);
        if (h[0] != 0xba7816bfu || h[7] != 0xf20015adu) fails |= 4u;
    }
    // --- RIPEMD-160 of 32 zero bytes -------------------------------------
    {
        uint z[8]; for (uint i = 0; i < 8; i++) z[i] = 0u;
        uint o[5]; ripemd160_32(z, o);
        // ripemd160(00 * 32) = d1a70126ff7a149ca6f9b638db084480440ff842
        if (o[0] != 0xd1a70126u || o[4] != 0x440ff842u) fails |= 8u;
    }
    // --- Keccak-256 of 64 zero bytes -------------------------------------
    {
        ulong a[25]; for (uint i = 0; i < 25; i++) a[i] = 0UL;
        a[8] ^= 0x01UL;
        a[16] ^= 0x8000000000000000UL;
        keccak_f(a);
        // keccak256(00 * 64) begins ad3228b676f7d3cd...
        uint w0 = bswap32(((uint)(a[0] & 0xFFFFFFFFUL)));
        if (w0 != 0xad3228b6u) fails |= 16u;
    }

    // --- the whole public-key -> address path, using the generator -------
    // The primitives can each be perfect while the bytes fed to them are in
    // the wrong order; only an end-to-end vector catches that.
    {
        FE gx, gy;
        gx.d[0] = 0x16F81798u; gx.d[1] = 0x59F2815Bu; gx.d[2] = 0x2DCE28D9u; gx.d[3] = 0x029BFCDBu;
        gx.d[4] = 0xCE870B07u; gx.d[5] = 0x55A06295u; gx.d[6] = 0xF9DCBBACu; gx.d[7] = 0x79BE667Eu;
        gy.d[0] = 0xFB10D4B8u; gy.d[1] = 0x9C47D08Fu; gy.d[2] = 0xA6855419u; gy.d[3] = 0xFD17B448u;
        gy.d[4] = 0x0E1108A8u; gy.d[5] = 0x5DA4FBFCu; gy.d[6] = 0x26A3C465u; gy.d[7] = 0x483ADA77u;

        uint ex[8], ey[8];
        fe_to_be_words(gx, ex);
        fe_to_be_words(gy, ey);

        // hash160(compressed G) = 751e76e8199196d454941c45d1b3a323f1433bd6
        uint hc[5];
        hash160_compressed(ex, gy.d[0] & 1u, hc);
        if (hc[0] != 0x751e76e8u || hc[4] != 0xf1433bd6u) fails |= 32u;

        // ethereum address for private key 1 = 7e5f4552091a69125d5dfcb7b8c2659029395bdf
        uint he[5];
        eth_address(ex, ey, he);
        if (he[0] != 0x7e5f4552u || he[4] != 0x29395bdfu) fails |= 64u;
    }

    out[0] = fails;
    out[1] = GRP_SIZE;
}
