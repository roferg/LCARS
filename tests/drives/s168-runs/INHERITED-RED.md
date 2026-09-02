# S168 — the red we INHERITED, measured before any of this round's work

Measured on `fix/worker-fence` at its cut from `main` (c88e546), 2026-08-30:
**2275 web tests, 22 red — 17 errors + 5 failures.** None are in this round's
scope; none were cured here. They are written down so a later reader can tell
what this round did from what it merely ran on top of.

`worker-adapter` / `front-half-worktree` / `lcars-launch` were all GREEN at the
cut (141 PASS / 0 FAIL on lcars-launch).

## Known and explained — 19 of 22 (the fake-PNG fixture class)

All 17 errors, plus 2 of the 5 failures, are the image-paste class the
worker-fence doc's pre-flight predicted: the fixtures paste a FAKE PNG and the
hardened `_image_defect` correctly refuses an image that does not hold together.
**The feature is not broken; the fixtures are.** Suites: `test_align_endpoints`
(`ImagePaste*`, `ParkedSeedIsImagesOnly`), `test_log_session`,
`test_write_endpoints` (`LogTest` image routing).

The doc predicted 17; it is 19 now because tests were added after it was written.

## NOT explained by that class — 3 failures, and somebody should look

These are not fixture problems and they are not named in any doc. They are
REGRESSION GUARDS, which is what makes them worth writing down: each one exists
to catch a change nobody intended, and a guard that is already red cannot do
that job for anyone who comes next.

- `test_gh_host_links.GhHostMetaTest.test_github_com_payload_is_byte_identical_to_before_the_change`
- `test_gh_host_links.GhHostMetaTest.test_a_repo_with_no_remote_is_byte_identical_to_before_the_change`
      Two "byte-identical to before the change" guards on the GitHub host-links
      payload. Something changed that payload and these are how you would know.

- `test_help_console.ConsoleTitleGlyphTest.test_no_console_title_in_the_product_uses_an_emoji_glyph`
      `AssertionError: '⧉' not found in '▦▤▣▧▨▩◆◇◈●○◐▶▸▹✓⊹⌖⬢⬡⚡↩■' :
       console title '⧉ Duplicate program' opens with an off-family glyph`
      A console title shipped with a glyph outside the LCARS family. Cosmetic,
      but the guard is doing exactly what it was built to do and is being
      ignored.

Filed here rather than fixed: curing inherited defects inline is what turned a
one-session slice into a mini-round at S163 (7 of its 20 defects were inherited).
