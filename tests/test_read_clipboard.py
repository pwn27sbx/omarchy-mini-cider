import os
import stat
import subprocess
import sys
import tempfile
import time
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HELPER = os.path.join(REPO_ROOT, "helpers", "read_clipboard.py")


def fake_wl_paste(bin_dir, script_body):
    """Install a fake wl-paste on PATH that runs the given Python body."""
    path = os.path.join(bin_dir, "wl-paste")
    with open(path, "w") as f:
        f.write("#!" + sys.executable + "\n")
        f.write("import sys, time\n")
        f.write(script_body)
    os.chmod(path, stat.S_IRWXU)


def run_read(bin_dir, timeout=10):
    env = dict(os.environ)
    env["PATH"] = bin_dir + os.pathsep + env.get("PATH", "")
    return subprocess.run(
        [sys.executable, HELPER],
        capture_output=True,
        env=env,
        timeout=timeout,
    )


class ReadClipboardTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.bin_dir = self.tmp.name

    def test_prints_trimmed_token(self):
        fake_wl_paste(self.bin_dir, "sys.stdout.write('  secret-token-123 \\n')\n")
        proc = run_read(self.bin_dir)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout, b"secret-token-123\n")

    def test_valid_token_survives_slow_exit_after_eof(self):
        # wl-paste closes stdout first and exits a little later; that must
        # not be treated as a failure.
        fake_wl_paste(
            self.bin_dir,
            "import os\n"
            "sys.stdout.write('secret-token-123')\n"
            "sys.stdout.flush()\n"
            "os.close(1)\n"
            "time.sleep(0.2)\n",
        )
        proc = run_read(self.bin_dir)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout, b"secret-token-123\n")

    def test_endless_clipboard_is_rejected_without_reading_it_all(self):
        # A payload that never ends: the helper must stop at its byte cap,
        # kill wl-paste, and fail fast instead of buffering the stream.
        fake_wl_paste(
            self.bin_dir,
            "chunk = 'A' * 65536\n"
            "while True:\n"
            "    sys.stdout.write(chunk)\n"
            "    sys.stdout.flush()\n",
        )
        started = time.monotonic()
        proc = run_read(self.bin_dir)
        self.assertNotEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout, b"")
        self.assertLess(time.monotonic() - started, 2.0)

    def test_payload_just_over_byte_cap_is_rejected(self):
        fake_wl_paste(self.bin_dir, "sys.stdout.write('A' * 4097)\n")
        proc = run_read(self.bin_dir)
        self.assertNotEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout, b"")

    def test_token_longer_than_512_chars_is_rejected(self):
        fake_wl_paste(self.bin_dir, "sys.stdout.write('A' * 513)\n")
        proc = run_read(self.bin_dir)
        self.assertNotEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout, b"")

    def test_token_of_exactly_512_chars_is_accepted(self):
        fake_wl_paste(self.bin_dir, "sys.stdout.write('A' * 512)\n")
        proc = run_read(self.bin_dir)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout, b"A" * 512 + b"\n")

    def test_control_characters_are_rejected(self):
        fake_wl_paste(self.bin_dir, "sys.stdout.write('abc\\x1bdef')\n")
        proc = run_read(self.bin_dir)
        self.assertNotEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout, b"")

    def test_multiline_clipboard_is_rejected(self):
        fake_wl_paste(self.bin_dir, "sys.stdout.write('line1\\nline2')\n")
        proc = run_read(self.bin_dir)
        self.assertNotEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout, b"")

    def test_invalid_utf8_is_rejected(self):
        fake_wl_paste(self.bin_dir, "sys.stdout.buffer.write(b'\\xff\\xfe')\n")
        proc = run_read(self.bin_dir)
        self.assertNotEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout, b"")

    def test_empty_clipboard_is_rejected(self):
        fake_wl_paste(self.bin_dir, "sys.exit(1)\n")
        proc = run_read(self.bin_dir)
        self.assertNotEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout, b"")

    def test_hanging_wl_paste_times_out(self):
        fake_wl_paste(self.bin_dir, "time.sleep(30)\n")
        started = time.monotonic()
        proc = run_read(self.bin_dir)
        self.assertNotEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout, b"")
        self.assertLess(time.monotonic() - started, 5.0)

    def test_missing_wl_paste_fails_cleanly(self):
        env = dict(os.environ)
        env["PATH"] = self.bin_dir
        proc = subprocess.run([sys.executable, HELPER], capture_output=True,
                              env=env, timeout=10)
        self.assertNotEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout, b"")


if __name__ == "__main__":
    unittest.main()
