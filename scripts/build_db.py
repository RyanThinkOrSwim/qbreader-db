#!/usr/bin/env python3
"""Build qbreader.sqlite from the QBReader mongoexport dumps (NDJSON, Extended JSON).

Usage:
    python3 scripts/build_db.py --dump-dir qbdump --out dist

Outputs (in --out):
    qbreader.sqlite        uncompressed database (journal_mode=DELETE, single file)
    qbreader.sqlite.xz     LZMA/xz, decodable on iOS with Compression's COMPRESSION_LZMA
    manifest.json          version, schema, sizes, sha256 of both files, row counts

Streams line-by-line, so it runs in well under 1 GB of RAM.
"""
import argparse
import datetime as dt
import hashlib
import json
import lzma
import os
import sqlite3
import sys
import time

SCHEMA_VERSION = 1

SCHEMA = """
CREATE TABLE meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
) WITHOUT ROWID;

CREATE TABLE sets (
    id          INTEGER PRIMARY KEY,
    mongo_id    TEXT NOT NULL UNIQUE,
    name        TEXT NOT NULL,
    year        INTEGER NOT NULL,
    difficulty  INTEGER,
    standard    INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE packets (
    id          INTEGER PRIMARY KEY,
    mongo_id    TEXT NOT NULL UNIQUE,
    set_id      INTEGER NOT NULL REFERENCES sets(id),
    name        TEXT NOT NULL,
    number      INTEGER NOT NULL
);

CREATE TABLE tossups (
    id                    INTEGER PRIMARY KEY,
    mongo_id              TEXT NOT NULL UNIQUE,
    set_id                INTEGER NOT NULL REFERENCES sets(id),
    packet_id             INTEGER NOT NULL REFERENCES packets(id),
    number                INTEGER NOT NULL,
    question              TEXT NOT NULL,
    question_sanitized    TEXT NOT NULL,
    answer                TEXT NOT NULL,
    answer_sanitized      TEXT NOT NULL,
    category              TEXT NOT NULL,
    subcategory           TEXT NOT NULL,
    alternate_category    TEXT,
    alternate_subcategory TEXT,
    difficulty            INTEGER,
    year                  INTEGER NOT NULL,
    standard              INTEGER NOT NULL,
    updated_at            INTEGER
);

CREATE TABLE bonuses (
    id                    INTEGER PRIMARY KEY,
    mongo_id              TEXT NOT NULL UNIQUE,
    set_id                INTEGER NOT NULL REFERENCES sets(id),
    packet_id             INTEGER NOT NULL REFERENCES packets(id),
    number                INTEGER NOT NULL,
    leadin                TEXT NOT NULL,
    leadin_sanitized      TEXT NOT NULL,
    part_count            INTEGER NOT NULL,
    category              TEXT NOT NULL,
    subcategory           TEXT NOT NULL,
    alternate_category    TEXT,
    alternate_subcategory TEXT,
    difficulty            INTEGER,
    year                  INTEGER NOT NULL,
    standard              INTEGER NOT NULL,
    updated_at            INTEGER
);

CREATE TABLE bonus_parts (
    bonus_id             INTEGER NOT NULL REFERENCES bonuses(id),
    part_index           INTEGER NOT NULL,
    part                 TEXT NOT NULL,
    part_sanitized       TEXT NOT NULL,
    answer               TEXT NOT NULL,
    answer_sanitized     TEXT NOT NULL,
    value                INTEGER NOT NULL DEFAULT 10,
    difficulty_modifier  TEXT,
    PRIMARY KEY (bonus_id, part_index)
) WITHOUT ROWID;
"""

INDEXES = """
CREATE INDEX packets_set           ON packets(set_id, number);
CREATE INDEX tossups_filter        ON tossups(difficulty, category, subcategory, year);
CREATE INDEX tossups_subcat        ON tossups(subcategory, difficulty);
CREATE INDEX tossups_alt_subcat    ON tossups(alternate_subcategory) WHERE alternate_subcategory IS NOT NULL;
CREATE INDEX tossups_packet        ON tossups(packet_id, number);
CREATE INDEX tossups_set           ON tossups(set_id);
CREATE INDEX bonuses_filter        ON bonuses(difficulty, category, subcategory, year);
CREATE INDEX bonuses_subcat        ON bonuses(subcategory, difficulty);
CREATE INDEX bonuses_alt_subcat    ON bonuses(alternate_subcategory) WHERE alternate_subcategory IS NOT NULL;
CREATE INDEX bonuses_packet        ON bonuses(packet_id, number);
CREATE INDEX bonuses_set           ON bonuses(set_id);
"""

