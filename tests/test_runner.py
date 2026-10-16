"""Exercise the shipped scripts against a local, account-free CLI fixture."""

import concurrent.futures
import ctypes
from ctypes import wintypes
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
import unittest
import uuid

REPOSITORY = Path(__file__).resolve().parents[1]
FIXTURES = Path(__file__).resolve().parent / "fixtures"
PWSH = shutil.which("pwsh")
ARTIFACTS = Path(os.environ.get("ANTIGRAVITY_HELPER_TEST_ROOT", str(REPOSITORY / ".test-output"))) / uuid.uuid4().hex


def prepare(name, mode="success", prompt="Unicode: 中文\nQuoted: \"value\"", timeout="5s", action=None):
    workspace = ARTIFACTS / name
    workspace.mkdir(parents=True, exist_ok=True)
    entry = "Get-AntigravityInfo.ps1" if action else "Invoke-Antigravity.ps1"
    parameters = {
        "Workspace": str(workspace), "Timeout": timeout, "CliPath": PWSH,
        "CliPrefixArguments": ["-NoProfile", "-File", str(FIXTURES / "fake-cli.ps1")],
    }
    if action:
        parameters["Action"] = action
    else:
        parameters.update(Prompt=prompt, Model="fixture-model")
    case_file = workspace / f"case-{uuid.uuid4().hex}.json"
    case_file.write_text(json.dumps({"entry": str(REPOSITORY / "scripts" / entry), "parameters": parameters}, ensure_ascii=False), encoding="utf-8")
    command = [PWSH, "-NoProfile", "-File", str(FIXTURES / "invoke-case.ps1"), "-CaseFile", str(case_file)]
    environment = dict(os.environ, FAKE_AGY_MODE=mode, FAKE_PID_FILE=str(workspace / "pid.txt"))
    return workspace, command, environment, case_file


def execute(case):
    _, command, environment, _ = case
    completed = subprocess.run(command, env=environment, capture_output=True, text=True, encoding="utf-8", timeout=35)
    try:
        result = json.loads(completed.stdout)
    except ValueError as error:
        raise AssertionError(f"Expected one JSON result. stdout={completed.stdout!r}; stderr={completed.stderr!r}") from error
    return completed, result


def process_running(pid):
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    kernel.OpenProcess.restype = wintypes.HANDLE
    kernel.GetExitCodeProcess.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]
    kernel.GetExitCodeProcess.restype = wintypes.BOOL
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    handle = kernel.OpenProcess(0x1000, False, pid)
    if not handle:
        if ctypes.get_last_error() == 87:
            return False
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        code = wintypes.DWORD()
        if not kernel.GetExitCodeProcess(handle, ctypes.byref(code)):
            raise ctypes.WinError(ctypes.get_last_error())
        return code.value == 259
    finally:
        kernel.CloseHandle(handle)


