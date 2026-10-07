#!/usr/bin/env python3
# Managed by vps-init-suite.

"""Safely inspect and adjust the Xray policy stored by 3X-UI."""

import json
import os
import re
import shlex
import sqlite3
import subprocess
import sys
from contextlib import closing
from pathlib import Path
from urllib.parse import quote


SETTING_KEY = "xrayTemplateConfig"


def fail(message):
    raise RuntimeError(message)


def db_rows(connection):
    columns = {row[1] for row in connection.execute("PRAGMA table_info(settings)")}
    if not {"id", "key", "value"}.issubset(columns):
        fail("The 3X-UI settings table has an unsupported schema; no changes were made.")
    rows = connection.execute(
        "SELECT id, value FROM settings WHERE key = ? ORDER BY id", (SETTING_KEY,)
    ).fetchall()
    if len(rows) != 1:
        fail(f"Expected one {SETTING_KEY} row in the 3X-UI database; found {len(rows)}.")
    return rows[0]


def open_database(path, readonly=False):
    if readonly:
        uri = f"file:{quote(str(Path(path).resolve()))}?mode=ro"
        connection = sqlite3.connect(uri, uri=True, timeout=30)
    else:
        connection = sqlite3.connect(path, timeout=30)
    connection.execute("PRAGMA busy_timeout = 30000")
    return connection


def load_config(connection):
    _, raw = db_rows(connection)
    try:
        config = json.loads(raw)
    except (TypeError, json.JSONDecodeError) as error:
        fail(f"Stored Xray template is not valid JSON: {error}")
    if not isinstance(config, dict):
        fail("Stored Xray template is not a JSON object; no changes were made.")
    return config


def show_policy(database):
    with closing(open_database(database, readonly=True)) as connection:
        config = load_config(connection)
    policy = config.get("policy") or {}
    if not isinstance(policy, dict):
        fail("The Xray policy field is not an object; no changes were made.")
    levels = policy.get("levels") or {}
    if not isinstance(levels, dict):
        fail("The Xray policy levels field is not an object; no changes were made.")
    print("3X-UI Xray policy levels (only level 0 is changed by this tool):")
    if not levels:
        print("  No levels configured; effective connIdle uses Xray defaults.")
    for key in sorted(levels, key=str):
        level = levels[key]
        if not isinstance(level, dict):
            print(f"  level {key}: invalid value ({type(level).__name__})")
            continue
        fields = ("handshake", "connIdle", "uplinkOnly", "downlinkOnly", "bufferSize")
        values = ", ".join(f"{field}={level.get(field, 'default')}" for field in fields)
        print(f"  level {key}: {values}")


def backup_database(database, destination):
    destination = Path(destination)
    destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if destination.exists():
        fail(f"Backup destination already exists: {destination}")
    source = open_database(database, readonly=True)
    target = sqlite3.connect(destination)
    try:
        source.backup(target)
        result = target.execute("PRAGMA integrity_check").fetchone()[0]
        if result != "ok":
            fail(f"Database backup failed integrity check: {result}")
    finally:
        target.close()
        source.close()
    os.chmod(destination, 0o600)


def restore_database(database, backup):
    source = open_database(backup, readonly=True)
    target = open_database(database)
    try:
        source.backup(target)
        result = target.execute("PRAGMA integrity_check").fetchone()[0]
        if result != "ok":
            fail(f"Restored database failed integrity check: {result}")
    finally:
        target.close()
        source.close()


def restore_policy(database, backup):
    with closing(open_database(backup, readonly=True)) as source:
        backup_config = load_config(source)
    with closing(open_database(database)) as target:
        target.execute("BEGIN IMMEDIATE")
        try:
            row_id, _ = db_rows(target)
            current = load_config(target)
            if "policy" in backup_config:
                current["policy"] = backup_config["policy"]
            else:
                current.pop("policy", None)
            target.execute(
                "UPDATE settings SET value = ? WHERE id = ?",
                (json.dumps(current, ensure_ascii=False, indent=2), row_id),
            )
            target.commit()
        except Exception:
            target.rollback()
            raise
    print("Restored only the Xray policy from the selected backup; other panel data was preserved.")