# Contentless FTS5: holds only the search index (rowid = tossups.id / bonuses.id),
# the text itself is read from the base tables. unicode61 + remove_diacritics 2
# needs SQLite >= 3.27, which every iOS 13+ device ships.
FTS = """
CREATE VIRTUAL TABLE tossups_fts USING fts5(
    question, answer,
    content='', columnsize=0,
    tokenize='unicode61 remove_diacritics 2'
);
CREATE VIRTUAL TABLE bonuses_fts USING fts5(
    leadin, parts, answers,
    content='', columnsize=0,
    tokenize='unicode61 remove_diacritics 2'
);
"""


def oid(v):
    return v["$oid"] if isinstance(v, dict) else str(v)


def num(v):
    if v is None:
        return None
    if isinstance(v, dict):
        for k in ("$numberInt", "$numberLong", "$numberDouble"):
            if k in v:
                return int(float(v[k]))
    return int(v)


def date_secs(v):
    if v is None:
        return None
    if isinstance(v, dict) and "$date" in v:
        d = v["$date"]
        if isinstance(d, dict):
            return int(d["$numberLong"]) // 1000
        if isinstance(d, (int, float)):
            return int(d) // 1000
        return int(dt.datetime.fromisoformat(d.replace("Z", "+00:00")).timestamp())
    return None


def ndjson(path):
    with open(path, encoding="utf-8") as f:
        for line in f:
            if line.strip():
                yield json.loads(line)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def build(dump_dir, db_path, version):
    if os.path.exists(db_path):
        os.remove(db_path)
    con = sqlite3.connect(db_path)
    con.executescript("""
        PRAGMA page_size = 4096;
        PRAGMA journal_mode = OFF;
        PRAGMA synchronous = OFF;
        PRAGMA temp_store = FILE;
        PRAGMA cache_size = -65536;
    """)
    con.executescript(SCHEMA)
    p = lambda name: os.path.join(dump_dir, name)

    set_ids, set_info = {}, {}
    for i, d in enumerate(ndjson(p("sets.json")), 1):
        m = oid(d["_id"])
        set_ids[m] = i
        set_info[m] = (num(d.get("year")), d.get("standard", True))
        con.execute("INSERT INTO sets VALUES (?,?,?,?,?,?)",
                    (i, m, d["name"], num(d.get("year")), num(d.get("difficulty")), int(d.get("standard", True))))
    log(f"sets: {len(set_ids)}")

    # Packets whose set no longer exists in sets.json are orphans in the source
    # dump (no questions reference them); skip them.
    packet_ids, orphans = {}, 0
    for d in ndjson(p("packets.json")):
        sid = set_ids.get(oid(d["set"]["_id"]))
        if sid is None:
            orphans += 1
            continue
        i = len(packet_ids) + 1
        m = oid(d["_id"])
        packet_ids[m] = i
        con.execute("INSERT INTO packets VALUES (?,?,?,?,?)", (i, m, sid, d["name"], num(d["number"])))
    log(f"packets: {len(packet_ids)} (skipped {orphans} orphan)")

    def common(d):
        s = d["set"]
        sm = oid(s["_id"])
        set_year = num(s.get("year")) or set_info.get(sm, (None,))[0]
        return dict(
            set_id=set_ids[sm],
            packet_id=packet_ids[oid(d["packet"]["_id"])],
            number=num(d["number"]),
            category=d["category"],
            subcategory=d["subcategory"],
            alternate_category=d.get("alternate_category"),
            alternate_subcategory=d.get("alternate_subcategory"),
            difficulty=num(d.get("difficulty")),
            year=num(d.get("year")) or set_year,
            standard=int(s.get("standard", True)),
            updated_at=date_secs(d.get("updatedAt")),
        )

    n = 0
    batch, fts = [], []
    for n, d in enumerate(ndjson(p("tossups.json")), 1):
        c = common(d)
        batch.append((n, oid(d["_id"]), c["set_id"], c["packet_id"], c["number"],
                      d["question"], d["question_sanitized"], d["answer"], d["answer_sanitized"],
                      c["category"], c["subcategory"], c["alternate_category"], c["alternate_subcategory"],
                      c["difficulty"], c["year"], c["standard"], c["updated_at"]))
        if len(batch) >= 5000:
            con.executemany("INSERT INTO tossups VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", batch)
            batch.clear()
    con.executemany("INSERT INTO tossups VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", batch)
    tossup_count = n
    log(f"tossups: {tossup_count}")

    con.executescript(FTS)
    con.execute("INSERT INTO tossups_fts(rowid, question, answer) "
                "SELECT id, question_sanitized, answer_sanitized FROM tossups")
    log("tossups_fts built")

    batch, parts_batch = [], []
    for n, d in enumerate(ndjson(p("bonuses.json")), 1):
        c = common(d)
        parts, parts_s = d["parts"], d["parts_sanitized"]
        answers, answers_s = d["answers"], d["answers_sanitized"]
        values = [num(v) for v in d.get("values", [])]
        mods = d.get("difficultyModifiers", [])
        k = len(parts)
        batch.append((n, oid(d["_id"]), c["set_id"], c["packet_id"], c["number"],
                      d["leadin"], d["leadin_sanitized"], k,
                      c["category"], c["subcategory"], c["alternate_category"], c["alternate_subcategory"],
                      c["difficulty"], c["year"], c["standard"], c["updated_at"]))
        for j in range(k):
            parts_batch.append((n, j, parts[j], parts_s[j] if j < len(parts_s) else parts[j],
                                answers[j] if j < len(answers) else "",
                                answers_s[j] if j < len(answers_s) else "",
                                values[j] if j < len(values) and values[j] is not None else 10,
                                mods[j] if j < len(mods) else None))
        fts.append((n, d["leadin_sanitized"], "\n".join(parts_s), "\n".join(answers_s)))
        if len(batch) >= 5000:
            con.executemany("INSERT INTO bonuses VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", batch)
            con.executemany("INSERT INTO bonus_parts VALUES (?,?,?,?,?,?,?,?)", parts_batch)
            con.executemany("INSERT INTO bonuses_fts(rowid, leadin, parts, answers) VALUES (?,?,?,?)", fts)
            batch.clear(); parts_batch.clear(); fts.clear()
    con.executemany("INSERT INTO bonuses VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", batch)
    con.executemany("INSERT INTO bonus_parts VALUES (?,?,?,?,?,?,?,?)", parts_batch)
    con.executemany("INSERT INTO bonuses_fts(rowid, leadin, parts, answers) VALUES (?,?,?,?)", fts)
    bonus_count = n
    log(f"bonuses: {bonus_count}")

    con.executescript(INDEXES)
    con.execute("INSERT INTO tossups_fts(tossups_fts) VALUES ('optimize')")
    con.execute("INSERT INTO bonuses_fts(bonuses_fts) VALUES ('optimize')")
    log("indexes + fts optimize done")

    counts = {
        "sets": len(set_ids), "packets": len(packet_ids),
        "tossups": tossup_count, "bonuses": bonus_count,
        "bonus_parts": con.execute("SELECT count(*) FROM bonus_parts").fetchone()[0],
    }
    meta = {
        "schema_version": str(SCHEMA_VERSION),
        "data_version": version,
        "built_at": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "source": "QBReader mongoexport dumps",
        **{f"count_{k}": str(v) for k, v in counts.items()},
    }
    con.executemany("INSERT INTO meta VALUES (?,?)", meta.items())
    con.execute(f"PRAGMA user_version = {SCHEMA_VERSION}")
    con.commit()
    con.execute("ANALYZE")
    con.commit()
    con.execute("PRAGMA journal_mode = DELETE")
    con.execute("VACUUM")
    ok = con.execute("PRAGMA integrity_check").fetchone()[0]
    con.close()
    if ok != "ok":
        sys.exit(f"integrity_check failed: {ok}")
    log(f"vacuumed, integrity ok, {os.path.getsize(db_path)/1e6:.1f} MB")
    return counts


