"""The ENTER-the-interface launcher (S68, behavior 6).

`lcars serve --open` boots the daemon on a FREE port, prints the resolved URL,
and opens the system browser at the board. The auto-open MUST be guarded so
tests never spawn a browser: it only opens when `--open` is passed AND
`LCARS_SERVE_NO_OPEN` is not set. `lcars serve` with no flag stays HEADLESS.

These tests drive __main__'s open decision directly (no real serve_forever) so
no browser is spawned and no port is held.
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from lcars_serve import __main__ as m  # noqa: E402


class LauncherOpenDecisionTest(unittest.TestCase):
    def test_no_flag_stays_headless(self):
        self.assertFalse(m.should_open(open_flag=False, env={}))

    def test_open_flag_opens(self):
        self.assertTrue(m.should_open(open_flag=True, env={}))

    def test_no_open_env_suppresses_even_with_flag(self):
        self.assertFalse(
            m.should_open(open_flag=True, env={"LCARS_SERVE_NO_OPEN": "1"}))

    def test_free_port_resolution_reads_back_assigned_port(self):
        # port 0 → the OS assigns a free port; make_server must bind and expose
        # the real port (the launcher prints it).
        from lcars_serve.server import make_server
        from lcars_serve.local_adapter import LocalAdapter
        import tempfile
        httpd = make_server(LocalAdapter(tempfile.mkdtemp()),
                            host="127.0.0.1", port=0, poll_interval=1.0)
        try:
            port = httpd.server_address[1]
            self.assertIsInstance(port, int)
            self.assertGreater(port, 0)
        finally:
            httpd.server_close()


if __name__ == "__main__":
    unittest.main()
