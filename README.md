# QBReader offline database

Pre-built, indexed SQLite of the full QBReader question bank, served as a static
file from GitHub Releases and installed on-device by the iOS app.

## Current build

Source: QBReader mongoexport dumps (Google Drive folder `184vCqGAVqUt0G7-K2jG5MH7e2Qm3GzYp`).
Both builds hold the same rows: 184,089 tossups, 156,503 bonuses (464,826 parts),
8,829 packets and 692 sets. Search is FTS5 and ignores accents (`bronte` matches `Brontë`).

| | Full | Lite |
|---|---|---|
| Manifest | `manifest.json` | `manifest-lite.json` |
| Download | `qbreader.sqlite.xz`, ~199 MB | `qbreader-lite.sqlite.xz`, ~136 MB |
| On device | ~800 MB | ~492 MB |
| Question / lead-in / part HTML | yes | no (plain text) |
| Answer HTML (required part in `<b><u>`) | yes | yes |
| Phrase / NEAR search | yes | no (word and prefix search work) |
| Extra subcategory + set indexes | yes | no (subcategory filters still ~30 ms) |

Both builds share one schema. In lite, `tossups.question`, `bonuses.leadin` and
`bonus_parts.part` are NULL. `QBReaderStore` falls back to the `*_sanitized`
text, so app code doesn't change. `meta.variant` says which build is open.

## Layout

```
scripts/build_db.py          dumps -> qbreader.sqlite + .xz + manifest.json
scripts/download_dumps.py    pulls the 4 JSON dumps from Drive (skips .bson)
.github/workflows/build-db.yml  monthly rebuild -> GitHub Release "db-YYYY-MM-DD"
ios/QBReaderDatabaseManager.swift  manifest check, download, verify, decompress, install
ios/QBReaderStore.swift      read-only queries: random by filter, full-text search, packets
```

## Build locally

```bash
pip install gdown
python3 scripts/download_dumps.py --folder https://drive.google.com/drive/folders/184vCqGAVqUt0G7-K2jG5MH7e2Qm3GzYp --out qbdump
python3 scripts/build_db.py --dump-dir qbdump --out dist \
  --base-url https://github.com/RyanThinkOrSwim/qbreader-db/releases/download/db-$(date +%F)
python3 scripts/build_db.py --dump-dir qbdump --out dist --variant lite \
  --base-url https://github.com/RyanThinkOrSwim/qbreader-db/releases/download/db-$(date +%F)
```

About 10 minutes on one CPU, under 1 GB RAM. Most of that is xz compression.

## Schema (v1, `PRAGMA user_version = 1`)

- `sets(id, mongo_id, name, year, difficulty, standard)`
- `packets(id, mongo_id, set_id, name, number)`
- `tossups(id, mongo_id, set_id, packet_id, number, question, question_sanitized, answer, answer_sanitized, category, subcategory, alternate_category, alternate_subcategory, difficulty, year, standard, updated_at)`
- `bonuses(id, mongo_id, set_id, packet_id, number, leadin, leadin_sanitized, part_count, category, subcategory, alternate_category, alternate_subcategory, difficulty, year, standard, updated_at)`
- `bonus_parts(bonus_id, part_index, part, part_sanitized, answer, answer_sanitized, value, difficulty_modifier)`
- `tossups_fts(question, answer)`: contentless FTS5, `rowid = tossups.id`
- `bonuses_fts(leadin, parts, answers)`: contentless FTS5, `rowid = bonuses.id`
- `meta(key, value)`: `data_version`, `built_at`, row counts

Conventions: snake_case columns, integer primary keys, booleans as 0/1,
`updated_at` in Unix seconds. HTML fields keep QBReader's `<b><u>` markup, which
marks the required part of each answer. `*_sanitized` fields are QBReader's own
plain-text versions, with quotes normalized and the power mark removed. They are
kept as-is because they can't be reliably derived from the HTML.

Indexes cover the QBReader filter path `(difficulty, category, subcategory, year)`,
plus subcategory, alternate subcategory, packet order, and set. A filtered random
pick takes about 30 ms on desktop.

Source quirk: 16 packets in `packets.json` belong to a set ("2022 MRNA Vaccine")
that is not in `sets.json`, and no questions reference them, so they are skipped.

## iOS integration

Requires iOS 15+. Uses only system frameworks: Foundation, Compression, CryptoKit, SQLite3.

1. Add both files in `ios/` to the app target. Link `libsqlite3.tbd` (Build Phases > Link Binary).
2. Pick a build: `QBReaderDatabaseManager.shared` (full) or `QBReaderDatabaseManager.lite`.
   Both read from `https://github.com/RyanThinkOrSwim/qbreader-db/releases/latest/download/`.
   Both install to the same file, so switching from one to the other replaces the current database.
3. Pro unlock / settings screen:

```swift
let manager = QBReaderDatabaseManager.lite   // or .shared for full
if let update = try await manager.availableUpdate() {
    // update.compressedSize / update.size -> "Download 136 MB (needs ~492 MB free)"
    try await manager.install(update) { p in
        Task { @MainActor in self.progress = p }
    }
}
let store = try QBReaderStore(url: try await manager.databaseURL)
```

4. Queries:

```swift
var f = QBFilter()
f.difficulties = [3, 4]
f.categories = ["Science"]
let tossups = store.randomTossups(f, count: 20)
let hits = store.searchTossups("schoenberg", answerOnly: true)
let bonuses = store.randomBonuses(f, count: 5)
```

Install does the following:

1. Downloads with progress.
2. Checks the SHA-256 of the `.xz`.
3. Stream-decompresses with `COMPRESSION_LZMA`, using a few MB of RAM.
4. Checks the SHA-256 of the `.sqlite` and `user_version`.
5. Swaps the file in atomically and marks it `isExcludedFromBackup`.

If any step fails, the old database stays in place.

Close any open `QBReaderStore` before calling `install` on an existing install,
then reopen it after.

### Why xz, not zstd

Apple's Compression framework has no zstd decoder. It does support LZMA in xz
format, zlib (raw deflate), LZFSE, LZ4, and Brotli. Using xz keeps the app free
of third-party libraries. The build writes a single-stream, single-block xz file
with a CRC32 check, the layout Apple's decoder handles.

## Schema changes

Bump `SCHEMA_VERSION` in `build_db.py` and `supportedSchemaVersion` in the Swift
manager together. Older app builds ignore manifests with a newer schema, so they
keep their current database instead of installing one they can't read.
