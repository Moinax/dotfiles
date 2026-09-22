"""Exercise terminal discovery without opening or focusing desktop windows."""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TERM = ROOT / "home/dot_local/bin/executable_term"


class TermTest(unittest.TestCase):
    def setUp(self):
        scratch = ROOT / ".scratch"
        scratch.mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix="test-term-", dir=scratch)
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.log = self.directory / "calls"
        self.env = {
            **os.environ,
            "PATH": f"{self.directory}:{os.environ['PATH']}",
            "LD_LIBRARY_PATH": "/project/nix/lib",
            "TEST_STATE": str(self.directory),
            "TEST_MODE": "present",
        }
        self.command("hyprctl", '''
[[ -z "${LD_LIBRARY_PATH+x}" ]] || exit 90
echo "$1" >> "$TEST_STATE/calls"
case "$1" in
    clients)
        case "$TEST_MODE" in
            failed) echo "connection failed" >&2; exit 1 ;;
            malformed) echo 'not json'; exit ;;
            empty) exit ;;
            object) echo '{}'; exit ;;
            absent)
                if [[ ! -f "$TEST_STATE/launched" ]]; then
                    echo '[]'; exit
                fi ;;
        esac
        echo '[{"class":"zellij","workspace":{"id":-99}}]'
        ;;
    activewindow) echo '{"class":"zellij"}' ;;
    *) exit 91 ;;
esac
''')
        # Intercept the launcher itself: no process can reach a real Kitty.
        self.command("setsid", '''
echo "launch $*" >> "$TEST_STATE/calls"
[[ "$LD_LIBRARY_PATH" == /project/nix/lib ]] || exit 92
touch "$TEST_STATE/launched"
''')

    def command(self, name, body):
        path = self.directory / name
        path.write_text("#!/bin/bash\nset -eu\n" + body)
        path.chmod(0o755)

    def run_term(self, mode):
        return subprocess.run(
            ["bash", str(TERM)], env={**self.env, "TEST_MODE": mode},
            capture_output=True, text=True, timeout=10, check=False,
        )

    def test_existing_scratchpad_window_from_project_shell(self):
        result = self.run_term("present")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("launch", self.log.read_text())

    def test_lookup_errors_never_launch(self):
        for mode in ("failed", "malformed", "empty", "object"):
            with self.subTest(mode=mode):
                result = self.run_term(mode)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("refusing to open another terminal", result.stderr)
                self.assertNotIn("launch", self.log.read_text())

    def test_missing_window_launches_once_and_preserves_project_environment(self):
        result = self.run_term("absent")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.log.read_text().count("launch "), 1)
        self.assertIn("kitty --class zellij zellij attach -c main", self.log.read_text())


if __name__ == "__main__":
    unittest.main()
