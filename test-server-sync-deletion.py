"""Bounded Ubuntu regression: only fresh synthetic files, never user config."""
import contextlib
import importlib.util
import io
import json
import sys
import tempfile
from pathlib import Path
from types import SimpleNamespace

spec = importlib.util.spec_from_file_location("public_sync", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
with tempfile.TemporaryDirectory(prefix="sync-deletion-fixture-") as temporary:
    base = Path(temporary)
    root = base / "p-fixture"
    (root / "src").mkdir(parents=True)
    (root / "src/index.js").write_text("public fixture", encoding="utf-8")
    (root / "src/.npmrc").write_bytes(b"")
    ignore = root / ".stignore"
    ignore.write_text("(?i).env*\n!/src/index.js\n!/src/deleted.js\n*\n", encoding="utf-8")
    manifest = base / "seed-manifest.json"
    manifest.write_text(json.dumps({"projectId": "p-fixture", "hostId": "h-fixture", "allowedRoots": ["src"]}), encoding="utf-8")
    output = base / "snapshot.json"
    args = SimpleNamespace(base=str(base), project="p-fixture", host="h-fixture", manifest=str(manifest), output=str(output), refresh_ignores=True)
    with contextlib.redirect_stdout(io.StringIO()):
        module.snapshot(args)
    assert "!/src/deleted.js" in ignore.read_text("utf-8").splitlines()
    assert [f["path"] for f in json.loads(output.read_text("utf-8"))["files"]] == ["src/index.js"]
    assert ".npmrc" not in ignore.read_text("utf-8")
    ignore.unlink()
    target = base / "public-target.txt"
    target.write_text("must stay unchanged", encoding="utf-8")
    ignore.symlink_to(target)
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            module.snapshot(args)
    except ValueError:
        pass
    else:
        raise AssertionError("ignore symlink accepted")
    assert target.read_text("utf-8") == "must stay unchanged"
print("PASS: deleted-path tombstone allowlist retained; current snapshot/secret exclusion/symlink denial")
