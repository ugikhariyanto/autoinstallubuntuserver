#!/usr/bin/env python3
"""Membuat hash password SHA-512 crypt(3) untuk autoinstall (identity.password).

Contoh:
    python hash-password.py                # tanya password (input tersembunyi)
    python hash-password.py "passwordku"   # langsung dari argumen

Hasilnya (string yang diawali "$6$...") tempel ke autoinstall.yaml pada
key identity.password, lalu rebuild ISO dengan build-iso.ps1.
"""
import getpass
import hashlib
import secrets
import sys

ITOA64 = "./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

PERM = [
    (0, 21, 42), (22, 43, 1), (44, 2, 23), (3, 24, 45), (25, 46, 4),
    (47, 5, 26), (6, 27, 48), (28, 49, 7), (50, 8, 29), (9, 30, 51),
    (31, 52, 10), (53, 11, 32), (12, 33, 54), (34, 55, 13), (56, 14, 35),
    (15, 36, 57), (37, 58, 16), (59, 17, 38), (18, 39, 60), (40, 61, 19),
    (62, 20, 41),
]


def _b64_24bit(w, x, y, n):
    w = (w << 16) | (x << 8) | y
    out = []
    for _ in range(n):
        out.append(ITOA64[w & 0x3F])
        w >>= 6
    return "".join(out)


def sha512_crypt(password, salt=None, rounds=5000):
    pw = password.encode()
    if salt is None:
        salt = "".join(secrets.choice(ITOA64) for _ in range(16))
    salt = salt[:16]
    s = salt.encode()

    b = hashlib.sha512(pw + s + pw).digest()

    a = hashlib.sha512()
    a.update(pw)
    a.update(s)
    n = len(pw)
    a.update(b * (n // 64) + b[: n % 64])
    i = n
    while i:
        a.update(b if (i & 1) else pw)
        i >>= 1
    alt = a.digest()

    dp = hashlib.sha512(pw * n).digest()
    p = dp * (n // 64) + dp[: n % 64]

    ds = hashlib.sha512(s * (16 + alt[0])).digest()
    ss = ds * (len(s) // 64) + ds[: len(s) % 64]

    c = alt
    for i in range(rounds):
        h = hashlib.sha512()
        h.update(p if (i & 1) else c)
        if i % 3:
            h.update(ss)
        if i % 7:
            h.update(p)
        h.update(c if (i & 1) else p)
        c = h.digest()

    enc = "".join(_b64_24bit(c[x], c[y], c[z], 4) for x, y, z in PERM)
    enc += _b64_24bit(0, 0, c[63], 2)
    return "$6$%s$%s" % (salt, enc)


if __name__ == "__main__":
    # self-test terhadap vektor uji resmi SHA-crypt
    assert sha512_crypt("Hello world!", "saltstring") == (
        "$6$saltstring$svn8UoSVapNtMuq1ukKS4tPQd8iKwSMHWjl/O817G3uBnIFNjnQJuesI68u4"
        "OTLiBFdcbYEdFCoEOfaS35inz1"
    )

    if len(sys.argv) > 1:
        pw = sys.argv[1]
    else:
        pw = getpass.getpass("Password baru: ")
        if pw != getpass.getpass("Ulangi password: "):
            sys.exit("Password tidak sama.")

    print()
    print(sha512_crypt(pw))
