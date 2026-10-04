import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HELPER = os.path.join(REPO_ROOT, "helpers", "json_store.py")


def run(args, stdin=b"", state=None, cache=None):
    env = dict(os.environ)
    env["XDG_STATE_HOME"] = state
    env["XDG_CACHE_HOME"] = cache
    return subprocess.run([sys.executable, HELPER] + args, input=stdin, capture_output=True, env=env, timeout=10)


class JsonStoreTests(unittest.TestCase):
    def setUp(self):
        self._t = tempfile.TemporaryDirectory()
        self.state = os.path.join(self._t.name, "state")
        self.cache = os.path.join(self._t.name, "cache")

    def tearDown(self):
        self._t.cleanup()

    def test_read_missing_store_prints_empty_object(self):
        r = run(["read", "offsets"], state=self.state, cache=self.cache)
        self.assertEqual(r.returncode, 0)
        self.assertEqual(json.loads(r.stdout), {})

    def test_write_then_read_round_trips(self):
        payload = {"a|b|200": {"v": -300, "t": 1}}
        w = run(["write", "offsets"], json.dumps(payload).encode(), self.state, self.cache)
        self.assertEqual(w.returncode, 0, w.stderr)
        r = run(["read", "offsets"], state=self.state, cache=self.cache)
        self.assertEqual(json.loads(r.stdout), payload)

    def test_offsets_live_in_state_and_lyrics_in_cache(self):
        run(["write", "offsets"], b"{}", self.state, self.cache)
        run(["write", "lyrics"], b"{}", self.state, self.cache)
        self.assertTrue(os.path.isfile(os.path.join(self.state, "mini-cider", "offsets.json")))
        self.assertTrue(os.path.isfile(os.path.join(self.cache, "mini-cider", "lyrics.json")))

    def test_files_and_dirs_are_private(self):
        run(["write", "offsets"], b"{}", self.state, self.cache)
        d = os.path.join(self.state, "mini-cider")
        self.assertEqual(stat.S_IMODE(os.stat(d).st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(os.stat(os.path.join(d, "offsets.json")).st_mode), 0o600)

    def test_rejects_unknown_store_name_and_path_tricks(self):
        for name in ("token", "../offsets", "offsets.json", "", "/etc/passwd"):
            r = run(["write", name], b"{}", self.state, self.cache)
            self.assertEqual(r.returncode, 2, name)
        self.assertFalse(os.path.exists(os.path.join(self.state, "mini-cider", "token")))

    def test_rejects_invalid_json_and_non_object(self):
        for bad in (b"not json", b"[1,2]", b"\"x\"", b"\xff\xfe", b""):
            r = run(["write", "offsets"], bad, self.state, self.cache)
            self.assertEqual(r.returncode, 1, bad)
        self.assertFalse(os.path.exists(os.path.join(self.state, "mini-cider", "offsets.json")))

    def test_rejects_oversized_payload_and_keeps_previous_file(self):
        run(["write", "lyrics"], b'{"keep": 1}', self.state, self.cache)
        big = b'{"x": "' + b"a" * (17 * 1024 * 1024) + b'"}'
        r = run(["write", "lyrics"], big, self.state, self.cache)
        self.assertEqual(r.returncode, 1)
        self.assertEqual(json.loads(run(["read", "lyrics"], state=self.state, cache=self.cache).stdout), {"keep": 1})

    def test_read_ignores_a_symlinked_store_file(self):
        d = os.path.join(self.state, "mini-cider")
        os.makedirs(d, mode=0o700)
        target = os.path.join(self._t.name, "secret.json")
        with open(target, "w") as f:
            f.write('{"leak": 1}')
        os.symlink(target, os.path.join(d, "offsets.json"))
        r = run(["read", "offsets"], state=self.state, cache=self.cache)
        self.assertEqual(json.loads(r.stdout), {})

    def test_write_replaces_a_symlink_without_following_it(self):
        d = os.path.join(self.state, "mini-cider")
        os.makedirs(d, mode=0o700)
        target = os.path.join(self._t.name, "victim.json")
        with open(target, "w") as f:
            f.write("original")
        os.symlink(target, os.path.join(d, "offsets.json"))
        w = run(["write", "offsets"], b'{"a": 1}', self.state, self.cache)
        self.assertEqual(w.returncode, 0)
        with open(target) as f:
            self.assertEqual(f.read(), "original")
        self.assertFalse(os.path.islink(os.path.join(d, "offsets.json")))

    def test_read_of_corrupt_file_prints_empty_object(self):
        d = os.path.join(self.state, "mini-cider")
        os.makedirs(d, mode=0o700)
        with open(os.path.join(d, "offsets.json"), "w") as f:
            f.write("{broken")
        r = run(["read", "offsets"], state=self.state, cache=self.cache)
        self.assertEqual(r.returncode, 0)
        self.assertEqual(json.loads(r.stdout), {})


if __name__ == "__main__":
    unittest.main()
