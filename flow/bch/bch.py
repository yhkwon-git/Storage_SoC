#!/usr/bin/env python3
"""Reference model of the NAND channels' BCH code (step 3-3).

Binary BCH over GF(2^13), primitive polynomial x^13 + x^4 + x^3 + x + 1,
correcting t = 8 bit errors in a codeword of 516 message bytes (a 512-byte
sector and 4 bytes of metadata) and 13 parity bytes: k = 4128, n = 4232 bits,
shortened from the full length 8191.

Bit order. A codeword is sent as bytes, each byte bit 7 first. Stream bit q
(q = 8 x byte + 7 - bit) is the coefficient of x^(n - 1 - q): the first bit
sent has the highest degree, the parity is the last 104 bits.

  encode(msg)            parity bytes of a 516-byte message (systematic)
  syndromes(cw)          S_1 .. S_2t of a received codeword
  berlekamp_massey(S)    error locator Lambda(x), coefficients lambda_0..lambda_L
  chien(lam, n)          stream bits q where Lambda(alpha^-(n-1-q)) = 0
  decode(cw)             (corrected codeword, bit positions corrected) or
                         (None, None) when the errors are past correcting

Run as a script it checks itself on random codewords (python bch.py --self).
"""

import argparse
import random

M = 13
POLY = (1 << 13) | (1 << 4) | (1 << 3) | (1 << 1) | 1     # x^13 + x^4 + x^3 + x + 1
Q = (1 << M) - 1                                           # 8191, the multiplicative order
T = 8
K_BYTES = 516
P_BYTES = 13
N_BYTES = K_BYTES + P_BYTES
K = 8 * K_BYTES
N = 8 * N_BYTES
R = M * T                                                  # parity bits, 104

# ---------------------------------------------------------------------------
# GF(2^13)
# ---------------------------------------------------------------------------
EXP = [0] * (2 * Q)
LOG = [0] * (Q + 1)
_x = 1
for _i in range(Q):
    EXP[_i] = _x
    LOG[_x] = _i
    _x <<= 1
    if _x & (1 << M):
        _x ^= POLY
for _i in range(Q, 2 * Q):
    EXP[_i] = EXP[_i - Q]
assert _x == 1, "the polynomial is not primitive"
assert len(set(EXP[:Q])) == Q, "the polynomial is not primitive"


def gmul(a, b):
    if a == 0 or b == 0:
        return 0
    return EXP[LOG[a] + LOG[b]]


def ginv(a):
    assert a != 0
    return EXP[(Q - LOG[a]) % Q]


def apow(e):
    """alpha^e for any integer e."""
    return EXP[e % Q]


# ---------------------------------------------------------------------------
# Generator polynomial: the product of the minimal polynomials of
# alpha^1, alpha^3, ..., alpha^(2t-1). Polynomials over GF(2) are ints, bit i
# the coefficient of x^i.
# ---------------------------------------------------------------------------
def coset(j):
    c, e = [], j % Q
    while e not in c:
        c.append(e)
        e = (2 * e) % Q
    return c


def minpoly(j):
    """Minimal polynomial of alpha^j over GF(2), as an int."""
    p = [1]                                                # coefficients in GF(2^13), lowest first
    for e in coset(j):
        root = apow(e)
        q = [0] * (len(p) + 1)
        for i, c in enumerate(p):                          # p(x) * (x + root)
            q[i + 1] ^= c
            q[i] ^= gmul(c, root)
        p = q
    assert all(c in (0, 1) for c in p)
    return sum(c << i for i, c in enumerate(p))


def pmul2(a, b):
    """Product of two GF(2) polynomials."""
    r = 0
    while b:
        if b & 1:
            r ^= a
        a <<= 1
        b >>= 1
    return r


MINPOLYS = []
G = 1
for _j in range(1, 2 * T, 2):
    _m = minpoly(_j)
    if _m not in MINPOLYS:
        MINPOLYS.append(_m)
        G = pmul2(G, _m)
