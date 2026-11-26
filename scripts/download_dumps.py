#!/usr/bin/env python3
"""Download the QBReader JSON dumps (not the .bson copies) from the public Drive folder."""
import argparse
import os

import gdown

WANTED = {"sets.json", "packets.json", "tossups.json", "bonuses.json"}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--folder", required=True)
    ap.add_argument("--out", default="qbdump")
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)

    files = gdown.download_folder(args.folder, skip_download=True, quiet=True)
    found = {f.path: f.id for f in files if os.path.basename(f.path) in WANTED}
    missing = WANTED - {os.path.basename(p) for p in found}
    if missing:
        raise SystemExit(f"Drive folder is missing: {sorted(missing)}")
    for path, file_id in found.items():
        dst = os.path.join(args.out, os.path.basename(path))
        gdown.download(id=file_id, output=dst, quiet=False)
        print(f"{dst}: {os.path.getsize(dst) / 1e6:.1f} MB")


if __name__ == "__main__":
    main()
