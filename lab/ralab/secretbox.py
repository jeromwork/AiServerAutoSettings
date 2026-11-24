"""Шифрование и расшифровка секретов (enc1, AES-256-CBC, HMAC-SHA256)."""

import base64
import hashlib
import hmac
import os

_SBOX = bytes.fromhex(
    "637c777bf26b6fc53001672bfed7ab76ca82c97dfa5947f0add4a2af9ca472c0"
    "b7fd9326363ff7cc34a5e5f171d8311504c723c31896059a071280e2eb27b275"
    "09832c1a1b6e5aa0523bd6b329e32f8453d100ed20fcb15b6acbbe394a4c58cf"
    "d0efaafb434d338545f9027f503c9fa851a3408f929d38f5bcb6da2110fff3d2"
    "cd0c13ec5f974417c4a77e3d645d197360814fdc222a908846eeb814de5e0bdb"
    "e0323a0a4906245cc2d3ac629195e479e7c8376d8dd54ea96c56f4ea657aae08"
    "ba78252e1ca6b4c6e8dd741f4bbd8b8a703eb5664803f60e613557b986c11d9e"
    "e1f8981169d98e949b1e87e9ce5528df8ca1890dbfe6426841992d0fb054bb16"
)

_INV_SBOX = bytearray(256)
for _i, _b in enumerate(_SBOX):
    _INV_SBOX[_b] = _i
_INV_SBOX = bytes(_INV_SBOX)

_RCON = (0x00, 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1B, 0x36)


def _gmul(a: int, b: int) -> int:
    p = 0
    for _ in range(8):
        if b & 1:
            p ^= a
        hi = a & 0x80
        a = (a << 1) & 0xFF
        if hi:
            a ^= 0x1B
        b >>= 1
    return p


_MUL2 = bytes(_gmul(i, 2) for i in range(256))
_MUL3 = bytes(_gmul(i, 3) for i in range(256))
_MUL9 = bytes(_gmul(i, 9) for i in range(256))
_MUL11 = bytes(_gmul(i, 11) for i in range(256))
_MUL13 = bytes(_gmul(i, 13) for i in range(256))
_MUL14 = bytes(_gmul(i, 14) for i in range(256))


