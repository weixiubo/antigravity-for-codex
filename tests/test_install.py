"""Validate installation without changing the user's actual skill directory."""

import concurrent.futures
import ctypes
from ctypes import wintypes
import hashlib
import json
import os
from pathlib import Path
import subprocess
import unittest
import uuid
import zipfile

from test_runner import ARTIFACTS, FIXTURES, PWSH, REPOSITORY, read_handle


@unittest.skipUnless(os.name == "nt" and PWSH, "Windows and PowerShell 7.4+ are required")
class InstallationTests(unittest.TestCase):
    def setUp(self):
        self.root = ARTIFACTS / ("installation-" + uuid.uuid4().hex)
        self.root.mkdir(parents=True)
        self.destination = self.root / "skills/antigravity-for-codex"

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

    def test_replacement_archives_and_preserves_hidden_files(self):
        self.assertEqual(self.install().returncode, 0)
        hidden = self.destination / "hidden-local.txt"
        hidden.write_text("Hidden local file", encoding="utf-8")
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel.SetFileAttributesW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD]
        kernel.GetFileAttributesW.argtypes = [wintypes.LPCWSTR]
        self.assertTrue(kernel.SetFileAttributesW(str(hidden), 0x2))
        completed = self.install("-Replace")
        self.assertEqual(completed.returncode, 0, completed.stderr)
        with zipfile.ZipFile(json.loads(completed.stdout)["backup"]) as archive:
            name = next(name for name in archive.namelist() if name.endswith("/hidden-local.txt"))
            self.assertEqual(archive.read(name), b"Hidden local file")
        self.assertEqual(hidden.read_text(encoding="utf-8"), "Hidden local file")
        self.assertTrue(kernel.GetFileAttributesW(str(hidden)) & 0x2)

    def test_lookalike_manifest_cannot_authorize_replacement(self):
        self.destination.mkdir(parents=True)
        manifest = self.destination / "SKILL.md"
        contents = "---\nname: other-skill\n---\nExample\nname: antigravity-for-codex\n"
        manifest.write_text(contents, encoding="utf-8")
        completed = self.install("-Replace")
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("not an antigravity-for-codex installation", completed.stderr)
        self.assertEqual(manifest.read_text(encoding="utf-8"), contents)
        self.assertFalse(list(self.destination.parent.glob("*.zip")))

    def test_failed_preparation_leaves_current_installation_intact(self):
        self.assertEqual(self.install().returncode, 0)
        manifest = self.destination / "SKILL.md"
        manifest.write_bytes(manifest.read_bytes() + b"\nOld local marker\n")
        before = self.installation_hashes()
        with read_handle(self.destination / "LICENSE", 0):
            completed = self.install("-Replace")
        self.assertNotEqual(completed.returncode, 0)
        self.assertEqual(self.installation_hashes(), before)

    def test_failed_publication_restores_the_previous_directory(self):
        self.assertEqual(self.install().returncode, 0)
        before = self.installation_hashes()
        script = self.root / "publish-rollback.ps1"
        script.write_text(
            """param($Installer, $Target, $Previous, $Missing)
. $Installer -Destination $Target -Replace -WhatIf
try {
    Publish-InstallTree -Staged $Missing -Target $Target -Previous $Previous -Existing
} catch {
    if ((Test-Path -LiteralPath $Target -PathType Container) -and
        -not (Test-Path -LiteralPath $Previous)) { exit 0 }
    throw
}
exit 1
""",
            encoding="utf-8",
        )
        completed = subprocess.run(
            [PWSH, "-NoProfile", "-File", str(script), str(REPOSITORY / "Install-Skill.ps1"),
             str(self.destination), str(self.root / "previous"), str(self.root / "absent-stage")],
            capture_output=True, text=True, encoding="utf-8", timeout=30,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(self.installation_hashes(), before)

    def installation_hashes(self):
        return {path.relative_to(self.destination): hashlib.sha256(path.read_bytes()).digest()
                for path in self.destination.rglob("*") if path.is_file()}

    def test_concurrent_fresh_installs_only_publish_once(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda _: self.install(), range(2)))
        self.assertEqual(sorted(result.returncode for result in results), [0, 1])
        published = next(result for result in results if result.returncode == 0)
        for relative in json.loads(published.stdout)["files"]:
            self.assertEqual((self.destination / relative).read_bytes(), (REPOSITORY / relative).read_bytes())

    def test_what_if_does_not_write(self):
        completed = self.install("-WhatIf")
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertFalse(self.destination.exists())

    def test_relative_destination_follows_powershell_location(self):
        case = self.root / "install-case.json"
        case.write_text(json.dumps({"entry": str(REPOSITORY / "Install-Skill.ps1"),
                                    "caller_directory": str(self.root),
                                    "parameters": {"Destination": "skills/antigravity-for-codex"}}), encoding="utf-8")
        completed = subprocess.run([PWSH, "-NoProfile", "-File", str(FIXTURES / "invoke-case.ps1"),
                                    "-CaseFile", str(case)], capture_output=True, text=True,
                                   encoding="utf-8", timeout=30)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        installed = Path(json.loads(completed.stdout)["destination"])
        self.assertTrue(installed.samefile(self.destination), f"{installed} != {self.destination}")
        self.assertTrue((self.destination / "SKILL.md").is_file())
