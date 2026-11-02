#!/usr/bin/env python3
"""SQLite schema regression tests for weread/lib/thought_db.lua.

These tests execute the exact CREATE TABLE and ALTER TABLE statements extracted
from the plugin source against SQLite. They do not load KOReader or execute the
Lua ThoughtDB module itself.
"""
from pathlib import Path
import re
import sqlite3
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "weread/lib/thought_db.lua").read_text(encoding="utf-8")


def extract_schema_sql():
    match = re.search(
        r"db:exec\(\[\[\s*(CREATE TABLE IF NOT EXISTS review_items.*?WITHOUT ROWID)\s*\]\]",
        SOURCE,
        re.DOTALL,
    )
    if not match:
        raise AssertionError("Could not find review_items CREATE TABLE SQL in thought_db.lua")
    return match.group(1)


def extract_migration_sql():
    match = re.search(
        r'db:exec\("(ALTER TABLE review_items ADD COLUMN review_id TEXT NOT NULL DEFAULT \'\')\s*"\)',
        SOURCE,
    )
    if not match:
        raise AssertionError("Could not find review_id ALTER TABLE SQL in thought_db.lua")
    return match.group(1)


LEGACY_SCHEMA = """
CREATE TABLE review_items (
    chapter_uid INTEGER NOT NULL,
    range       TEXT    NOT NULL,
    item_index  INTEGER NOT NULL,
    abstract    TEXT,
    author      TEXT    NOT NULL,
    content     TEXT    NOT NULL,
    likes_count INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (chapter_uid, range, item_index)
) WITHOUT ROWID
"""


def columns(conn):
    return {row[1] for row in conn.execute("PRAGMA table_info(review_items)")}


class ThoughtDBMigrationTests(unittest.TestCase):
    def test_fresh_schema_includes_review_id(self):
        conn = sqlite3.connect(":memory:")
        conn.execute(extract_schema_sql())
        self.assertIn("review_id", columns(conn))
        conn.close()

    def test_existing_database_migrates_without_losing_rows(self):
        conn = sqlite3.connect(":memory:")
        conn.execute(LEGACY_SCHEMA)
        conn.execute(
            """INSERT INTO review_items
               (chapter_uid, range, item_index, abstract, author, content, likes_count)
               VALUES (?, ?, ?, ?, ?, ?, ?)""",
            (1686, "10-20", 1, "摘录", "旧作者", "旧想法正文", 3),
        )

        conn.execute(extract_migration_sql())

        self.assertIn("review_id", columns(conn))
        old_row = conn.execute(
            """SELECT chapter_uid, range, item_index, author, content,
                      likes_count, review_id
               FROM review_items"""
        ).fetchone()
        self.assertEqual(
            old_row, (1686, "10-20", 1, "旧作者", "旧想法正文", 3, "")
        )

        conn.execute(
            """INSERT INTO review_items
               (chapter_uid, range, item_index, abstract, author, content,
                likes_count, review_id)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
            (1686, "30-40", 1, None, "新作者", "新想法正文", 0, "review-123"),
        )
        new_row = conn.execute(
            "SELECT review_id FROM review_items WHERE range='30-40'"
        ).fetchone()
        self.assertEqual(new_row, ("review-123",))
        conn.close()


if __name__ == "__main__":
    unittest.main(verbosity=2)
