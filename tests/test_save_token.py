import os
import stat
import subprocess
import sys
import tempfile
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HELPER = os.path.join(REPO_ROOT, "helpers", "save_token.py")


def run_save(token_bytes, state_home, legacy_path=None, env_extra=None):
    env = dict(os.environ)
    env["XDG_STATE_HOME"] = state_home
    if env_extra:
        env.update(env_extra)
    args = [sys.executable, HELPER]
    if legacy_path is not None:
        args.append(legacy_path)
    return subprocess.run(
        args,
        input=token_bytes,
        capture_output=True,
        env=env,
        timeout=10,
    )


class SaveTokenTests(unittest.TestCase):
    def test_saves_token_from_stdin(self):
        with tempfile.TemporaryDirectory() as state_home:
            proc = run_save(b"secret-token-123\n", state_home)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            token_path = os.path.join(state_home, "mini-cider", "token")
            with open(token_path, "rb") as f:
                self.assertEqual(f.read(), b"secret-token-123")

    def test_token_never_read_from_argv_or_env(self):
        # The helper must not accept a token via CIDER_TOKEN or argv; only stdin.
        with tempfile.TemporaryDirectory() as state_home:
            proc = run_save(
                b"",
                state_home,
                legacy_path=None,
                env_extra={"CIDER_TOKEN": "env-leaked-token"},
            )
            self.assertNotEqual(proc.returncode, 0)
            token_path = os.path.join(state_home, "mini-cider", "token")
            self.assertFalse(os.path.exists(token_path))

    def test_empty_token_rejected(self):
        with tempfile.TemporaryDirectory() as state_home:
            proc = run_save(b"   \n", state_home)
            self.assertNotEqual(proc.returncode, 0)

    def test_oversized_token_rejected(self):
        with tempfile.TemporaryDirectory() as state_home:
            oversized = b"a" * (4 * 1024 + 1)
            proc = run_save(oversized, state_home)
            self.assertNotEqual(proc.returncode, 0)
            token_path = os.path.join(state_home, "mini-cider", "token")
            self.assertFalse(os.path.exists(token_path))

    def test_control_characters_rejected(self):
        with tempfile.TemporaryDirectory() as state_home:
            proc = run_save(b"bad\x01token", state_home)
            self.assertNotEqual(proc.returncode, 0)

    def test_dir_created_0700_and_file_0600(self):
        with tempfile.TemporaryDirectory() as state_home:
            proc = run_save(b"tok\n", state_home)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            dir_path = os.path.join(state_home, "mini-cider")
            file_path = os.path.join(dir_path, "token")
            self.assertEqual(stat.S_IMODE(os.stat(dir_path).st_mode), 0o700)
            self.assertEqual(stat.S_IMODE(os.stat(file_path).st_mode), 0o600)

    def test_symlinked_state_dir_refused(self):
        with tempfile.TemporaryDirectory() as state_home, tempfile.TemporaryDirectory() as outside:
            link_path = os.path.join(state_home, "mini-cider")
            os.symlink(outside, link_path)
            proc = run_save(b"tok\n", state_home)
            self.assertNotEqual(proc.returncode, 0)
            self.assertFalse(os.path.exists(os.path.join(outside, "token")))

    def test_symlinked_token_file_not_overwritten_in_place(self):
        # Writing must not follow a symlink at the destination path -- the
        # atomic replace swaps the directory entry rather than the target.
        with tempfile.TemporaryDirectory() as state_home, tempfile.TemporaryDirectory() as outside:
            dir_path = os.path.join(state_home, "mini-cider")
            os.makedirs(dir_path, mode=0o700)
            target = os.path.join(outside, "secret")
            with open(target, "w") as f:
                f.write("original")
            link_path = os.path.join(dir_path, "token")
            os.symlink(target, link_path)

            proc = run_save(b"new-token\n", state_home)
            self.assertEqual(proc.returncode, 0, proc.stderr)

            # The outside target must be untouched.
            with open(target) as f:
                self.assertEqual(f.read(), "original")
            # The token path must now be a regular file, not the symlink.
            self.assertFalse(os.path.islink(link_path))
            with open(link_path) as f:
                self.assertEqual(f.read(), "new-token")

    def test_atomic_replace_no_partial_file(self):
        with tempfile.TemporaryDirectory() as state_home:
            proc = run_save(b"tok\n", state_home)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            dir_path = os.path.join(state_home, "mini-cider")
            names = os.listdir(dir_path)
            self.assertEqual(names, ["token"])

    def test_legacy_file_removed_when_regular_and_owned(self):
        with tempfile.TemporaryDirectory() as state_home, tempfile.TemporaryDirectory() as plugin_dir:
            legacy = os.path.join(plugin_dir, "cider_token.txt")
            with open(legacy, "w") as f:
                f.write("old-token")
            proc = run_save(b"new-token\n", state_home, legacy_path=legacy)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertFalse(os.path.exists(legacy))

    def test_legacy_symlink_not_deleted_and_target_untouched(self):
        with tempfile.TemporaryDirectory() as state_home, tempfile.TemporaryDirectory() as plugin_dir, tempfile.TemporaryDirectory() as outside:
            target = os.path.join(outside, "real_token.txt")
            with open(target, "w") as f:
                f.write("real-old-token")
            legacy = os.path.join(plugin_dir, "cider_token.txt")
            os.symlink(target, legacy)

            proc = run_save(b"new-token\n", state_home, legacy_path=legacy)
            self.assertEqual(proc.returncode, 0, proc.stderr)

            self.assertTrue(os.path.islink(legacy))
            with open(target) as f:
                self.assertEqual(f.read(), "real-old-token")


if __name__ == "__main__":
    unittest.main()