def set_policy(database, conn_idle, uplink_only=None, downlink_only=None):
    if not 60 <= conn_idle <= 86400:
        fail("connIdle must be between 60 and 86400 seconds.")
    if uplink_only is not None and not 1 <= uplink_only <= 86400:
        fail("uplinkOnly must be between 1 and 86400 seconds.")
    if downlink_only is not None and not 1 <= downlink_only <= 86400:
        fail("downlinkOnly must be between 1 and 86400 seconds.")
    with closing(open_database(database)) as connection:
        connection.execute("BEGIN IMMEDIATE")
        try:
            row_id, _ = db_rows(connection)
            config = load_config(connection)
            policy = config.setdefault("policy", {})
            if not isinstance(policy, dict):
                fail("The Xray policy field is not an object; no changes were made.")
            levels = policy.setdefault("levels", {})
            if not isinstance(levels, dict):
                fail("The Xray policy levels field is not an object; no changes were made.")
            level = levels.setdefault("0", {})
            if not isinstance(level, dict):
                fail("Xray policy level 0 is not an object; no changes were made.")
            previous = {
                "connIdle": level.get("connIdle", "unset (Xray default)"),
                "uplinkOnly": level.get("uplinkOnly", "unset (Xray default)"),
                "downlinkOnly": level.get("downlinkOnly", "unset (Xray default)"),
            }
            level["connIdle"] = conn_idle
            if uplink_only is not None:
                level["uplinkOnly"] = uplink_only
            if downlink_only is not None:
                level["downlinkOnly"] = downlink_only
            connection.execute(
                "UPDATE settings SET value = ? WHERE id = ?",
                (json.dumps(config, ensure_ascii=False, indent=2), row_id),
            )
            connection.commit()
        except Exception:
            connection.rollback()
            raise
    print(
        "Updated policy level 0: "
        f"connIdle {previous['connIdle']} -> {conn_idle}, "
        f"uplinkOnly {previous['uplinkOnly']} -> {level.get('uplinkOnly', 'unset')}, "
        f"downlinkOnly {previous['downlinkOnly']} -> {level.get('downlinkOnly', 'unset')}."
    )


def parse_environment_text(text):
    values = {}
    for line in text.splitlines():
        match = re.match(r"^\s*(?:export\s+)?(XUI_DB_TYPE|XUI_DB_FOLDER)\s*=\s*(.*?)\s*$", line)
        if not match:
            continue
        try:
            parsed = shlex.split(match.group(2), comments=True, posix=True)
        except ValueError:
            continue
        if len(parsed) == 1:
            values[match.group(1)] = parsed[0]
    return values


def locate_database():
    values = dict(os.environ)
    for env_file in ("/etc/default/x-ui", "/etc/conf.d/x-ui", "/etc/sysconfig/x-ui"):
        try:
            values.update(parse_environment_text(Path(env_file).read_text(encoding="utf-8")))
        except OSError:
            pass
    try:
        result = subprocess.run(
            ["systemctl", "show", "x-ui.service", "--property=EnvironmentFiles", "--value"],
            check=False,
            capture_output=True,
            text=True,
            timeout=10,
        )
        if result.returncode == 0:
            for token in shlex.split(result.stdout):
                env_path = token.split(" ", 1)[0]
                if env_path.startswith("/"):
                    try:
                        values.update(parse_environment_text(Path(env_path).read_text(encoding="utf-8")))
                    except OSError:
                        pass
        result = subprocess.run(
            ["systemctl", "show", "x-ui.service", "--property=Environment", "--value"],
            check=False,
            capture_output=True,
            text=True,
            timeout=10,
        )
        if result.returncode == 0:
            for token in shlex.split(result.stdout):
                if token.startswith(("XUI_DB_TYPE=", "XUI_DB_FOLDER=")):
                    values.update(parse_environment_text(token))
    except (OSError, subprocess.SubprocessError, ValueError):
        pass

    backend = values.get("XUI_DB_TYPE", "sqlite").lower()
    if backend not in ("", "sqlite", "sqlite3"):
        fail(f"3X-UI uses {backend} storage. This tool only supports SQLite and made no changes.")
    folder = values.get("XUI_DB_FOLDER", "/etc/x-ui")
    if not folder.startswith("/"):
        fail("XUI_DB_FOLDER must be an absolute path; refusing to guess the database location.")
    database = Path(folder) / "x-ui.db"
    if not database.is_file():
        fail(f"3X-UI SQLite database not found: {database}")
    print(database)


def main(argv):
    if len(argv) == 2 and argv[1] == "locate":
        locate_database()
    elif len(argv) == 3 and argv[1] == "show":
        show_policy(argv[2])
    elif len(argv) == 4 and argv[1] == "backup":
        backup_database(argv[2], argv[3])
    elif len(argv) in (4, 6) and argv[1] == "set":
        seconds = int(argv[3])
        if not 60 <= seconds <= 86400:
            fail("connIdle must be between 60 and 86400 seconds.")
        uplink = downlink = None
        if len(argv) == 6:
            uplink, downlink = int(argv[4]), int(argv[5])
            if not 1 <= uplink <= 86400 or not 1 <= downlink <= 86400:
                fail("uplinkOnly and downlinkOnly must be between 1 and 86400 seconds.")
        set_policy(argv[2], seconds, uplink, downlink)
    elif len(argv) == 4 and argv[1] == "restore":
        restore_database(argv[2], argv[3])
    elif len(argv) == 4 and argv[1] == "restore-policy":
        restore_policy(argv[2], argv[3])
    else:
        fail("Usage: xui-policy.py locate|show DB|backup DB DEST|set DB SECONDS [UPLINK DOWNLINK]|restore DB BACKUP|restore-policy DB BACKUP")


if __name__ == "__main__":
    try:
        main(sys.argv)
    except (RuntimeError, sqlite3.Error, OSError, ValueError) as error:
        print(f"xui-policy: {error}", file=sys.stderr)
        sys.exit(1)
