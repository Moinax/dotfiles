"""Exercise dev's session gate without a real zellij or terminal."""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEV = ROOT / "home/dot_local/bin/executable_dev"


class DevTest(unittest.TestCase):
    def setUp(self):
        scratch = ROOT / ".scratch"
        scratch.mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix="test-dev-", dir=scratch)
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.project = self.directory / "proj"
        self.project.mkdir()
        self.log = self.directory / "calls"
        self.log.touch()
        self.env = {
            **os.environ,
            "PATH": f"{self.directory}:{os.environ['PATH']}",
            "TEST_STATE": str(self.directory),
        }
        # A client counts once "$TEST_STATE/attached" exists; "nosession" makes
        # every call fail the way zellij does with no server at all.
        self.command("zellij", '''
shift 3  # -s main action
echo "$1" >> "$TEST_STATE/calls"
[[ -f "$TEST_STATE/nosession" && ! -f "$TEST_STATE/attached" ]] && exit 1
case "$1" in
    list-clients)
        echo "CLIENT_ID ZELLIJ_PANE_ID RUNNING_COMMAND"
        [[ -f "$TEST_STATE/attached" ]] && echo "1         terminal_0     N/A"
        ;;
    new-tab) echo 3 ;;
    list-panes) echo '[]' ;;
esac
''')
        # `term` attaches a client only when the test says a Kitty would.
        self.command("term", '''
echo "term" >> "$TEST_STATE/calls"
[[ -f "$TEST_STATE/term-attaches" ]] && touch "$TEST_STATE/attached"
exit 0
''')

    def command(self, name, body):
        path = self.directory / name
        path.write_text("#!/bin/bash\nset -eu\n" + body)
        path.chmod(0o755)

    def flag(self, *names):
        for name in names:
            (self.directory / name).touch()

    def run_dev(self):
        result = subprocess.run(
            ["bash", str(DEV), str(self.project)], env=self.env,
            capture_output=True, text=True, timeout=15, check=False,
        )
        return result, self.log.read_text().split()

    def test_attached_client_skips_the_launch(self):
        self.flag("attached")
        result, calls = self.run_dev()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls.count("term"), 1)  # only the final raise
        self.assertIn("new-tab", calls)

    def test_live_server_without_client_launches_before_new_tab(self):
        for extra in ((), ("nosession",)):
            with self.subTest(nosession=bool(extra)):
                for name in ("attached", "nosession", "calls"):
                    (self.directory / name).unlink(missing_ok=True)
                self.log.touch()
                self.flag("term-attaches", *extra)
                result, calls = self.run_dev()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertLess(calls.index("term"), calls.index("new-tab"))

    def test_client_that_never_attaches_creates_no_tab(self):
        result, calls = self.run_dev()
        self.assertEqual(result.returncode, 1)
        self.assertIn("no zellij client attached", result.stderr)
        self.assertNotIn("new-tab", calls)


if __name__ == "__main__":
    unittest.main()
