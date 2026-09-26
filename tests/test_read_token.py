import os
import subprocess
import sys
import tempfile
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HELPER = os.path.join(REPO_ROOT, "helpers", "read_token.py")


def run_read(state_home, legacy_path=None):
    env = dict(os.environ)
    env["XDG_STATE_HOME"] = state_home
    args = [sys.executable, HELPER]
    if legacy_path is not None:
        args.append(legacy_path)
    return subprocess.run(args, capture_output=True, text=True, env=env, timeout=10)


class ReadTokenTests(unittest.TestCase):
    def test_reads_token_from_new_location(self):
        with tempfile.TemporaryDirectory() as state_home:
            d = os.path.join(state_home, "mini-cider")
            os.makedirs(d, mode=0o700)
            with open(os.path.join(d, "token"), "w") as f:
                f.write("my-token\n")
            proc = run_read(state_home)
            self.assertEqual(proc.returncode, 0)
            self.assertEqual(proc.stdout.strip(), "my-token")

    def test_returns_nothing_when_missing(self):
        with tempfile.TemporaryDirectory() as state_home:
            proc = run_read(state_home)
            self.assertEqual(proc.returncode, 0)
            self.assertEqual(proc.stdout.strip(), "")

    def test_legacy_fallback_read(self):
        with tempfile.TemporaryDirectory() as state_home, tempfile.TemporaryDirectory() as plugin_dir:
            legacy = os.path.join(plugin_dir, "cider_token.txt")
            with open(legacy, "w") as f:
                f.write("legacy-token")
            proc = run_read(state_home, legacy_path=legacy)
            self.assertEqual(proc.returncode, 0)
            self.assertEqual(proc.stdout.strip(), "legacy-token")

    def test_new_location_wins_over_legacy(self):
        with tempfile.TemporaryDirectory() as state_home, tempfile.TemporaryDirectory() as plugin_dir:
            d = os.path.join(state_home, "mini-cider")
            os.makedirs(d, mode=0o700)
            with open(os.path.join(d, "token"), "w") as f:
                f.write("new-token")
            legacy = os.path.join(plugin_dir, "cider_token.txt")
            with open(legacy, "w") as f:
                f.write("legacy-token")
            proc = run_read(state_home, legacy_path=legacy)
            self.assertEqual(proc.stdout.strip(), "new-token")

    def test_symlinked_token_file_not_followed(self):
        with tempfile.TemporaryDirectory() as state_home, tempfile.TemporaryDirectory() as outside:
            d = os.path.join(state_home, "mini-cider")
            os.makedirs(d, mode=0o700)
            secret = os.path.join(outside, "secret")
            with open(secret, "w") as f:
                f.write("secret-token")
            os.symlink(secret, os.path.join(d, "token"))
            proc = run_read(state_home)
            self.assertEqual(proc.returncode, 0)
            self.assertEqual(proc.stdout.strip(), "")

    def test_symlinked_legacy_not_followed(self):
        with tempfile.TemporaryDirectory() as state_home, tempfile.TemporaryDirectory() as plugin_dir, tempfile.TemporaryDirectory() as outside:
            secret = os.path.join(outside, "secret")
            with open(secret, "w") as f:
                f.write("secret-token")
            legacy = os.path.join(plugin_dir, "cider_token.txt")
            os.symlink(secret, legacy)
            proc = run_read(state_home, legacy_path=legacy)
            self.assertEqual(proc.returncode, 0)
            self.assertEqual(proc.stdout.strip(), "")

    def test_bounded_read_ignores_oversized_file(self):
        with tempfile.TemporaryDirectory() as state_home:
            d = os.path.join(state_home, "mini-cider")
            os.makedirs(d, mode=0o700)
            with open(os.path.join(d, "token"), "w") as f:
                f.write("x" * (4 * 1024 + 100))
            proc = run_read(state_home)
            self.assertEqual(proc.returncode, 0)
            self.assertLessEqual(len(proc.stdout.strip()), 4 * 1024)


    def test_oversized_token_rejected_not_truncated(self):
        # A token file larger than the cap must be rejected outright, never
        # silently truncated into a different token.
        with tempfile.TemporaryDirectory() as state_home:
            token_dir = os.path.join(state_home, "mini-cider")
            os.makedirs(token_dir, mode=0o700)
            with open(os.path.join(token_dir, "token"), "w") as f:
                f.write("a" * (4 * 1024 + 1))
            env = dict(os.environ)
            env["XDG_STATE_HOME"] = state_home
            proc = subprocess.run([sys.executable, HELPER], capture_output=True, text=True, env=env, timeout=10)
            self.assertEqual(proc.stdout.strip(), "")

if __name__ == "__main__":
    unittest.main()
