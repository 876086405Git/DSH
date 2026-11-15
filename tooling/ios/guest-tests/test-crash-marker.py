#!/usr/bin/env python3
"""Real POSIX marker tests. These do not claim iSH or Apple execution."""
import pathlib
import shutil
import signal
import subprocess
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent


class CrashMarkerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory(prefix='guest-crash-build-')
        cls.binary = pathlib.Path(cls.build.name) / 'crash-marker'
        subprocess.run([shutil.which('cc') or 'cc', '-std=c11', '-Wall', '-Wextra',
                        '-Werror', '-O2', str(HERE / 'crash-marker.c'), '-o',
                        str(cls.binary)], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.build.cleanup()

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='guest-crash-case-')
        self.base = pathlib.Path(self.temporary.name)

    def tearDown(self):
        self.temporary.cleanup()

    def run_case(self, mode, directory=None):
        return subprocess.check_output([str(self.binary), mode,
                                        str(directory or self.base)], text=True,
                                       timeout=10).strip()

    def test_killed_owner_pauses_next_process_until_explicit_resume(self):
        child = subprocess.Popen([str(self.binary), 'hold', str(self.base)],
                                 stdout=subprocess.PIPE, text=True)
        try:
            self.assertEqual(child.stdout.readline().strip(), 'durable')
            payload = (self.base / 'active-task').read_text()
            self.assertEqual(payload, 'dsh-guest-task 1\ngeneration 41\nstage task\n')
            child.send_signal(signal.SIGKILL)
            self.assertEqual(child.wait(timeout=10), -signal.SIGKILL)
            self.assertEqual(self.run_case('status'), '1')
            self.run_case('rejected')
            self.assertEqual((self.base / 'active-task').read_text(), payload)
            self.run_case('resume')
            self.assertEqual(self.run_case('status'), '0')
            self.run_case('roundtrip')
        finally:
            if child.poll() is None:
                child.kill()
                child.wait(timeout=10)
            child.stdout.close()

    def test_live_generation_ownership_and_descriptor_release(self):
        self.run_case('roundtrip')

    def test_short_writes_and_eintr(self):
        self.run_case('short-write')

    def test_no_entry_after_file_fsync_failure(self):
        self.run_case('file-fsync')

    def test_no_entry_after_directory_fsync_failure(self):
        self.run_case('dir-fsync')

    def test_truncated_write_requires_explicit_resume(self):
        self.run_case('write-failure')

    def test_settle_never_removes_a_replaced_inode(self):
        self.run_case('replaced')

    def test_unsettled_owner_leaves_pause_record(self):
        self.run_case('unsettled')
        self.assertEqual(self.run_case('status'), '1')

    def test_absent_directory_is_clear(self):
        missing = self.base / 'not-installed'
        self.assertEqual(self.run_case('status', missing), '0')
        self.run_case('resume', missing)
        self.assertFalse(missing.exists())

    def test_symlink_is_suspension_not_a_writable_target(self):
        victim = self.base / 'synthetic-user-file'
        victim.write_text('retain this synthetic content')
        (self.base / 'active-task').symlink_to(victim)
        self.run_case('rejected')
        self.assertEqual(victim.read_text(), 'retain this synthetic content')
        self.run_case('resume')
        self.assertEqual(victim.read_text(), 'retain this synthetic content')


if __name__ == '__main__':
    unittest.main(verbosity=2)
