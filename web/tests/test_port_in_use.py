"""S187 behaviour 6 — a CIVIL refusal when the board's port is already taken.

Plain `lcars viewscreen` binds the fixed 8765 (only `--open` picks a free port).
A second one therefore died inside `make_server` on a raw `OSError:
[Errno 48] Address already in use` traceback — no message, no fix, no test.

The bind is now guarded PORT-AGNOSTICALLY: any occupied port raises
`PortInUseError`, and `__main__.main` turns that into ONE plain line in the
LCARS voice (naming the port, best-effort naming the holder, and giving both
escapes) plus a non-zero exit. Every test here occupies a SCRATCH port it opens
itself — never 8765, which may well be held by something the operator is using.
"""
import io
import os
import socket
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from lcars_serve import __main__ as m  # noqa: E402
from lcars_serve.server import make_server, PortInUseError  # noqa: E402
from lcars_serve.local_adapter import LocalAdapter  # noqa: E402


class _Occupied(object):
    """A scratch localhost port held open for the duration of a `with` block."""

    def __enter__(self):
        self.sock = socket.socket()
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen(1)
        self.port = self.sock.getsockname()[1]
        return self

    def __exit__(self, *a):
        self.sock.close()
        return False


class PortInUseTest(unittest.TestCase):
    def _adapter(self):
        return LocalAdapter(tempfile.mkdtemp())

    def test_occupied_port_raises_the_typed_error_not_a_bare_oserror(self):
        with _Occupied() as held:
            with self.assertRaises(PortInUseError) as ctx:
                make_server(self._adapter(), host="127.0.0.1", port=held.port)
            self.assertEqual(ctx.exception.port, held.port)

    def test_the_refusal_is_one_plain_line_naming_port_and_both_fixes(self):
        with _Occupied() as held:
            try:
                make_server(self._adapter(), host="127.0.0.1", port=held.port)
                self.fail("expected PortInUseError")
            except PortInUseError as exc:
                line = exc.lcars_line()
        self.assertEqual(len(line.splitlines()), 1, "must be ONE line")
        self.assertIn(str(held.port), line)
        self.assertIn("--open", line)
        self.assertIn("--port", line)
        self.assertNotIn("Traceback", line)

    def test_the_holder_is_named_best_effort(self):
        # This process holds the socket, so the holder lookup must find a
        # command name (lsof reports the python binary). Best-effort by
        # contract: an empty answer is allowed, a crash is not.
        with _Occupied() as held:
            holder = m and None  # keep flake8 quiet about the import
            from lcars_serve.server import port_holder
            holder = port_holder(held.port)
        self.assertIsInstance(holder, str)
        self.assertTrue(holder, "lsof should name this process as the holder")

    def test_main_exits_non_zero_with_the_line_and_no_traceback(self):
        with _Occupied() as held:
            err = io.StringIO()
            real = sys.stderr
            sys.stderr = err
            try:
                rc = m.main(["--host", "127.0.0.1", "--port", str(held.port),
                             "--repo-root", tempfile.mkdtemp(), "--read-only"])
            finally:
                sys.stderr = real
        self.assertNotEqual(rc, 0)
        out = err.getvalue()
        self.assertNotIn("Traceback", out)
        self.assertEqual(len([l for l in out.splitlines() if l.strip()]), 1)
        self.assertIn(str(held.port), out)
        self.assertIn("--open", out)

    def test_a_free_port_is_untouched_by_the_guard(self):
        # The --open free-port path (port 0) must be completely unaffected.
        httpd = make_server(self._adapter(), host="127.0.0.1", port=0)
        try:
            self.assertGreater(httpd.server_address[1], 0)
        finally:
            httpd.server_close()


if __name__ == "__main__":
    unittest.main()
