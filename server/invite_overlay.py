"""Versioned PE overlay shared format with launcher/InvitationOverlay.cs.
SHA-256 detects damage/substitution; it is not a publisher signature.
"""
import hashlib
import io
import struct
import zipfile

MAGIC = b'RAINVITE-OV1\r\n\x1a\n'
LIMIT = 128 * 1024 * 1024


def pe_size(data):
    if len(data) < 64 or data[:2] != b'MZ':
        raise ValueError('PE header')
    pe = struct.unpack_from('<I', data, 60)[0]
    if pe + 24 > len(data) or data[pe:pe+4] != b'PE\0\0':
        raise ValueError('PE signature')
    sections = struct.unpack_from('<H', data, pe+6)[0]
    optional = struct.unpack_from('<H', data, pe+20)[0]
    start = pe + 24
    end = struct.unpack_from('<I', data, start+60)[0]
    for n in range(sections):
        raw_size, raw_start = struct.unpack_from('<II', data, start+optional+n*40+16)
        end = max(end, raw_start+raw_size)
    # Authenticode uses a file offset, unlike other data directories.
    magic = struct.unpack_from('<H', data, start)[0]
    directory = start + (112 if magic == 0x20b else 96)
    if optional >= directory-start+40:
        certificate, size = struct.unpack_from('<II', data, directory+32)
        end = max(end, certificate+size)
    if not 64 <= end <= len(data):
        raise ValueError('PE length')
    return end


def attach(base, files):
    if pe_size(base) != len(base):
        raise ValueError('release EXE already has an overlay')
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, 'w', zipfile.ZIP_DEFLATED) as z:
        for name, value in files.items():
            z.writestr(name, value)
    payload = buf.getvalue()
    prefix = base + MAGIC + payload + struct.pack('<Q', len(payload))
    if len(prefix)+48 > LIMIT:
        raise ValueError('overlay too large')
    return prefix + hashlib.sha256(prefix).digest() + MAGIC


def read(data):
    end = pe_size(data)
    if len(data) == end:
        return None
    if len(data) > LIMIT or data[end:end+16] != MAGIC or data[-16:] != MAGIC or len(data) < end+72:
        raise ValueError('damaged invitation overlay')
    length = struct.unpack_from('<Q', data, len(data)-56)[0]
    if length != len(data)-end-72 or hashlib.sha256(data[:-48]).digest() != data[-48:-16]:
        raise ValueError('invitation integrity check failed')
    with zipfile.ZipFile(io.BytesIO(data[end+16:-56])) as z:
        if len(z.namelist()) != len(set(z.namelist())) or sum(x.file_size for x in z.infolist()) > LIMIT:
            raise ValueError('invalid payload')
        if set(z.namelist()) - {'invite.rainvite', 'sing-box.exe'} or 'invite.rainvite' not in z.namelist():
            raise ValueError('invalid payload files')
        return {name: z.read(name) for name in z.namelist()}
