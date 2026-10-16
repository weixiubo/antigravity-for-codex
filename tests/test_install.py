"""Validate installation without changing the user's actual skill directory."""

import hashlib
import json
import os
from pathlib import Path
import subprocess
import unittest
import uuid
import zipfile

from test_runner import ARTIFACTS, FIXTURES, PWSH, REPOSITORY


@unittest.skipUnless(os.name == "nt" and PWSH, "Windows and PowerShell 7.4+ are required")
class InstallationTests(unittest.TestCase):
    def setUp(self):
        self.root = ARTIFACTS / ("installation-" + uuid.uuid4().hex)
        self.root.mkdir(parents=True)
        self.destination = self.root / "skills/antigravity-helper"

    def install(self, *extra):
        return subprocess.run([PWSH, "-NoProfile", "-File", str(REPOSITORY / "Install-Skill.ps1"),
                               "-Destination", str(self.destination), *extra],
                              capture_output=True, text=True, encoding="utf-8", timeout=30)

    def test_installation_copies_runtime_and_preserves_instructions(self):
        instructions = self.root / "AGENTS.md"
        instructions.write_text("Existing project instructions.\n", encoding="utf-8")
        before = instructions.read_bytes()
        completed = self.install()
        self.assertEqual(completed.returncode, 0, completed.stderr)
        result = json.loads(completed.stdout)
        self.assertEqual(result["status"], "SUCCESS")
        self.assertFalse(result["agents_md_modified"])
        for relative in result["files"]:
            self.assertEqual(hashlib.sha256((REPOSITORY / relative).read_bytes()).digest(),
                             hashlib.sha256((self.destination / relative).read_bytes()).digest())
        self.assertEqual(instructions.read_bytes(), before)
        self.assertFalse((self.destination / "tests").exists())

    def test_existing_installation_requires_replace(self):
        self.assertEqual(self.install().returncode, 0)
        before = (self.destination / "SKILL.md").read_bytes()
        repeated = self.install()
        self.assertNotEqual(repeated.returncode, 0)
        self.assertEqual((self.destination / "SKILL.md").read_bytes(), before)

    def test_replacement_preserves_backup_and_extra_files(self):
        self.assertEqual(self.install().returncode, 0)
        note = self.destination / "local-note.txt"
        note.write_text("Local extension", encoding="utf-8")
        completed = self.install("-Replace")
        self.assertEqual(completed.returncode, 0, completed.stderr)
        backup = Path(json.loads(completed.stdout)["backup"])
        self.assertTrue(backup.is_file())
        with zipfile.ZipFile(backup) as archive:
            name = next(name for name in archive.namelist() if name.replace("\\", "/").endswith("/local-note.txt"))
            self.assertEqual(archive.read(name), b"Local extension")
        self.assertEqual(note.read_text(encoding="utf-8"), "Local extension")

    def test_what_if_does_not_write(self):
        completed = self.install("-WhatIf")
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertFalse(self.destination.exists())

    def test_relative_destination_follows_powershell_location(self):
        case = self.root / "install-case.json"
        case.write_text(json.dumps({"entry": str(REPOSITORY / "Install-Skill.ps1"),
                                    "caller_directory": str(self.root),
                                    "parameters": {"Destination": "skills/antigravity-helper"}}), encoding="utf-8")
        completed = subprocess.run([PWSH, "-NoProfile", "-File", str(FIXTURES / "invoke-case.ps1"),
                                    "-CaseFile", str(case)], capture_output=True, text=True,
                                   encoding="utf-8", timeout=30)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(Path(json.loads(completed.stdout)["destination"]), self.destination)
        self.assertTrue((self.destination / "SKILL.md").is_file())