@unittest.skipUnless(os.name == "nt" and PWSH, "Windows and PowerShell 7.4+ are required")
class RunnerTests(unittest.TestCase):
    def test_long_unicode_input(self):
        prompt = ("中文 \"double\" 'single' $([math]::sqrt(4)) `n\n" * 2000) + "END"
        completed, result = execute(prepare("unicode", prompt=prompt))
        self.assertEqual(completed.returncode, 0, result)
        self.assertEqual(result["response"], prompt)
        self.assertTrue(result["model_verified"])
        saved = json.loads((Path(result["run_directory"]) / "result.json").read_text(encoding="utf-8-sig"))
        self.assertEqual(saved["status"], "SUCCESS")

    def test_prompt_file(self):
        case = prepare("prompt-file")
        path = case[0] / "task with spaces.txt"
        path.write_text("文件任务\nSecond line", encoding="utf-8")
        config = json.loads(case[3].read_text(encoding="utf-8"))
        del config["parameters"]["Prompt"]
        config["parameters"]["PromptFile"] = str(path)
        case[3].write_text(json.dumps(config), encoding="utf-8")
        completed, result = execute(case)
        self.assertEqual(completed.returncode, 0, result)
        self.assertEqual(result["response"], path.read_bytes().decode("utf-8"))

    def test_nonzero_exit_overrides_success_event(self):
        completed, result = execute(prepare("nonzero", "nonzero"))
        self.assertNotEqual(completed.returncode, 0)
        self.assertEqual(result["status"], "ERROR")
        self.assertEqual(result["exit_code"], 7)

    def test_relative_records_follow_powershell_location(self):
        case = prepare("relative-records")
        config = json.loads(case[3].read_text(encoding="utf-8"))
        config["caller_directory"] = str(case[0])
        config["parameters"]["RecordDirectory"] = ".records"
        case[3].write_text(json.dumps(config), encoding="utf-8")
        completed, result = execute(case)
        self.assertEqual(completed.returncode, 0, result)
        self.assertEqual(Path(result["run_directory"]).parent, case[0] / ".records")

    def test_missing_result(self):
        _, result = execute(prepare("missing", "missing"))
        self.assertEqual(result["error_kind"], "missing_result")

    def test_permission_denials(self):
        for mode in ("denied", "tool-denied"):
            with self.subTest(mode=mode):
                completed, result = execute(prepare(mode, mode))
                self.assertEqual(result["status"], "PARTIAL")
                self.assertNotEqual(completed.returncode, 0)

    def test_model_mismatch(self):
        _, result = execute(prepare("mismatch", "mismatch"))
        self.assertEqual(result["error_kind"], "model_mismatch")

    def test_authentication_and_quota_errors(self):
        for mode, expected in (("auth", "authentication_required"), ("quota", "quota_or_rate_limit")):
            with self.subTest(mode=mode):
                _, result = execute(prepare(mode, mode))
                self.assertEqual(result["error_kind"], expected)

    def test_non_json_progress(self):
        completed, result = execute(prepare("noise", "noise"))
        self.assertEqual(completed.returncode, 0, result)

    def test_timeout_stops_owned_process(self):
        case = prepare("timeout", "hang", timeout="0.1s")
        completed, result = execute(case)
        self.assertEqual(result["status"], "TIMEOUT")
        self.assertEqual(completed.returncode, 124)
        self.assertFalse(process_running(int((case[0] / "pid.txt").read_text())))

    def test_cancel_preserves_unrelated_process(self):
        case = prepare("cancel", "hang", timeout="20s")
        sentinel = subprocess.Popen([PWSH, "-NoProfile", "-Command", "Start-Sleep -Seconds 60"], creationflags=subprocess.CREATE_NO_WINDOW)
        child = subprocess.Popen(case[1], env=case[2], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding="utf-8")
        try:
            deadline = time.monotonic() + 15
            receipts = []
            while time.monotonic() < deadline:
                receipts = list(case[0].glob("work/antigravity/*/process.json"))
                if receipts:
                    break
                time.sleep(0.05)
            self.assertTrue(receipts, "Run did not start")
            process_info = json.loads(receipts[0].read_text(encoding="utf-8-sig"))
            (receipts[0].parent / "cancel").touch()
            stdout, stderr = child.communicate(timeout=15)
            result = json.loads(stdout)
            self.assertEqual(result["status"], "CANCELLED", stderr)
            self.assertEqual(child.returncode, 130)
            self.assertFalse(process_running(process_info["pid"]))
            self.assertIsNone(sentinel.poll())
        finally:
            for process in (child, sentinel):
                if process.poll() is None:
                    process.terminate()
                process.wait(timeout=10)

    def test_parallel_runs_have_distinct_records(self):
        cases = [prepare("parallel", prompt=marker) for marker in ("first", "second")]
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results = [item[1] for item in pool.map(execute, cases)]
        self.assertNotEqual(results[0]["run_directory"], results[1]["run_directory"])
        self.assertEqual({result["response"] for result in results}, {"first", "second"})

    def test_information_queries(self):
        completed, result = execute(prepare("info", action="All"))
        self.assertEqual(completed.returncode, 0, result)
        self.assertEqual(result["version"], "1.3.5-fixture")
        self.assertEqual(result["models"][0]["id"], "fixture-model")
        self.assertEqual(result["quota"][0]["remaining"], "75%")

    def test_unknown_quota_is_not_success(self):
        completed, result = execute(prepare("unknown-quota", "usage-unknown", action="Usage"))
        self.assertEqual(result["status"], "ERROR")
        self.assertNotEqual(completed.returncode, 0)
        self.assertEqual(result["quota"], [])
        self.assertIn("unavailable", result["usage_raw"])