def _key_expansion(key: bytes) -> list[bytes]:
    w = [list(key[4 * i : 4 * i + 4]) for i in range(8)]
    for i in range(8, 60):
        temp = list(w[i - 1])
        if i % 8 == 0:
            temp = [temp[1], temp[2], temp[3], temp[0]]
            temp = [_SBOX[b] for b in temp]
            temp[0] ^= _RCON[i // 8]
        elif i % 8 == 4:
            temp = [_SBOX[b] for b in temp]
        w.append([w[i - 8][j] ^ temp[j] for j in range(4)])
    round_keys = []
    for r in range(15):
        rk = bytearray()
        for c in range(4):
            rk.extend(w[r * 4 + c])
        round_keys.append(bytes(rk))
    return round_keys


def _cipher_block(block: bytes, round_keys: list[bytes]) -> bytes:
    s = bytearray(block)
    rk = round_keys[0]
    for i in range(16):
        s[i] ^= rk[i]
    for r in range(1, 14):
        rk = round_keys[r]
        for i in range(16):
            s[i] = _SBOX[s[i]]
        s[1], s[5], s[9], s[13] = s[5], s[9], s[13], s[1]
        s[2], s[6], s[10], s[14] = s[10], s[14], s[2], s[6]
        s[3], s[7], s[11], s[15] = s[15], s[3], s[7], s[11]
        for c in range(4):
            idx = c * 4
            s0, s1, s2, s3 = s[idx], s[idx + 1], s[idx + 2], s[idx + 3]
            s[idx] = _MUL2[s0] ^ _MUL3[s1] ^ s2 ^ s3
            s[idx + 1] = s0 ^ _MUL2[s1] ^ _MUL3[s2] ^ s3
            s[idx + 2] = s0 ^ s1 ^ _MUL2[s2] ^ _MUL3[s3]
            s[idx + 3] = _MUL3[s0] ^ s1 ^ s2 ^ _MUL2[s3]
        for i in range(16):
            s[i] ^= rk[i]

    rk = round_keys[14]
    for i in range(16):
        s[i] = _SBOX[s[i]]
    s[1], s[5], s[9], s[13] = s[5], s[9], s[13], s[1]
    s[2], s[6], s[10], s[14] = s[10], s[14], s[2], s[6]
    s[3], s[7], s[11], s[15] = s[15], s[3], s[7], s[11]
    for i in range(16):
        s[i] ^= rk[i]
    return bytes(s)


def _inv_cipher_block(block: bytes, round_keys: list[bytes]) -> bytes:
    s = bytearray(block)
    rk = round_keys[14]
    for i in range(16):
        s[i] ^= rk[i]
    for r in range(13, 0, -1):
        rk = round_keys[r]
        s[1], s[5], s[9], s[13] = s[13], s[1], s[5], s[9]
        s[2], s[6], s[10], s[14] = s[10], s[14], s[2], s[6]
        s[3], s[7], s[11], s[15] = s[7], s[11], s[15], s[3]
        for i in range(16):
            s[i] = _INV_SBOX[s[i]]
        for i in range(16):
            s[i] ^= rk[i]
        for c in range(4):
            idx = c * 4
            s0, s1, s2, s3 = s[idx], s[idx + 1], s[idx + 2], s[idx + 3]
            s[idx] = _MUL14[s0] ^ _MUL11[s1] ^ _MUL13[s2] ^ _MUL9[s3]
            s[idx + 1] = _MUL9[s0] ^ _MUL14[s1] ^ _MUL11[s2] ^ _MUL13[s3]
            s[idx + 2] = _MUL13[s0] ^ _MUL9[s1] ^ _MUL14[s2] ^ _MUL11[s3]
            s[idx + 3] = _MUL11[s0] ^ _MUL13[s1] ^ _MUL9[s2] ^ _MUL14[s3]

    rk = round_keys[0]
    s[1], s[5], s[9], s[13] = s[13], s[1], s[5], s[9]
    s[2], s[6], s[10], s[14] = s[10], s[14], s[2], s[6]
    s[3], s[7], s[11], s[15] = s[7], s[11], s[15], s[3]
    for i in range(16):
        s[i] = _INV_SBOX[s[i]]
    for i in range(16):
        s[i] ^= rk[i]
    return bytes(s)


def _aes_cbc_encrypt(data: bytes, key: bytes, iv: bytes) -> bytes:
    pad_len = 16 - (len(data) % 16)
    padded = data + bytes([pad_len] * pad_len)
    round_keys = _key_expansion(key)
    out = bytearray()
    prev = iv
    for offset in range(0, len(padded), 16):
        block = padded[offset : offset + 16]
        xored = bytes(b ^ p for b, p in zip(block, prev))
        ct = _cipher_block(xored, round_keys)
        out.extend(ct)
        prev = ct
    return bytes(out)


def _aes_cbc_decrypt(data: bytes, key: bytes, iv: bytes) -> bytes:
    if len(data) == 0 or len(data) % 16 != 0:
        raise ValueError("Invalid ciphertext length")
    round_keys = _key_expansion(key)
    out = bytearray()
    prev = iv
    for offset in range(0, len(data), 16):
        ct = data[offset : offset + 16]
        pt = _inv_cipher_block(ct, round_keys)
        block = bytes(b ^ p for b, p in zip(pt, prev))
        out.extend(block)
        prev = ct
    pad_len = out[-1]
    if pad_len < 1 or pad_len > 16 or out[-pad_len:] != bytes([pad_len] * pad_len):
        raise ValueError("Invalid PKCS7 padding")
    return bytes(out[:-pad_len])


def new_kdf() -> dict:
    return {
        "iterations": 600000,
        "salt": base64.b64encode(os.urandom(16)).decode("ascii"),
    }


def derive(password: str, kdf: dict) -> bytes:
    salt = kdf["salt"]
    if isinstance(salt, str):
        salt = base64.b64decode(salt)
    iterations = int(kdf.get("iterations", 600000))
    return hashlib.pbkdf2_hmac(
        "sha256", password.encode("utf-8"), salt, iterations, dklen=64
    )


def encrypt(plain: str, key: bytes) -> str:
    if len(key) != 64:
        raise ValueError("Key must be 64 bytes")
    aes_key = key[:32]
    hmac_key = key[32:]
    iv = os.urandom(16)
    data = plain.encode("utf-8")
    ct = _aes_cbc_encrypt(data, aes_key, iv)
    payload = iv + ct
    mac = hmac.new(hmac_key, payload, hashlib.sha256).digest()
    return "enc1:" + base64.b64encode(payload + mac).decode("ascii")


def decrypt(value: str, key: bytes) -> str:
    if len(key) != 64:
        raise ValueError("Key must be 64 bytes")
    if not isinstance(value, str) or not value.startswith("enc1:"):
        raise ValueError("Неверный пароль или повреждённый секрет")
    try:
        raw = base64.b64decode(value[5:])
    except Exception as e:
        raise ValueError("Неверный пароль или повреждённый секрет") from e
    if len(raw) < 16 + 16 + 32:
        raise ValueError("Неверный пароль или повреждённый секрет")
    payload = raw[:-32]
    expected_mac = raw[-32:]
    hmac_key = key[32:]
    mac = hmac.new(hmac_key, payload, hashlib.sha256).digest()
    if not hmac.compare_digest(mac, expected_mac):
        raise ValueError("Неверный пароль или повреждённый секрет")
    iv = payload[:16]
    ct = payload[16:]
    aes_key = key[:32]
    try:
        plain_bytes = _aes_cbc_decrypt(ct, aes_key, iv)
        return plain_bytes.decode("utf-8")
    except Exception as e:
        raise ValueError("Неверный пароль или повреждённый секрет") from e


def make_check(key: bytes) -> str:
    return encrypt("remoteagents", key)


def password_ok(check: str, key: bytes) -> bool:
    try:
        return decrypt(check, key) == "remoteagents"
    except Exception:
        return False
