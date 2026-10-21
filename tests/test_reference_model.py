"""
Pytest suite for VanityMetal's GPU reference model.

VanityMetal is a macOS/Metal app: the Swift XCTest target and the GPU
cross-check only build on Apple hardware. But the kernel maths has a pure-Python
reference model (Tools/verify_model.py) and an address-range model
(Tools/verify_targets.py) that reproduce the GPU algorithms limb-for-limb and
check them against independent ground truth. Those run anywhere Python runs.

This module exposes that reference model as a recognized, collectable test suite
so `pytest` can build and run it in any Linux sandbox - no Xcode, no GPU, no
network. The granular tests below check the curve and field arithmetic against
Python's own big integers, the hashes against published vectors, and address
encoding against a well-known external anchor; the final two run the complete
committed verifiers end to end.
"""
import hashlib
import sys
from pathlib import Path

# The reference models live in Tools/ next to this repo's root.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "Tools"))

import verify_model as vm          # noqa: E402
import verify_targets as vt        # noqa: E402


# --------------------------------------------------------------------------- #
# secp256k1 curve
# --------------------------------------------------------------------------- #

def _on_curve(x, y):
    return (y * y - (x * x * x + 7)) % vm.P == 0


def test_generator_is_g():
    assert vm.ec_mul(1) == (vm.GX, vm.GY)


def test_scalar_mul_is_additive():
    # 5G == 2G + 3G, 7G == 3G + 4G — the group law must be consistent.
    assert vm.ec_mul(5) == vm.ec_add(vm.ec_mul(2), vm.ec_mul(3))
    assert vm.ec_mul(7) == vm.ec_add(vm.ec_mul(3), vm.ec_mul(4))


def test_scalar_multiples_lie_on_curve():
    for k in (1, 2, 3, 7, 12345, 0xDEADBEEF, vm.N - 1):
        x, y = vm.ec_mul(k)
        assert _on_curve(x, y), f"k={k} off curve"


# --------------------------------------------------------------------------- #
# field arithmetic (mirrors fe_* kernel routines)
# --------------------------------------------------------------------------- #

def test_field_mul_matches_bigint():
    for a, b in ((2, 3), (vm.P - 1, vm.P - 1), (0x1234567, 0x89ABCDEF), (vm.GX, vm.GY)):
        assert vm.fe_mul_model(a, b) == (a * b) % vm.P


def test_field_inverse_is_reciprocal():
    for a in (1, 2, 3, vm.GX, vm.P - 1):
        inv = vm.fe_inv_chain(a)
        assert (a * inv) % vm.P == 1


# --------------------------------------------------------------------------- #
# hashes
# --------------------------------------------------------------------------- #

def test_ripemd160_published_vectors():
    assert vm.ripemd160(b"").hex() == "9c1185a5c5e9fc54612808977ee8f548b2258d31"
    assert vm.ripemd160(b"abc").hex() == "8eb208f7e05d987a9b044a8e98c6b087f15a0bfc"
    assert vm.ripemd160(b"message digest").hex() == "5d0689ef49d2fae572b881b123a85ffa21595f36"


def test_ripemd160_matches_openssl_when_available():
    try:
        ref = hashlib.new("ripemd160")
    except (ValueError, TypeError):
        import pytest
        pytest.skip("OpenSSL RIPEMD-160 not available in this build")
    ref.update(b"The quick brown fox jumps over the lazy dog")
    assert vm.ripemd160(b"The quick brown fox jumps over the lazy dog").hex() == ref.hexdigest()


# --------------------------------------------------------------------------- #
# address encoding
# --------------------------------------------------------------------------- #

def test_known_p2pkh_for_privkey_one():
    # The compressed-key P2PKH address for private key 1 is a widely published
    # secp256k1 test vector.
    assert vt.addresses_for(1)["p2pkh"][0] == "1BgGZ9tcN4rm9KBzDn7KprQz87SZ26SAMH"


def test_address_encoders_are_internally_consistent():
    k = 0xC0FFEE0BADCAFE1234567890ABCDEF00112233445566778899AABBCCDDEEFF01
    addrs = vt.addresses_for(k)
    # Every form must be derivable and non-empty, and the three Base58 forms
    # start with the right version prefix.
    assert addrs["p2pkh"][0].startswith("1")
    assert addrs["p2sh"][0].startswith("3")
    assert addrs["bech32"][0].startswith("bc1q")
    assert addrs["eth"][0].startswith("0x") and len(addrs["eth"][0]) == 42


# --------------------------------------------------------------------------- #
# full committed verifiers, end to end
# --------------------------------------------------------------------------- #

def test_full_reference_model_passes():
    assert vm.run_tests() == 0


def test_full_target_ranges_pass():
    assert vt.run_tests() == 0
