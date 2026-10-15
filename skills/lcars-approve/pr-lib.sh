# pr-lib.sh — the shared PR-open logic, sourced by both the Verify driver
# (skills/lcars-run/run.sh `open-pr`) and lcars approve (its legacy direct-open
# fallback). It is NOT executable on its own; a caller sources it and must have
# already set, in its own scope:
#
#   MISSION_DIR   the mission's .git/lcars/missions/<id> dir
#   STATE         $MISSION_DIR/state.json
#   MISSION_ID    the mission id
#   GIT_BIN       the git binary
#   GH_BIN        the gh binary
#   host()        the forge adapter seam: host <op> [args…]
#   json_str()    "key" string reader  (file key)
#   json_raw()    bare-token reader     (file key)
#   die()         the caller's error/exit
#
# The factoring exists so the title/body/manifest builders live in ONE place:
# extracting them here keeps approve.sh's byte-for-byte PR body (its tests assert
# the exact Goal/ADR/wave/Closes layout) while letting Verify auto-open the same
# PR. No behaviour changed when it moved out of approve.sh.

# Check current Git configuration, not a possibly stale baseFreshness reason.
# Only exit 1 proves absence; configured values and read errors keep existing advice.
pr_origin_guidance() {
  command -v "$GIT_BIN" >/dev/null 2>&1 || return 1
  if "$GIT_BIN" config --get remote.origin.url >/dev/null 2>&1; then
    return 1
  else
    local rc=$?
    [ "$rc" -eq 1 ] || return 1
  fi
  printf '%s\n' "this repo has no 'origin' remote — connect an existing hosted repo before retrying. Add its URL manually with: git remote add origin <repository-url>. Mission stays at verify."
}

# --- PR title: the PRD's `# Mission:` line, falling back to state.json title --
pr_title() {
  local t=""
  [ -f "$MISSION_DIR/prd.md" ] \
    && t="$(sed -n 's/^# Mission:[[:space:]]*//p' "$MISSION_DIR/prd.md" | head -1)"
  # S176 — a HEADING-FORM PRD (accepted since S176: a bare `Mission: <title>`
  # line, or `## Type` with the value beneath) has no `# Mission:` line for the
  # sed above. Fall back to the SAME both-shapes reader file.sh validates and
  # derives through, so the PR body cannot go quietly blank on a PRD file.sh
  # accepted. Purely additive: a bold-form PRD never reaches this line, so its
  # byte-for-byte PR body is unchanged.
  if [ -z "$t" ] && [ -f "$MISSION_DIR/prd.md" ] \
     && command -v lcars_prd_field >/dev/null 2>&1; then
    t="$(lcars_prd_field "$MISSION_DIR/prd.md" 'Mission' | head -1)"
  fi
  [ -n "$t" ] || t="$(json_str "$STATE" title)"
  printf '%s' "${t:-$MISSION_ID}"
}

