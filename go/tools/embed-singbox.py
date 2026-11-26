#!/usr/bin/env python3
"""Fetch sing-box for one target per third_party/singbox.lock.json, verify, write the embed file.

usage: embed-singbox.py LOCK OS ARCH OUT CACHE_DIR
"""
import hashlib, io, json, os, sys, tarfile, urllib.request, zipfile

lock, goos, goarch, out, cache = sys.argv[1:6]
asset = next((a for a in json.load(open(lock))["assets"] if a["os"] == goos and a["arch"] == goarch), None)
if asset is None:
    sys.exit(f"embed-singbox: no asset for {goos}/{goarch}")
os.makedirs(cache, exist_ok=True)
cached = os.path.join(cache, asset["sha256"])
data = None
if os.path.exists(cached):
    data = open(cached, "rb").read()
    if hashlib.sha256(data).hexdigest() != asset["sha256"]:
        data = None
if data is None:
    with urllib.request.urlopen(asset["url"], timeout=120) as r:
        data = r.read(256 << 20)
    if hashlib.sha256(data).hexdigest() != asset["sha256"]:
        sys.exit("embed-singbox: archive sha256 mismatch")
    open(cached + ".part", "wb").write(data)
    os.replace(cached + ".part", cached)
member = asset["binPath"]
if member.endswith(".exe"):
    binary = zipfile.ZipFile(io.BytesIO(data)).read(member)
else:
    f = tarfile.open(fileobj=io.BytesIO(data), mode="r:gz").extractfile(member)
    binary = f.read()
if hashlib.sha256(binary).hexdigest() != asset["binSha256"]:
    sys.exit("embed-singbox: binary sha256 mismatch")
os.makedirs(os.path.dirname(out), exist_ok=True)
open(out + ".tmp", "wb").write(binary)
os.replace(out + ".tmp", out)
print(f"embed-singbox: {goos}/{goarch} {len(binary)} bytes")
