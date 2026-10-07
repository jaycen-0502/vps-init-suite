#!/usr/bin/env python3

import importlib.util
import json
import sqlite3
import tempfile
import unittest
from contextlib import closing
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("xui_policy", PROJECT_ROOT / "xui-policy.py")
XUI_POLICY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(XUI_POLICY)


class XuiPolicyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.database = Path(self.temporary.name) / "x-ui.db"
        with closing(sqlite3.connect(self.database)) as connection:
            connection.execute(
                "CREATE TABLE settings (id INTEGER PRIMARY KEY, key TEXT NOT NULL, value TEXT NOT NULL)"
            )
            self.original_config = {
                "policy": {
                    "levels": {"0": {"handshake": 4, "connIdle": 300}},
                    "system": {"statsUserOnline": True},
                },
                "inbounds": [{"tag": "keep-existing-inbound"}],
            }
            connection.execute(
                "INSERT INTO settings (key, value) VALUES (?, ?)",
                (XUI_POLICY.SETTING_KEY, json.dumps(self.original_config)),
            )
            connection.execute(
                "INSERT INTO settings (key, value) VALUES (?, ?)", ("unrelated", "keep-this-row")
            )
            connection.commit()

    def tearDown(self):
        self.temporary.cleanup()

    def read_template(self):
        with closing(sqlite3.connect(self.database)) as connection:
            raw = connection.execute(
                "SELECT value FROM settings WHERE key = ?", (XUI_POLICY.SETTING_KEY,)
            ).fetchone()[0]
        return json.loads(raw)

    def test_set_policy_only_updates_default_level(self):
        XUI_POLICY.set_policy(self.database, 120, 2, 5)
        config = self.read_template()
        self.assertEqual(config["policy"]["levels"]["0"]["connIdle"], 120)
        self.assertEqual(config["policy"]["levels"]["0"]["uplinkOnly"], 2)
        self.assertEqual(config["policy"]["levels"]["0"]["downlinkOnly"], 5)
        self.assertEqual(config["policy"]["system"], {"statsUserOnline": True})
        self.assertEqual(config["inbounds"], self.original_config["inbounds"])

    def test_invalid_policy_does_not_write(self):
        with self.assertRaises(RuntimeError):
            XUI_POLICY.set_policy(self.database, 120, 0, 5)
        self.assertEqual(self.read_template(), self.original_config)

    def test_backup_and_restore_only_policy(self):
        backup = Path(self.temporary.name) / "backup.db"
        XUI_POLICY.backup_database(self.database, backup)
        XUI_POLICY.set_policy(self.database, 120, 2, 5)
        with closing(sqlite3.connect(self.database)) as connection:
            current = self.read_template()
            current["inbounds"].append({"tag": "added-after-backup"})
            connection.execute(
                "UPDATE settings SET value = ? WHERE key = ?",
                (json.dumps(current), XUI_POLICY.SETTING_KEY),
            )
            connection.commit()
        XUI_POLICY.restore_policy(self.database, backup)
        restored = self.read_template()
        self.assertEqual(restored["policy"], self.original_config["policy"])
        self.assertEqual(
            restored["inbounds"],
            self.original_config["inbounds"] + [{"tag": "added-after-backup"}],
        )

    def test_environment_file_parsing(self):
        values = XUI_POLICY.parse_environment_text(
            'XUI_DB_TYPE=sqlite\nXUI_DB_FOLDER="/srv/custom xui" # comment\nOTHER=value\n'
        )
        self.assertEqual(values, {"XUI_DB_TYPE": "sqlite", "XUI_DB_FOLDER": "/srv/custom xui"})


if __name__ == "__main__":
    unittest.main()