def compress_xz(src, dst):
    # Single-stream xz, LZMA2 preset 6, CRC32 check: the format Apple's
    # COMPRESSION_LZMA decoder expects.
    filters = [{"id": lzma.FILTER_LZMA2, "preset": 6}]
    with open(src, "rb") as fi, lzma.open(dst, "wb", format=lzma.FORMAT_XZ,
                                           check=lzma.CHECK_CRC32, filters=filters) as fo:
        for chunk in iter(lambda: fi.read(1 << 20), b""):
            fo.write(chunk)
    log(f"xz: {os.path.getsize(dst)/1e6:.1f} MB")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dump-dir", default="qbdump")
    ap.add_argument("--out", default="dist")
    ap.add_argument("--version", default=dt.date.today().isoformat())
    ap.add_argument("--base-url", default="",
                    help="URL prefix where the .xz will be hosted, e.g. a GitHub Release download URL")
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)
    db = os.path.join(args.out, "qbreader.sqlite")
    xz = db + ".xz"
    counts = build(args.dump_dir, db, args.version)
    compress_xz(db, xz)

    manifest = {
        "version": args.version,
        "schemaVersion": SCHEMA_VERSION,
        "url": (args.base_url.rstrip("/") + "/qbreader.sqlite.xz") if args.base_url else "qbreader.sqlite.xz",
        "compression": "lzma",
        "compressedSize": os.path.getsize(xz),
        "compressedSha256": sha256(xz),
        "size": os.path.getsize(db),
        "sha256": sha256(db),
        "counts": counts,
    }
    with open(os.path.join(args.out, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2)
    log("manifest.json written")
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()
