"""S187 behaviour 5 — the VERIFIED url is what the board renders, and the two
new record fields are inert to it.

`launch.sh` now writes `predictedUrl` (what the discovery worker guessed) and,
when the observation disagreed, `urlNote`, beside the `url` it verified against
the app's real bound socket. That is a change to the RECORD, not to the front
end: the local adapter names the launch fields it publishes, so the additions
never reach the board, and board.js keeps linking `launch.url` — which is now
the observed address rather than a guess.
"""
import os
import re
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from lcars_serve.local_adapter import LocalAdapter  # noqa: E402
from tests import _fixtures as fx  # noqa: E402

WEB_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


class VerifiedLaunchUrlSurfaceTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        d = fx.plant_simple(self.tmp, "m-verified", stage="verify")
        # the shape launch.sh writes when the guess was WRONG: url observed,
        # prediction demoted, note explaining the difference.
        fx.write_json(os.path.join(d, "launch.json"), {
            "status": "running",
            "target": "the game",
            "url": "http://localhost:5174",
            "predictedUrl": "http://localhost:5173",
            "urlNote": ("the launch inspector predicted http://localhost:5173, "
                        "but the app is actually listening on "
                        "http://localhost:5174"),
            "message": "the app is running.",
        })

    def _card(self):
        for m in LocalAdapter(self.tmp).board()["missions"]:
            if m["id"] == "m-verified":
                return m
        self.fail("mission not on the board")

    def test_card_links_the_verified_url(self):
        self.assertEqual(self._card()["launch"]["url"], "http://localhost:5174")

    def test_detail_links_the_verified_url(self):
        detail = LocalAdapter(self.tmp).mission("m-verified")
        self.assertEqual(detail["launch"]["url"], "http://localhost:5174")

    def test_the_new_record_fields_are_not_published_to_the_front_end(self):
        # No front-end change was made, and none is needed: the adapter's launch
        # payload is an explicit field list, so predictedUrl/urlNote stop here.
        launch = self._card()["launch"]
        self.assertNotIn("predictedUrl", launch)
        self.assertNotIn("urlNote", launch)
        detail = LocalAdapter(self.tmp).mission("m-verified")["launch"]
        self.assertNotIn("predictedUrl", detail)
        self.assertNotIn("urlNote", detail)

    def test_board_js_still_links_launch_url_and_nothing_else(self):
        with open(os.path.join(WEB_DIR, "static", "board.js")) as fh:
            js = fh.read()
        self.assertIn("a.href = launch.url", js)
        self.assertFalse(re.search(r"\bpredictedUrl\b", js),
                         "the renderer must stay ignorant of predictedUrl")
        self.assertFalse(re.search(r"\burlNote\b", js),
                         "the renderer must stay ignorant of urlNote")


if __name__ == "__main__":
    unittest.main()