# === A HUMAN PARAGRAPH IS NOT A PHYSICAL LINE ===============================
#
# WHAT WAS MEASURED (live, 2026-10-01). Every HUMAN-facing paragraph in the PR
# body stopped at its first physical SOURCE line. A Goal written as three
# hard-wrapped lines reached the captain as one; an ADR decision lost two
# thirds of its reasoning. The machine-written halves — the acceptance-criteria
# bullets, the wave manifest, the one-line fields — were intact, which is why
# nobody noticed: the PR body LOOKED complete.
#
# WHY IT LOOKED LIKE A COLUMN LIMIT, AND IS NOT. Of eleven observed cut points,
# eight sat at 78-81 characters, exactly like an 80-column budget. They are not.
# They are wherever the AUTHOR hard-wrapped, and most authors wrap at 80 — the
# three outliers (one cut at 14 characters, one at 28) are the disproof. The
# cause was a LINE-BASED READ, three of them:
#
#   `sed -n 's/^\*\*Goal:\*\*…//p' | head -1`   prints only the line that BEARS
#        the label, so a continuation line was never even a candidate.
#   the ADR awk, `d=$0` on /^\*\*Decision:\*\*/  one awk record is one line.
#   `_lcars_prd_read` (lcars-init/lcars-common.sh) returns the label line only,
#        or, for a heading-form section, "the first non-blank line under it" —
#        the heading-form fallback below used to come through it. It is STILL
#        line-based (its other callers read single-line fields and pipe through
#        `head -1`), but md_scan reads both PRD shapes, so the PR body no longer
#        goes anywhere near it.
#
# A width-based fix would have looked right on the eight and stayed wrong on the
# three. So this is the cure: ONE reader for every prose value this file shows
# the captain, and a wrap is a display choice that the reader undoes.
#
# md_scan <markdown-file> → tab-separated records, one per line, each VALUE
# already joined WHOLE:
#
#   H<TAB><heading>                  a `#`-marked heading, markers stripped
#   V<TAB><label><TAB><value>        a `**Label:**` inline value
#   S<TAB><heading><TAB><value>      the first paragraph under a bare heading
#
# A value runs from its own line through every CONTINUATION line and is joined
# with single spaces. A blank line, a heading, a list item/blockquote, or
# another `**Label:**` ends it — those start a new block, so they are the only
# real boundaries. ONE VALUE IS ONE OUTPUT LINE, however long, so a caller that
# pipes through `head -1` can no longer clip it.
md_scan() { # markdown-file
  [ -f "$1" ] || return 0
  awk '
    function trim(s) { gsub(/[ \t]+/, " ", s); sub(/^ /, "", s); sub(/ $/, "", s); return s }
    function emit() {
      if (mode != "") print mode "\t" lab "\t" trim(buf)
      mode = ""; lab = ""; buf = ""
    }
    {
      line = $0; sub(/\r$/, "", line)
      # a blank line closes the value in flight, but NOT an open section
      if (line ~ /^[ \t]*$/) { emit(); next }
      # a heading: closes any value, and opens a section whose first paragraph
      # is its value (the heading-form PRD shape)
      if (line ~ /^[ \t]{0,3}#{1,6}[ \t]/) {
        emit()
        h = line; sub(/^[ \t]*#+[ \t]*/, "", h); sub(/[ \t]*:[ \t]*$/, "", h)
        h = trim(h); sub(/^[*_`]+/, "", h); sub(/[*_`]+$/, "", h)
        print "H\t" h
        sect = h; next
      }
      # a bold inline label: **Label:** value…
      if (line ~ /^[ \t]*\*\*[^*]*:[ \t]*\*\*/) {
        emit()
        lab = line
        sub(/^[ \t]*\*\*[ \t]*/, "", lab); sub(/[ \t]*:[ \t]*\*\*.*$/, "", lab)
        buf = line
        sub(/^[ \t]*\*\*[^*]*:[ \t]*\*\*[ \t]*/, "", buf)
        mode = "V"; sect = ""; next
      }
      # a list item or blockquote is its own block, never a continuation
      if (line ~ /^[ \t]*([-*+>]|[0-9]+[.)])[ \t]/) { emit(); sect = ""; next }
      # a continuation of the value in flight
      if (mode != "") { buf = buf " " line; next }
      # the first paragraph under a bare heading IS that heading section value
      if (sect != "") { buf = line; lab = sect; mode = "S"; sect = ""; next }
    }
    END { emit() }
  ' "$1"
}

# md_value <scan-output> <label> → the WHOLE value for that label, bold-inline
# form preferred, heading-section form as the fallback. Case-insensitive on the
# label, exactly as the shared PRD reader is.
md_value() { # scan  label
  printf '%s\n' "$1" | awk -F'\t' -v want="$2" '
    BEGIN { want = tolower(want) }
    $1 == "V" && tolower($2) == want { print $3; found = 1; exit }
    $1 == "S" && tolower($2) == want && !s { s = $3 }
    END { if (!found && s != "") print s }
  '
}

