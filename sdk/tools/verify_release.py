"""Check the file set and SHA-256 of an extracted XTCP delivery, using only Python 3."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath

def verify(root):
    root=root.resolve()
    manifest=root/"MANIFEST.json"
    records=json.loads(manifest.read_text(encoding="utf8"))
    expected=set()
    for item in records["files"]:
        rel=PurePosixPath(item["path"])
        if rel.is_absolute() or ".." in rel.parts or str(rel) in expected:
            raise ValueError(f"Invalid manifest entry {rel}")
        expected.add(str(rel))
        p=root/rel
        if not p.resolve().is_relative_to(root) or not p.is_file() or p.stat().st_size!=item["bytes"]:
            raise ValueError(f"Missing or changed file {rel}")
        h=hashlib.sha256()
        with p.open("rb") as source:
            for chunk in iter(lambda:source.read(1024*1024),b""):
                h.update(chunk)
        if h.hexdigest()!=item["sha256"]:
            raise ValueError(f"SHA-256 mismatch {rel}")
    found={p.relative_to(root).as_posix() for p in root.rglob("*") if p.is_file() and p!=manifest}
    if found!=expected:
        raise ValueError(f"Unexpected files {sorted(found-expected)}")
    print(f'{records["product"]} {records["version"]}: verified {len(expected)} files')
if __name__=="__main__":
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("root",nargs="?",type=Path,default=Path(__file__).resolve().parents[1])
    verify(p.parse_args().root)
