"""Create a descendant that inherits the runner's pipes."""

import json
from pathlib import Path
import subprocess
import sys
import time


def main():
    sys.stdin.readline()
    child = subprocess.Popen(
        [sys.executable, "-c", "import time; time.sleep(60)"],
        stdout=sys.stdout,
        stderr=sys.stderr,
        close_fds=False,
    )
    Path("descendant.pid").write_text(str(child.pid), encoding="ascii")
    print(json.dumps({
        "event": "init",
        "conversation_id": "fixture-process-tree",
        "init": {"model": "fixture-model"},
    }), flush=True)
    if sys.argv[1] == "wait":
        time.sleep(60)


if __name__ == "__main__":
    main()
