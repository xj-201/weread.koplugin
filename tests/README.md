# WeRead automated tests

This test suite is intentionally lightweight and runs on GitHub-hosted Ubuntu runners.

## Checks

- **LuaJIT syntax:** compiles every tracked plugin Lua source file with LuaJIT's parser. This catches syntax errors using the runtime family used by KOReader.
- **SQLite schema regression:** extracts the exact `CREATE TABLE review_items` and `ALTER TABLE ... ADD COLUMN review_id` SQL statements from `weread/lib/thought_db.lua`, then executes them against SQLite. It verifies:
  - a fresh database schema contains `review_id`;
  - a legacy database without `review_id` upgrades successfully;
  - existing thought rows and their values survive the migration;
  - a new thought row can store a `review_id`.

## Important scope limitation

The SQLite test executes the SQL statements extracted from the Lua source using Python's standard-library SQLite binding. It does **not** load KOReader, the `lua-ljsqlite3` binding, or call `ThoughtDB.open()` directly. A passing result validates the SQL migration and data-preservation behavior, but does not prove the full Kindle runtime path or UI behavior.

The workflow does not access user data, WeRead credentials, network APIs, or Kindle devices.