# --- user-facing summary: PRD Goal + Acceptance Criteria --------------------
user_summary() {
  local prd="$MISSION_DIR/prd.md"
  [ -f "$prd" ] || return 0
  local goal crit scan
  # The Goal is PROSE the captain wrote, so it is read as a paragraph (md_scan),
  # never as the one source line that happens to carry the label.
  scan="$(md_scan "$prd")"
  goal="$(md_value "$scan" Goal)"
  crit="$(awk '
    /^\*\*Acceptance Criteria:\*\*/ { grab=1; next }
    grab && /^\*\*[^*]*:\*\*/       { grab=0 }
    grab && /^-[[:space:]]/         { print }
  ' "$prd")"
  # S176 — same additive fallback as pr_title, for the two fields this summary
  # reads. A bold-form PRD satisfies both greps above and never gets here.
  if [ -z "$goal" ] && command -v lcars_prd_field >/dev/null 2>&1; then
    goal="$(lcars_prd_field "$prd" 'Goal' | head -1)"
  fi
  if [ -z "$crit" ]; then
    crit="$(awk '
      /^([ \t]{0,3}#{1,6}[ \t]*)?[*_]{0,3}[Aa]cceptance [Cc]riteria[*_]{0,3}[ \t]*:?[ \t]*$/ { grab=1; next }
      grab && /^([ \t]{0,3}#{1,6}[ \t])/ { grab=0 }
      grab && /^[*_]{0,2}(Mission|Type|Goal|Out of Scope|Constraints)[*_]{0,2}[ \t]*:?/ { grab=0 }
      grab && /^-[[:space:]]/ { print }
    ' "$prd")"
  fi
  [ -n "$goal" ] || [ -n "$crit" ] || return 0
  printf '## User-facing summary\n\n'
  [ -n "$goal" ] && printf '%s\n' "$goal"
  [ -n "$crit" ] && printf '\nAcceptance criteria:\n\n%s\n' "$crit"
}

# --- technical summary: ADRs (preferred) or commit subjects (fallback) ------
tech_summary() {
  local adr="$MISSION_DIR/adr.md" body=""
  if [ -f "$adr" ]; then
    # Each ADR decision is PROSE too, so it comes through md_scan whole — the
    # old reader took `d=$0` on the /^\*\*Decision:\*\*/ line, and one awk record
    # is one line, so a wrapped decision lost everything after its first wrap.
    body="$(md_scan "$adr" | awk -F'\t' '
      $1 == "H" && $2 ~ /^ADR-/        { titles[++n] = $2; next }
      $1 == "V" && tolower($2) == "decision" {
        if (n > 0 && decisions[n] == "") decisions[n] = $3
        next
      }
      END {
        for (i=1;i<=n;i++)
          if (decisions[i] != "") printf "- **%s** — %s\n", titles[i], decisions[i]
          else                    printf "- **%s**\n", titles[i]
      }
    ')"
  fi
  if [ -z "$body" ] && [ -n "${BRANCH:-}" ]; then
    local range="$BRANCH"
    [ -n "${BASE:-}" ] && range="$BASE..$BRANCH"
    body="$("$GIT_BIN" log --no-merges --format='- %s' "$range" 2>/dev/null)"
  fi
  [ -n "$body" ] || return 0
  printf '## Technical summary\n\n'
  printf '%s\n' "$body"
}

# --- PR body: user + technical summaries, then a per-wave ticket manifest ----
pr_body() {
  local waves="$MISSION_DIR/waves.json" plan="$MISSION_DIR/approved-plan.json"
  local us ts
  us="$(user_summary)"
  ts="$(tech_summary)"

  if [ -n "$us" ]; then
    printf '%s\n' "$us"
  else
    printf '## Summary\n\n'
    printf 'Mission **%s** — implemented across its scheduled waves.\n' "$(pr_title)"
  fi
  [ -n "$ts" ] && printf '\n%s' "$ts"

  [ -f "$waves" ] || return 0

  awk -v plan="$plan" '
    BEGIN {
      while ((getline line < plan) > 0) {
        n = split(line, a, "\"")
        if (n >= 4 && a[2] == "id")    cid = a[4]
        if (n >= 4 && a[2] == "title") title[cid] = a[4]
      }
      close(plan)
    }
    /"wave"[[:space:]]*:/ { w=$0; gsub(/[^0-9]/,"",w); printf "\n### Wave %s\n", w; next }
    /"id"[[:space:]]*:/   { n=split($0,a,"\""); if (n>=4) { id=a[4]; printf "- `%s` — %s\n", id, (id in title ? title[id] : "") } }
  ' "$waves"
}

# --- the sub-issue numbers Schedule opened, one per line --------------------
sub_issues() {
  local waves="$MISSION_DIR/waves.json"
  [ -f "$waves" ] || return 0
  awk '
    /"issue"[[:space:]]*:/ {
      v=$0; sub(/.*"issue"[[:space:]]*:[[:space:]]*/,"",v); gsub(/[ ,}]/,"",v)
      if (v != "" && v != "null") print v
    }
  ' "$waves"
}

# --- open_pr: checkout + push + gh pr create, recording the result -----------
# The full PR-open orchestration shared by Verify (auto-open) and approve. It is
# IDEMPOTENT: if state.json already records a prUrl it opens NO second PR and
# returns 0, echoing the recorded URL. Otherwise it:
#   1. checks the mission branch out, requires commits ahead of base, pushes it,
#   2. opens the PR via host pr-create (title/body/Closes built above),
#   3. records prUrl + prNumber into state.json.
# On any precondition failure it `die`s (the caller's die — non-zero, no advance),
# so a card never lands "in review" with no PR behind it. Sets PR_URL on success.
#
# Requires (in the caller's scope, in addition to the readers above):
#   lcars_state_set_string()  the shared state.json writer (lcars-state.sh) —
#                  the caller sources it; pr-lib never carried its own.
# Reads BRANCH/BASE from the caller (set them, or this resolves from state).
open_pr() {
  # Resolve branch/base if the caller did not.
  [ -n "${BRANCH:-}" ] || BRANCH="$(json_str "$STATE" branch)"
  [ -n "${BASE:-}" ]   || BASE="$(json_str "$STATE" base)"
  BASE="${BASE:-main}"
  [ -n "$BRANCH" ] || die "mission has no branch on file — re-file it so it gets a branch. Mission stays at verify."

  # Idempotency: a recorded prUrl means the PR already exists → no second PR.
  local existing; existing="$(json_str "$STATE" prUrl)"
  case "$existing" in
    http*|*/pull/*) PR_URL="$existing"; return 0 ;;
  esac

  # S111 (root-tree sovereignty): the branch must EXIST, but it is NEVER checked
  # out here — `git push origin <branch>` and `gh pr create --head` are ref-based
  # and work from any checkout. The old checkout at this line was the last site
  # that moved the captain's working tree onto a mission branch (caught live at
  # 002's Verify boundary in the S111 proof drive).
  "$GIT_BIN" show-ref --verify --quiet "refs/heads/$BRANCH" \
    || die "mission branch '$BRANCH' does not exist — Implement never committed to it. Mission stays at verify."

  # Require commits ahead of the base — no content, no PR.
  local ahead; ahead="$("$GIT_BIN" rev-list --count "$BASE..$BRANCH" 2>/dev/null)"
  case "$ahead" in
    ''|0) die "no commits on '$BRANCH' ahead of '$BASE' — nothing to open a PR for. Mission stays at verify." ;;
  esac

  command -v "$GIT_BIN" >/dev/null 2>&1 \
    || die "git not found — cannot push '$BRANCH'. Mission stays at verify."
  local origin_guidance
  if origin_guidance="$(pr_origin_guidance)"; then
    die "$origin_guidance"
  fi
  "$GIT_BIN" push -u origin "$BRANCH" >/dev/null 2>&1 \
    || die "could not push '$BRANCH' to origin — push it and re-run. Mission stays at verify."

  local TITLE BODY
  TITLE="$(pr_title)"
  BODY="$(pr_body)"
  command -v "$GH_BIN" >/dev/null 2>&1 \
    || die "gh not found — cannot open the PR for '$BRANCH'. Mission stays at verify."

  # RULE B: the PR closes the parent + sub-issues on MERGE via Closes directives.
  local CLOSES=() seen_closes=" "
  add_close() {
    local n="$1"
    case "$n" in ''|null) return 0 ;; esac
    case "$seen_closes" in *" $n "*) return 0 ;; esac
    seen_closes="$seen_closes$n "
    CLOSES+=(--closes "$n")
  }
  local PARENT sub
  PARENT="$(json_raw "$STATE" githubIssue)"
  add_close "$PARENT"
  while IFS= read -r sub; do add_close "$sub"; done < <(sub_issues)

  PR_URL="$(host pr-create --head "$BRANCH" --base "$BASE" --title "$TITLE" --body "$BODY" ${CLOSES[@]+"${CLOSES[@]}"})"
  case "$PR_URL" in
    http*|*/pull/*) : ;;
    *) die "gh pr create did not return a PR URL for '$BRANCH' — open the PR by hand, then re-run. Mission stays at verify." ;;
  esac

  # Record the PR so the lifecycle is idempotent and the board can show it.
  local PR_NUM; PR_NUM="${PR_URL##*/}"
  lcars_state_set_string "$STATE" prUrl "$PR_URL"
  case "$PR_NUM" in
    ''|*[!0-9]*) : ;;
    *) lcars_state_set_string "$STATE" prNumber "$PR_NUM" ;;
  esac
  return 0
}
