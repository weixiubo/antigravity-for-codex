"""Exercise the shipped scripts against a local, account-free CLI fixture."""

import concurrent.futures
from contextlib import contextmanager
import ctypes
from ctypes import wintypes
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import unittest
import uuid

REPOSITORY = Path(__file__).resolve().parents[1]
FIXTURES = Path(__file__).resolve().parent / "fixtures"
PWSH = shutil.which("pwsh")
ARTIFACTS = Path(os.environ.get("ANTIGRAVITY_FOR_CODEX_TEST_ROOT", str(REPOSITORY / ".test-output"))) / uuid.uuid4().hex


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
    case_id = uuid.uuid4().hex
    case_file = workspace / f"case-{case_id}.json"
    case_file.write_text(json.dumps({"entry": str(REPOSITORY / "scripts" / entry), "parameters": parameters}, ensure_ascii=False), encoding="utf-8")
    command = [PWSH, "-NoProfile", "-File", str(FIXTURES / "invoke-case.ps1"), "-CaseFile", str(case_file)]
    environment = dict(os.environ, FAKE_AGY_MODE=mode, FAKE_PID_FILE=str(workspace / f"pid-{case_id}.txt"))
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



def wait_for(check, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        found = check()
        if found:
            return found
        time.sleep(0.025)
    raise AssertionError("Timed out waiting for the local fixture")


@contextmanager
def read_handle(path, share):
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.CreateFileW.argtypes = [
        wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, wintypes.LPVOID,
        wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE,
    ]
    kernel.CreateFileW.restype = wintypes.HANDLE
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    handle = kernel.CreateFileW(str(path), 0x80000000, share, None, 3, 0, None)
    if handle == ctypes.c_void_p(-1).value:
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        yield
    finally:
        kernel.CloseHandle(handle)


def set_parameters(case, **parameters):
    config = json.loads(case[3].read_text(encoding="utf-8"))
    config["parameters"].update(parameters)
    case[3].write_text(json.dumps(config), encoding="utf-8")
    return case


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
        self.assertTrue(result["conversation_id"])

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
        for mode, expected in (
            ("auth", "authentication_required"),
            ("quota", "quota_or_rate_limit"),
            ("structured-quota", "quota_or_rate_limit"),
        ):
            with self.subTest(mode=mode):
                _, result = execute(prepare(mode, mode))
                self.assertEqual(result["error_kind"], expected)

    def test_non_json_progress(self):
        completed, result = execute(prepare("noise", "noise"))
        self.assertEqual(completed.returncode, 0, result)

    def test_timeout_stops_owned_process(self):
        case = prepare("timeout", "hang-quota-noise", timeout="0.1s")
        completed, result = execute(case)
        self.assertEqual(result["status"], "TIMEOUT")
        self.assertEqual(completed.returncode, 124)
        self.assertEqual(result["error_kind"], "timeout")
        self.assertTrue(result["conversation_id"])
        self.assertFalse(process_running(int(Path(case[2]["FAKE_PID_FILE"]).read_text())))

    def test_cancel_preserves_unrelated_process(self):
        case = prepare("cancel", "hang-after-init", timeout="20s")
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
            events = receipts[0].parent / "events.jsonl"
            wait_for(lambda: events.exists() and '"init"' in events.read_text(encoding="utf-8"))
            (receipts[0].parent / "cancel").touch()
            stdout, stderr = child.communicate(timeout=15)
            result = json.loads(stdout)
            self.assertEqual(result["status"], "CANCELLED", stderr)
            self.assertEqual(child.returncode, 130)
            self.assertEqual(result["error_kind"], "cancelled")
            self.assertTrue(result["conversation_id"])
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
            completed_runs = list(pool.map(execute, cases))
        for completed, result in completed_runs:
            self.assertEqual(completed.returncode, 0, result)
        results = [result for _, result in completed_runs]
        self.assertNotEqual(results[0]["run_directory"], results[1]["run_directory"])
        self.assertEqual({result["response"] for result in results}, {"first", "second"})
        self.assertNotEqual(results[0]["conversation_id"], results[1]["conversation_id"])

    def test_protocol_errors(self):
        for mode in ("invalid-init", "invalid-result", "invalid-response", "duplicate-result"):
            with self.subTest(mode=mode):
                completed, result = execute(prepare(mode, mode))
                self.assertEqual(completed.returncode, 1, result)
                self.assertEqual(result["error_kind"], "protocol_error")

    def test_conversation_ids(self):
        for mode, expected in (
            ("success", "SUCCESS"),
            ("wrong-resume", "ERROR"),
            ("result-id-mismatch", "ERROR"),
        ):
            with self.subTest(mode=mode):
                case = prepare(mode, mode)
                conversation = "requested-fixture-session"
                if mode != "result-id-mismatch":
                    set_parameters(case, ConversationId=conversation)
                completed, result = execute(case)
                self.assertEqual(result["status"], expected)
                if expected == "SUCCESS":
                    self.assertEqual(completed.returncode, 0)
                    self.assertEqual(result["conversation_id"], conversation)
                else:
                    self.assertEqual(result["error_kind"], "conversation_mismatch")
                    self.assertIsNone(result["conversation_id"])

    def test_cli_timeout_exit_code(self):
        completed, result = execute(prepare("cli-timeout", "cli-timeout"))
        self.assertEqual(completed.returncode, 124)
        self.assertEqual(result["status"], "TIMEOUT")
        self.assertEqual(result["cli_status"], "TIMEOUT")
        self.assertTrue(result["conversation_id"])

    def test_unrelated_diagnostics_do_not_change_outcome(self):
        for mode, status, kind in (
            ("benign-diagnostics", "SUCCESS", None),
            ("error-noise", "ERROR", "cli_error"),
        ):
            with self.subTest(mode=mode):
                _, result = execute(prepare(mode, mode))
                self.assertEqual(result["status"], status)
                self.assertEqual(result["error_kind"], kind)
                self.assertFalse(result["permission_denied"])

    def test_early_cli_diagnostic_survives_a_closed_input_pipe(self):
        case = prepare("auth-before-stdin", "auth-before-stdin", prompt="x" * 2_000_000)
        completed, result = execute(case)
        self.assertEqual(completed.returncode, 1, result)
        self.assertEqual(result["error_kind"], "authentication_required")

    def prepare_process_tree(self, name, behavior):
        case = prepare(name, timeout="0.1s" if behavior == "exit" else "20s")
        return set_parameters(
            case, CliPath=sys.executable,
            CliPrefixArguments=["-B", str(FIXTURES / "process_cli.py"), behavior],
        )

    def test_timeout_cleans_descendant_after_cli_exits(self):
        case = self.prepare_process_tree("orphan-after-root-exit", "exit")
        pid_file = case[0] / "descendant.pid"
        try:
            completed, result = execute(case)
            self.assertEqual(completed.returncode, 124, result)
            self.assertEqual(result["exit_code"], 0)
            self.assertEqual(result["conversation_id"], "fixture-process-tree")
            self.assertFalse(process_running(int(pid_file.read_text(encoding="ascii"))))
        finally:
            if pid_file.exists():
                pid = int(pid_file.read_text(encoding="ascii"))
                if process_running(pid):
                    os.kill(pid, 15)

    def test_wrapper_exit_closes_its_job(self):
        case = self.prepare_process_tree("parent-exit", "wait")
        wrapper = subprocess.Popen(case[1], env=case[2], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        descendant_path = case[0] / "descendant.pid"
        try:
            receipt = wait_for(lambda: next(case[0].glob("work/antigravity/*/process.json"), None))
            root_pid = json.loads(receipt.read_text(encoding="utf-8"))["pid"]
            wait_for(lambda: descendant_path.exists() and descendant_path.stat().st_size)
            descendant = int(descendant_path.read_text(encoding="ascii"))
            self.assertTrue(process_running(root_pid))
            self.assertTrue(process_running(descendant))
            wrapper.terminate()
            wrapper.wait(timeout=5)
            wait_for(lambda: not process_running(root_pid) and not process_running(descendant), timeout=5)
        finally:
            if wrapper.poll() is None:
                wrapper.terminate()
                wrapper.wait(timeout=5)
            if descendant_path.exists() and descendant_path.stat().st_size:
                pid = int(descendant_path.read_text(encoding="ascii"))
                if process_running(pid):
                    os.kill(pid, 15)

    def test_final_result_replacement_and_logging_failure(self):
        for share, expected in ((0x5, "SUCCESS"), (0x1, "ERROR")):
            with self.subTest(share=share):
                case = prepare("replace-result-" + str(share), "wait-for-release", timeout="15s")
                wrapper = subprocess.Popen(
                    case[1], env=case[2], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                    text=True, encoding="utf-8",
                )
                try:
                    result_file = wait_for(lambda: next(case[0].glob("work/antigravity/*/result.json"), None))
                    with read_handle(result_file, share):
                        self.assertEqual(json.loads(result_file.read_text(encoding="utf-8"))["status"], "RUNNING")
                        (case[0] / "release").touch()
                        stdout, _ = wrapper.communicate(timeout=18)
                        result = json.loads(stdout)
                        self.assertEqual(result["status"], expected, result)
                        self.assertEqual(result["response"], 'Unicode: 中文\nQuoted: "value"')
                        final = json.loads(result_file.read_text(encoding="utf-8"))
                        if expected == "SUCCESS":
                            self.assertEqual(final["status"], "SUCCESS")
                        else:
                            self.assertEqual(result["cli_status"], "SUCCESS")
                            self.assertEqual(result["error_kind"], "log_write_failed")
                            self.assertTrue(result["log_errors"])
                finally:
                    if wrapper.poll() is None:
                        wrapper.terminate()
                        wrapper.wait(timeout=5)
                    wrapper.communicate()

    def test_setup_errors_distinguish_cli_and_workspace_paths(self):
        cases = [
            ({"CliPath": str(ARTIFACTS)}, "invalid_cli_path"),
            ({"Workspace": str(FIXTURES / "fake-cli.ps1")}, "invalid_workspace"),
        ]
        for parameters, kind in cases:
            for action in (None, "Models"):
                with self.subTest(kind=kind, action=action):
                    completed, result = execute(set_parameters(prepare(kind, action=action), **parameters))
                    self.assertEqual(completed.returncode, 1)
                    self.assertEqual(result["error_kind"], kind)
        case = prepare("missing-cli", action="Doctor")
        config = json.loads(case[3].read_text(encoding="utf-8"))
        del config["parameters"]["CliPath"]
        case[3].write_text(json.dumps(config), encoding="utf-8")
        case[2].update(LOCALAPPDATA=str(case[0] / "local-app-data"), PATH="")
        completed, result = execute(case)
        self.assertEqual(completed.returncode, 1)
        self.assertEqual(result["error_kind"], "cli_missing")

    def test_information_queries(self):
        completed, result = execute(prepare("info", action="All"))
        self.assertEqual(completed.returncode, 0, result)
        self.assertEqual(result["version"], "0.0.0-fixture")
        self.assertEqual(result["models"][0]["id"], "fixture-model")
        self.assertEqual(result["quota"][0]["remaining"], "75%")

    def test_unknown_quota_is_not_success(self):
        completed, result = execute(prepare("unknown-quota", "usage-unknown", action="Usage"))
        self.assertEqual(result["status"], "ERROR")
        self.assertNotEqual(completed.returncode, 0)
        self.assertEqual(result["quota"], [])
        self.assertIn("unavailable", result["usage_raw"])

    def test_invalid_quota_retains_other_query_results(self):
        completed, result = execute(prepare("invalid-quota", "usage-invalid", action="All"))
        self.assertEqual(completed.returncode, 1)
        self.assertEqual(result["status"], "ERROR")
        self.assertEqual(result["quota"], [])
        self.assertIn("101%", result["usage_raw"])
        self.assertIn("permission denied", result["usage_raw"])
        self.assertEqual(result["models"][0]["id"], "fixture-model")
        self.assertEqual(result["version"], "0.0.0-fixture")
        self.assertEqual([error["query"] for error in result["errors"]], ["usage"])

    def test_failed_model_query_does_not_publish_models(self):
        completed, result = execute(prepare("nonzero-models", "models-failed", action="All"))
        self.assertEqual(completed.returncode, 1)
        self.assertEqual(result["models"], [])
        self.assertIn("fixture-model", result["models_raw"])
        self.assertEqual(result["quota"][0]["remaining"], "75%")
        self.assertEqual(result["errors"][0]["exit_code"], 2)
