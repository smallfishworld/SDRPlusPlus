#!/usr/bin/env python3
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / "flutter_ui" / "lib" / "models" / "sdr_module_catalog.dart"

roots = ("source_modules", "decoder_modules", "misc_modules", "sink_modules")

expected = set()
for root_name in roots:
    root = ROOT / root_name
    if not root.exists():
        continue
    for entry in root.iterdir():
        if entry.is_dir() and not entry.name.startswith("."):
            expected.add(f"{root_name}/{entry.name}")

text = CATALOG.read_text(encoding="utf-8")
mapped = set(re.findall(r"upstreamPath:\s*'([^']+)'", text))
mapped = {p for p in mapped if any(p.startswith(root + "/") for root in roots)}

missing = sorted(expected - mapped)
unknown = sorted(mapped - expected)

if missing or unknown:
    if missing:
        print("Missing SDR++ module mappings:")
        for path in missing:
            print(f"  - {path}")
    if unknown:
        print("Catalog entries with no upstream module directory:")
        for path in unknown:
            print(f"  - {path}")
    sys.exit(1)

print(f"SDR++ module catalog complete: {len(mapped)} upstream modules mapped")