assert G.bit_length() - 1 == R, "g(x) has degree %d" % (G.bit_length() - 1)
G_LOW = G & ((1 << R) - 1)                                 # g(x) without x^104


# ---------------------------------------------------------------------------
# Codec
# ---------------------------------------------------------------------------
def bits_of(data):
    """Stream bits of bytes, each byte bit 7 first."""
    for b in data:
        for i in range(7, -1, -1):
            yield (b >> i) & 1


def encode(msg):
    """The 13 parity bytes of a 516-byte message: the remainder of
    m(x) x^104 divided by g(x), shifted in a bit at a time as an LFSR does."""
    assert len(msg) == K_BYTES
    r = 0
    for u in bits_of(msg):
        fb = ((r >> (R - 1)) & 1) ^ u
        r = (r << 1) & ((1 << R) - 1)
        if fb:
            r ^= G_LOW
    return bytes((r >> (R - 8 - 8 * j)) & 0xFF for j in range(P_BYTES))


def syndromes(cw):
    """S_1 .. S_2t (index 0 unused) of a received codeword, by Horner over its bits."""
    assert len(cw) == N_BYTES
    s = [0] * (2 * T + 1)
    for j in range(1, 2 * T + 1, 2):
        a = apow(j)
        v = 0
        for c in bits_of(cw):
            v = gmul(v, a) ^ c
        s[j] = v
    for j in range(2, 2 * T + 1, 2):
        s[j] = gmul(s[j // 2], s[j // 2])
    return s


def berlekamp_massey(s):
    """Error locator Lambda(x) = 1 + lambda_1 x + ... from S_1 .. S_2t."""
    c, b = [1], [1]
    length, shift, bd = 0, 1, 1
    for k in range(2 * T):
        d = s[k + 1]
        for i in range(1, length + 1):
            if i < len(c):
                d ^= gmul(c[i], s[k + 1 - i])
        if d == 0:
            shift += 1
            continue
        coef = gmul(d, ginv(bd))
        nc = c + [0] * max(0, len(b) + shift - len(c))
        for i, bi in enumerate(b):
            nc[i + shift] ^= gmul(coef, bi)
        if 2 * length <= k:
            b, bd, length, shift = c, d, k + 1 - length, 1
        else:
            shift += 1
        c = nc
    while len(c) > 1 and c[-1] == 0:
        c.pop()
    return c, length


def chien(lam, n=N):
    """Stream bits q (0 .. n-1) whose degree d = n - 1 - q makes alpha^d an
    error locator: Lambda(alpha^-d) = 0."""
    out = []
    for q in range(n):
        x = apow(-(n - 1 - q))
        v, xp = 0, 1
        for c in lam:
            v ^= gmul(c, xp)
            xp = gmul(xp, x)
        if v == 0:
            out.append(q)
    return out


def decode(cw):
    s = syndromes(cw)
    if not any(s[1:]):
        return bytes(cw), []
    lam, length = berlekamp_massey(s)
    if len(lam) - 1 != length or length > T:
        return None, None
    qs = chien(lam)
    if len(qs) != length:
        return None, None
    out = bytearray(cw)
    for q in qs:
        out[q // 8] ^= 0x80 >> (q % 8)
    return bytes(out), qs


def sibm(s):
    """The decoder's Berlekamp-Massey: inversionless, binary, t iterations.

    Iteration k takes the discrepancy d (the coefficient of x^(2k+1) in
    sigma(x) S(x)), then sigma <- gamma sigma + d x tau. If d != 0 and
    D <= k: tau <- x sigma (the old one), gamma <- d, D <- 2k + 1 - D;
    otherwise tau <- x^2 tau. sigma is Lambda times gamma's product, with
    the same roots; D is the number of errors it locates."""
    sig = [1] + [0] * T
    tau = [1] + [0] * T
    gam, dd = 1, 0
    for k in range(T):
        d = 0
        for i in range(T + 1):
            j = 2 * k + 1 - i
            if j >= 1:
                d ^= gmul(sig[i], s[j])
        new = [gmul(gam, sig[i]) ^ (gmul(d, tau[i - 1]) if i else 0) for i in range(T + 1)]
        if d != 0 and dd <= k:
            tau = [0] + sig[:T]
            gam, dd = d, 2 * k + 1 - dd
        else:
            tau = [0, 0] + tau[:T - 1]
        sig = new
    return sig, dd


def chien8(sig, n=N):
    """The decoder's Chien search, eight stream bits a clock: R_i starts at
    sigma_i alpha^(-i(n-1)) and is multiplied by alpha^(8i) after each clock;
    bit m of a clock is an error when sum_i R_i alpha^(i m) = 0."""
    r = [gmul(sig[i], apow(-i * (n - 1))) for i in range(T + 1)]
    out = []
    for c in range((n + 7) // 8):
        for m in range(8):
            v = 0
            for i in range(T + 1):
                v ^= gmul(r[i], apow(i * m))
            if 8 * c + m < n and v == 0:
                out.append(8 * c + m)
        r = [gmul(r[i], apow(8 * i)) for i in range(T + 1)]
    return out


def decode_hw(cw):
    """decode() as the hardware does it: sibm, chien8, and the rule that the
    errors are past correcting unless sigma's degree, D and the roots found
    agree."""
    s = syndromes(cw)
    if not any(s[1:]):
        return bytes(cw), []
    sig, dd = sibm(s)
    deg = max(i for i in range(T + 1) if sig[i] or i == 0)
    qs = chien8(sig)
    if dd > T or deg != dd or len(qs) != dd:
        return None, None
    return flip(cw, qs), qs


def par_mask():
    """The mask the NAND channels XOR into the parity, both ways: the parity
    of an all-FFh message XOR FFh. An erased codeword (all FFh) then reads as
    a valid one, and an erased page with a few bits flipped is corrected back
    to FFh."""
    return bytes(p ^ 0xFF for p in encode(bytes([0xFF] * K_BYTES)))


def flip(cw, qs):
    out = bytearray(cw)
    for q in qs:
        out[q // 8] ^= 0x80 >> (q % 8)
    return bytes(out)


# ---------------------------------------------------------------------------
# Self-check
# ---------------------------------------------------------------------------
def self_check(n_words, seed):
    rnd = random.Random(seed)
    fixed = missed = detected = 0
    for w in range(n_words):
        msg = bytes(rnd.getrandbits(8) for _ in range(K_BYTES))
        cw = msg + encode(msg)
        assert not any(syndromes(cw)[1:]), "a codeword with nonzero syndromes"
        ne = w % (T + 3)                                   # 0 .. t + 2 errors
        qs = sorted(rnd.sample(range(N), ne))
        got, where = decode(flip(cw, qs))
        hw, hwq = decode_hw(flip(cw, qs))
        same = (hw is None) == (got is None) and (hw is None or (hw == got and sorted(hwq) == sorted(where)))
        assert same, "word %d: the hardware form disagrees" % w
        if ne <= T:
            assert got == cw and sorted(where) == qs, "word %d: %d errors not corrected" % (w, ne)
            fixed += 1
        elif got is None:
            detected += 1
        else:
            missed += 1                                    # decoded to another codeword
    print("[BCH] t=%d n=%d k=%d: %d words with 0 to %d errors corrected; past t, %d detected and %d miscorrected"
          % (T, N, K, fixed, T, detected, missed))


VEC_BYTES = 3 + K_BYTES + P_BYTES + N_BYTES + K_BYTES


def vectors(n_vec, seed):
    """Test vectors for tb_bch, each VEC_BYTES bytes: errors placed, whether
    the hardware form finds them past correcting, the bits it corrects, the
    message, its parity, the codeword as received, and the message it
    decodes to. Directed cases first, then random ones with 0 to t + 3
    errors."""
    rnd = random.Random(seed)
    cases = []

    def add(msg, qs, rx=None):
        cw = msg + encode(msg)
        if rx is None:
            rx = flip(cw, qs)
        got, where = decode_hw(rx)
        unc = got is None
        out = rx[:K_BYTES] if unc else got[:K_BYTES]
        cases.append(bytes([len(qs) & 0xFF, int(unc), 0 if unc else len(where)]) + msg + cw[K_BYTES:] + rx + out)

    rmsg = lambda: bytes(rnd.getrandbits(8) for _ in range(K_BYTES))
    add(rmsg(), [])
    add(bytes(K_BYTES), [])
    add(bytes([0xFF] * K_BYTES), [])
    add(rmsg(), [0])                                       # the first bit sent
    add(rmsg(), [N - 1])                                   # the last parity bit
    add(rmsg(), list(range(8)))                            # a whole byte
    add(rmsg(), list(range(8 * 100 + 4, 8 * 100 + 12)))    # 8 bits across two bytes
    add(rmsg(), sorted(rnd.sample(range(K, N), T)))        # t errors in the parity
    add(rmsg(), sorted(rnd.sample(range(K), T)))           # t in the message
    add(rmsg(), [8 * j for j in range(T)])                 # t, one in each of 8 bytes
    add(rmsg(), sorted(rnd.sample(range(N), T + 1)))       # t + 1
    add(rmsg(), [], bytes([0xFF] * N_BYTES))               # an erased codeword

    def zero_s1(ne):
        """ne error positions whose locators sum to 0, so that S_1 = 0: the
        first discrepancy is 0 and Berlekamp-Massey takes its x^2 tau step
        before any other."""
        while True:
            qs = rnd.sample(range(N), ne - 1)
            x = 0
            for q in qs:
                x ^= apow(N - 1 - q)
            if x == 0 or LOG[x] > N - 1 or (N - 1 - LOG[x]) in qs:
                continue
            return sorted(qs + [N - 1 - LOG[x]])

    for ne in range(3, T + 3):
        for _ in range(2):
            add(rmsg(), zero_s1(ne))
    while len(cases) < n_vec:
        ne = rnd.randint(0, T + 3)
        add(rmsg(), sorted(rnd.sample(range(N), ne)))
    return cases


def sv_pkg():
    """rtl/ecc/bch_pkg.sv: the code's constants for the RTL."""
    h13 = lambda v: "13'h%04X" % v
    lines = [
        "// Generated by flow/bch/bch.py --pkg; do not edit. The BCH code of the NAND",
        "// channels (step 3-3): binary, GF(2^13), t = %d, %d message bytes (a 512-byte" % (T, K_BYTES),
        "// sector and 4 bytes of metadata) and %d parity bytes. Bit order and the" % P_BYTES,
        "// algorithms are described in flow/bch/bch.py.",
        "package bch_pkg;",
        "",
        "  // Not every constant is used by every block.",
        "  /* verilator lint_off UNUSEDPARAM */",
        "  localparam int M       = %d;" % M,
        "  localparam int T       = %d;" % T,
        "  localparam int K_BYTES = %d;" % K_BYTES,
        "  localparam int P_BYTES = %d;" % P_BYTES,
        "  localparam int N_BYTES = %d;" % N_BYTES,
        "  localparam int N       = %d;" % N,
        "  localparam int R       = %d;" % R,
        "",
        "  // p(x) = x^13 + x^4 + x^3 + x + 1 without x^13; g(x) without x^104",
        "  localparam logic [12:0]  POLY = %s;" % h13(POLY & Q),
        "  localparam logic [103:0] G    = 104'h%026X;" % G_LOW,
        "",
        "  // Syndromes S_1, S_3, ..., S_15: alpha^j and alpha^(8j)",
        "  localparam logic [12:0] SYN_A  [8] = '{%s};" % ", ".join(h13(apow(2 * i + 1)) for i in range(T)),
        "  localparam logic [12:0] SYN_A8 [8] = '{%s};" % ", ".join(h13(apow(8 * (2 * i + 1))) for i in range(T)),
        "",
        "  // XORed into the parity as it is programmed and read, so that an erased",
        "  // codeword (all FFh) is a valid one",
        "  localparam logic [7:0] PAR_MASK [%d] = '{%s};" % (P_BYTES, ", ".join("8'h%02X" % b for b in par_mask())),
        "",
        "  // Squaring is linear: x^2 = sum of x[i] alpha^(2i)",
        "  localparam logic [12:0] SQ [13] = '{%s};" % ", ".join(h13(apow(2 * i)) for i in range(M)),
        "",
        "  // Chien search: R_i starts at sigma_i alpha^(-i(N-1)), steps by alpha^(8i);",
        "  // bit m of a clock takes alpha^(i m)",
        "  localparam logic [12:0] CH_INIT [%d] = '{%s};" % (T + 1, ", ".join(h13(apow(-i * (N - 1))) for i in range(T + 1))),
        "  localparam logic [12:0] CH_STEP [%d] = '{%s};" % (T + 1, ", ".join(h13(apow(8 * i)) for i in range(T + 1))),
        "  localparam logic [12:0] CH_POS [8][%d] = '{" % (T + 1),
    ]
    rows = ["    '{%s}" % ", ".join(h13(apow(i * m)) for i in range(T + 1)) for m in range(8)]
    lines.append(",\n".join(rows))
    lines += [
        "  };",
        "  /* verilator lint_on UNUSEDPARAM */",
        "",
        "  // a * b in GF(2^13); with b a constant it reduces to XORs.",
        "  function automatic logic [12:0] gf_mul(logic [12:0] a, logic [12:0] b);",
        "    logic [12:0] r;",
        "    r = 13'd0;",
        "    for (int i = 12; i >= 0; i--) begin",
        "      r = {r[11:0], 1'b0} ^ (r[12] ? POLY : 13'd0);",
        "      if (b[i]) r = r ^ a;",
        "    end",
        "    return r;",
        "  endfunction",
        "",
        "  function automatic logic [12:0] gf_sq(logic [12:0] a);",
        "    logic [12:0] r;",
        "    r = 13'd0;",
        "    for (int i = 0; i < 13; i++) if (a[i]) r = r ^ SQ[i];",
        "    return r;",
        "  endfunction",
        "endpackage : bch_pkg",
        "",
    ]
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--self", action="store_true", help="check the codec on random codewords")
    ap.add_argument("--words", type=int, default=220)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--pkg", metavar="FILE", help="write the RTL package (rtl/ecc/bch_pkg.sv)")
    ap.add_argument("--vectors", metavar="FILE", help="write test vectors for tb_bch, one hex byte a line")
    ap.add_argument("--nv", type=int, default=300, help="number of vectors")
    a = ap.parse_args()
    print("[BCH] g(x) = 0x%X (degree %d), minimal polynomials %s"
          % (G, G.bit_length() - 1, ", ".join("0x%X" % m for m in MINPOLYS)))
    if a.self:
        self_check(a.words, a.seed)
    if a.pkg:
        with open(a.pkg, "w", newline="\n") as f:
            f.write(sv_pkg())
    if a.vectors:
        vs = vectors(a.nv, a.seed)
        with open(a.vectors, "w", newline="\n") as f:
            for v in vs:
                f.write("\n".join("%02x" % b for b in v))
                f.write("\n")
        kinds = {}
        for v in vs:
            key = ("past t" if v[1] else "corrected") if v[0] or v[1] else "clean"
            kinds[key] = kinds.get(key, 0) + 1
        print("[BCH] %d vectors of %d bytes (seed %d): %s"
              % (len(vs), VEC_BYTES, a.seed, ", ".join("%d %s" % (n, k) for k, n in sorted(kinds.items()))))


if __name__ == "__main__":
    main()
