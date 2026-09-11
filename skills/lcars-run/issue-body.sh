#!/usr/bin/env bash
#
# issue-body.sh — Session 188. THE ONE COMPOSER for a Mission's GitHub issue
# body, plus the `lcars:handoff` envelope that makes that body machine-readable,
# plus the parse helper that reads the envelope back.
#
# This file is SOURCED (never executed). It defines functions and runs nothing at
# source time, so `lcars file`, `lcars run` and any later verb can all share the
# SAME composition. Its only hard dependency is a mission directory on disk.
#
# ---------------------------------------------------------------------------
# WHY A COMPOSER AT ALL
# ---------------------------------------------------------------------------
# Before S188 the issue body was composed INLINE at every filing lane — in
# skills/lcars-file/file.sh the park lane, the --complete lane (which both EDITs
# an existing issue and CREATEs one when gh was down at park time), and the
# grill-first --prd lane; and in skills/lcars-log/log.sh the logged-bug lane, the
# FIFTH. Inline variants of "prd → adr → Estimate" drift the moment one of them
# is touched, and nothing could refresh a body afterwards because no caller knew
# how to rebuild one. One function fixes both.
#
# ALL FIVE lanes now compose here. The log lane is the only one that emits a
# lead-in above the PRD (`> 🐞 Logged via …`) and the only one whose envelope
# ever carries a non-null `parentIssue`; both come out of lcars_ib_provenance and
# the envelope's overrides, so its VISIBLE body is byte-identical to what it
# emitted inline, modulo the appended envelope — the parity contract every lane
# holds.
#
# ---------------------------------------------------------------------------
# WHY THE BODY IS REFRESHED AT EXACTLY TWO POINTS — AND NOWHERE ELSE
# ---------------------------------------------------------------------------
# The captain's v1 boundary is THE ENDS OF THE PIPELINE, not every stage:
#
#     (1) the feedback re-grill completion  — the align re-entry finisher
#         (skills/lcars-run/run.sh, cmd_research, when feedback.md is present)
#     (2) Verify entry
#         (skills/lcars-run/run.sh, drive_verify, before the PR block)
#
# Those are the two moments where ANOTHER machine legitimately picks the mission
# up from GitHub alone: a laptop adopting a bounced mission must build the NEW
# spec, and a reviewer arriving at Verify must read the spec that was actually
# built. Everything in between — Research findings, plan.json, ticket state — is
# LOCAL richness under `.git/lcars/`, deliberately NOT synced (the mid-pipeline
# handoff is ledgered, not solved). So MID-FLIGHT BODIES GO STALE BY DESIGN.
# That is the contract, not an oversight: do NOT add a per-stage refresh.
#
# A refresh is also SKIPPED when the composed body is byte-identical to the one
# this repo last pushed for that mission ($MISSION_DIR/.issue-body.sha). That is
# what keeps a reconcile re-entry at Verify from spamming edits, and it makes the
# refresh a self-healing retry: a push that FAILED writes no marker, so the next
# transfer point tries again.
#
# And a push is an unconditional REPLACE, so a half-restored mission dir could
# otherwise delete the spec, or the whole "## Estimate" section (and with it
# every board pill), off GitHub for good. A refresh therefore resolves the body
# PART BY PART before it composes anything — each part rebuilt from its source,
# carried forward verbatim from the last pushed body, or named in a refusal. See
# "PART-AWARE COMPOSITION" further down; nothing measures the finished text.
#
# ---------------------------------------------------------------------------
# THE HANDOFF ENVELOPE
# ---------------------------------------------------------------------------
# Every composed body ends with ONE HTML comment, on ONE line, carrying
# schema-versioned JSON:
#
#   <!-- lcars:handoff v1 {"id":…,"branch":…,"base":…,"type":…,"engine":…,
#        "parentIssue":…,"attachments":N} -->            (all on one line)
#
# It is invisible on github.com and it is the ONLY machine-readable contract in
# the body — the github board adapter still regex-scrapes the human "## Estimate"
# section (web/lcars_serve/github_adapter.py `_pills_from_body`), which is why
# the envelope is APPENDED and changes not one byte above it.
#
# Values come from the mission's own state.json — the same resolution that wrote
# them. `engine` is state.json's `workerBin` (the ONE precedence order:
# --engine > $LCARS_WORKER_BIN > carried-forward, see file.sh `_resolve_worker_bin`)
# reduced to its basename; ABSENT workerBin means host-detect is in charge, and
# the envelope says `null` rather than guessing. A caller that legitimately knows
# better than state.json — `lcars file --complete`, which composes BEFORE it
# clears `prdPending` and therefore before `type`/`workerBin` are final — passes
# `key=value` overrides.
#
# A PARK body (an idea with no PRD yet) carries `"parked":true`, so a reader can
# tell "this mission has no spec yet" from the envelope alone.
#
# `attachments` is a COUNT, not a list, and it exists so a later `lcars adopt`
# can WARN: GitHub has no issue-asset upload API, so attachments cannot travel
# with the issue. That gap is LEDGERED, not solved here.
#
# ---------------------------------------------------------------------------
# API
# ---------------------------------------------------------------------------
#   lcars_issue_body_compose <mission-dir> <park|align> [estimate-text] [k=v…]
#       → the full body (base body + blank line + envelope) on stdout.
#   lcars_issue_body_refresh <mission-dir> [estimate-text]
#       → resolve every PART, recompose the ALIGN body, and PUSH it via the host
#         adapter's `issue-edit-body` op. No issue / no prd.md / unchanged body
#         → no-op 0. A REQUIRED part that can be neither rebuilt nor carried
#         forward → refuses, rc 2, no marker and no new baseline written, and a
#         breadcrumb `lcars status` renders.
#   lcars_issue_body_record <mission-dir> <body-file>
#       → remember a body that reached GitHub, and PROMOTE the part record the
#         compose that produced it staged (only when the two are the same body).
#         Every filing lane calls this after a successful create/edit.
#   lcars_ib_stage_parts <mission-dir> <body> <prov> <has-adr> <adr-src> <has-est> <est>
#       → stage the PART RECORD for the body just composed (compose calls it).
#   lcars_ib_rec_ok <mission-dir>            → 0 when a usable part record exists.
#   lcars_ib_rec_has <mission-dir> <prov|adr|est>
#       → 0 when the last pushed body carried that part and its bytes are on
#         record. This is the ONLY "does the issue carry an X?" question in the
#         library, and it is answered from a flag the composer wrote — never
#         from a search of the captain's prose.
#   lcars_ib_refuse <mission-dir> <issue> <part> <why> <fix>
#       → stderr + the $MISSION_DIR/.issue-body.refused breadcrumb.
#   $MISSION_DIR/.issue-body.carried
#       → the counterpart breadcrumb: the parts a SUCCESSFUL push carried
#         forward rather than rebuilt. `lcars status` renders both.
#   lcars_handoff_envelope <mission-dir> [k=v…]      → the envelope line.
#   lcars_handoff_json <body-file>                   → the envelope's JSON, or "".
#   lcars_handoff_version <body-file>                → e.g. "v1", or "".
#   lcars_handoff_require_v1 <body-file>             → 0 when this LCARS
#         understands the envelope's schema; non-zero + a reason on stderr when
#         it does not. A consumer must REFUSE an unknown version, not guess.
#   lcars_handoff_field <body-file> <key>            → one value, or "".
#   lcars_handoff_parse <body-file>                  → `key<TAB>value` lines.
#         A body with NO envelope (every issue filed before this round) parses to
#         NOTHING and exits 0 — never an error.
#
# Env (same conventions as the rest of LCARS, all stubbable):
#   LCARS_GH_BIN              the gh binary the host adapter shells out to
#   LCARS_HOST_ADAPTER        the host adapter script path
#   LCARS_ISSUE_BODY_RUN_BIN  the run.sh that renders `## Estimate` on refresh
#                             (falls back to $LCARS_RUN_BIN, then the sibling)

# Where this library lives — used to find its sibling host-adapter.sh / run.sh.
LCARS_IB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ===========================================================================
# Tiny jq-free JSON readers over a state.json file.
# Deliberately PREFIXED: run.sh and file.sh each carry their own json_str /
# _fj_str, and this library must not shadow either of them when sourced in.
# ===========================================================================
# lcars_ib_cp2utf8 <decimal-codepoint> → sets $LCARS_IB_CP_OUT to its UTF-8 bytes.
# bash 3.2 has no printf '\uXXXX', so every codepoint is encoded BY HAND through
# octal byte escapes. U+0000 yields nothing (a NUL cannot live in a bash string).
# `printf -v` keeps the bytes out of a command substitution, which would eat a
# decoded newline.
LCARS_IB_CP_OUT=""
lcars_ib_cp2utf8() {
  local cp="$1" oct
  LCARS_IB_CP_OUT=""
  [ "$cp" -gt 0 ] 2>/dev/null || return 0
  if   [ "$cp" -lt 128 ];   then oct="$(printf '\\%03o' "$cp")"
  elif [ "$cp" -lt 2048 ];  then oct="$(printf '\\%03o\\%03o' \
         "$(( (cp >> 6) | 192 ))" "$(( (cp & 63) | 128 ))")"
  elif [ "$cp" -lt 65536 ]; then oct="$(printf '\\%03o\\%03o\\%03o' \
         "$(( (cp >> 12) | 224 ))" "$(( ((cp >> 6) & 63) | 128 ))" "$(( (cp & 63) | 128 ))")"
  else                           oct="$(printf '\\%03o\\%03o\\%03o\\%03o' \
         "$(( (cp >> 18) | 240 ))" "$(( ((cp >> 12) & 63) | 128 ))" \
         "$(( ((cp >> 6) & 63) | 128 ))" "$(( (cp & 63) | 128 ))")"
  fi
  printf -v LCARS_IB_CP_OUT '%b' "$oct"
}

# lcars_ib_unesc <escaped> → the JSON string it encodes.
# ONE un-escaper, shared by the state.json reader and the envelope field reader,
# because both read a JSON string body and both used to get it wrong.
#
# It walks backslash-to-backslash rather than character-by-character (values are
# short, but this runs per field on every compose).
#
# \uXXXX — S188 fix round 2, defect N4. This used to decode only U+0000–U+007F
# and claimed to hand anything else back "rather than mangle it by a guess". It
# mangled it: the backslash had already been consumed, so the four hex digits
# fell through as literal characters and `lcars/日本` read back as
# `lcars/u65e5u672c` — silent corruption, the one unacceptable outcome. Every
# escape is now DECODED: any BMP codepoint is encoded to UTF-8 by hand, and a
# high surrogate followed by its low partner is combined into the one astral
# codepoint the pair spells. A LONE surrogate cannot be represented at all, so
# it is passed through VERBATIM (`\uD83D` in, `\uD83D` out) — which is what the
# old comment promised and the old code did not do.
lcars_ib_unesc() {
  local s="${1-}" out="" head c hex hex2 cp cp2 lo
  while :; do
    case "$s" in
      *\\*) head="${s%%\\*}"; out="$out$head"; s="${s#*\\}" ;;
      *)    out="$out$s"; break ;;
    esac
    c="${s:0:1}"; s="${s:1}"
    case "$c" in
      n)  out="$out"$'\n' ;;
      t)  out="$out"$'\t' ;;
      r)  out="$out"$'\r' ;;
      b)  out="$out"$'\b' ;;
      f)  out="$out"$'\f' ;;
      u)  hex="${s:0:4}"
          case "$hex" in
            [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F])
              cp="$((16#$hex))"; s="${s:4}"
              if [ "$cp" -ge 55296 ] && [ "$cp" -le 56319 ]; then
                # HIGH surrogate: only meaningful paired with a LOW one.
                lo=""
                if [ "${s:0:2}" = '\u' ]; then
                  hex2="${s:2:4}"
                  case "$hex2" in
                    [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F])
                      cp2="$((16#$hex2))"
                      if [ "$cp2" -ge 56320 ] && [ "$cp2" -le 57343 ]; then
                        lo="$cp2"; s="${s:6}"
                      fi ;;
                  esac
                fi
                if [ -n "$lo" ]; then
                  lcars_ib_cp2utf8 "$(( 65536 + (cp - 55296) * 1024 + (lo - 56320) ))"
                  out="$out$LCARS_IB_CP_OUT"
                else
                  out="$out\\u$hex"     # lone high surrogate → verbatim
                fi
              elif [ "$cp" -ge 56320 ] && [ "$cp" -le 57343 ]; then
                out="$out\\u$hex"       # lone low surrogate → verbatim
              else
                lcars_ib_cp2utf8 "$cp"; out="$out$LCARS_IB_CP_OUT"
              fi ;;
            *) out="${out}u" ;;
          esac ;;
      '') : ;;
      *)  out="$out$c" ;;
    esac
  done
  printf '%s' "$out"
}

# lcars_ib_str <file> <key> → the string value, or "".
#
# The value class is "runs of ordinary characters, with backslash-escapes
# between them" — NOT `[^"]*`, which stopped dead at the first `\"` and returned
# a SILENTLY TRUNCATED value (a branch of `lcars/we\"ird` read back as
# `lcars/we\`). Written WITHOUT `\|`, because BRE alternation is a GNU extension
# that BSD/macOS sed does not have — a silent no-match there, not an error.
lcars_ib_str() { # file key → the string value, or ""
  local raw
  [ -f "$1" ] || return 0
  raw="$(sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"\\\\]*\(\\\\.[^\"\\\\]*\)*\)\".*/\1/p" "$1" | head -1)"
  [ -n "$raw" ] || return 0
  lcars_ib_unesc "$raw"
}
lcars_ib_raw() { # file key → the raw (number/bool/null) value, or ""
  [ -f "$1" ] || return 0
  sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\([^,}\"[:space:]]*\).*/\1/p" "$1" | head -1
}

# lcars_ib_attach_count <state.json> → how many durable attachments are staged.
# state.json's `attachments` is a flat array of relative paths, so the element
# count is the quote count halved. No key ⇒ 0 (never a guess, never an error).
lcars_ib_attach_count() { # state
  local inner n
  [ -f "$1" ] || { printf '0'; return 0; }
  inner="$(sed -n 's/.*"attachments"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p' "$1" | head -1)"
  if [ -z "${inner// /}" ]; then printf '0'; return 0; fi
  n="$(printf '%s' "$inner" | tr -cd '"' | wc -c | tr -d ' ')"
  printf '%d' "$((n / 2))"
}

# lcars_ib_esc <text> → the text as the BODY of a JSON string that is ALSO safe
# inside a one-line HTML comment. Two properties, both load-bearing:
#
#   VALID JSON     — backslash first, then quote, then the control characters
#                    JSON forbids raw (newline, CR, tab; any other C0 byte is
#                    DROPPED rather than smuggled through).
#   CANNOT ESCAPE  — `>` is emitted as \u003E, so the byte `>` never appears in
#   THE COMMENT      an envelope value at all and nothing can spell `-->` (or
#                    `--!>`) and close the comment early. JSON reads \u003E back
#                    as `>`, so the VALUE is unchanged — only its spelling is.
#
# Before S188's fix round that second property was held BY ACCIDENT: lcars_ib_str
# truncated every value at its first quote, so nothing hostile survived long
# enough to break out. Reading values correctly (D6) means escaping them properly
# here — the two halves of that fix are inseparable.
lcars_ib_esc() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  s="${s//>/\\u003E}"
  printf '%s' "$s" | tr -d '\001-\010\013\014\016-\037\177'
}

# lcars_ib_jstr <text> → a JSON string literal, or the bare token `null` when
# the value is empty. Empty is NOT "" — an absent branch/type/engine must read
# as unknown, not as the empty string.
lcars_ib_jstr() {
  [ -n "${1:-}" ] || { printf 'null'; return 0; }
  printf '"%s"' "$(lcars_ib_esc "$1")"
}

# lcars_ib_host <op> [args…] — the host adapter, invoked exactly the way run.sh /
# feedback.sh / log.sh invoke it (env-injected binary, overridable script path).
lcars_ib_host() {
  LCARS_GH_BIN="${LCARS_GH_BIN:-${GH_BIN:-gh}}" \
    bash "${LCARS_HOST_ADAPTER:-$LCARS_IB_DIR/host-adapter.sh}" "$@"
}

# ===========================================================================
# The envelope
# ===========================================================================
LCARS_HANDOFF_SCHEMA="v1"

# lcars_handoff_envelope <mission-dir> [key=value…]
#   Keys accepted as overrides: id branch base type engine parentIssue
#   attachments parked. Anything else is ignored (forward-compatible).
# ---------------------------------------------------------------------------
# S196 A5 — THE ESTIMATE'S PILL FACTS, CARRIED AS RECORDED FIELDS
# ---------------------------------------------------------------------------
# THE DEFECT. A REMOTE card carries a cost pill and two difficulty pills; the
# instant the captain ADOPTED it they vanished, because `lcars adopt` rebuilds
# prd.md + state.json and there was nowhere for it to learn the estimate from.
# A visible downgrade at the exact moment he takes ownership.
#
# WHY THE ENVELOPE AND NOT THE "## Estimate" SECTION. The remote card's pills are
# scraped out of that human section by the github board adapter, and adopt is
# forbidden from doing the same: adopt NEVER re-scans the captain's prose (rule 1
# of adopt.sh, three sessions' worth of scar tissue). The captain writes PRDs
# *about LCARS*, so a PRD quoting an estimate — or a whole decoy envelope — is a
# document this project has already been handed in anger. Recorded fields win.
#
# WHAT TRAVELS: the three PILL facts AND the per-stage `models` map. The token
# and request tables do NOT — those are local working data (`.git/lcars/` stays
# the source of richness, the round's standing invariant) and nothing downstream
# reads them.
#
# THE MODELS MAP WAS THE HALF THIS SHIPPED WITHOUT, and the comment that used to
# stand here said losing it was "harmless downstream because resolve_stage_model
# reads `models`, finds none, and emits the legacy no-`--model` argv". A tester
# on two genuinely cold clones MEASURED that it is not harmless: the filing
# laptop spawned `claude … --model sonnet` and the adopted clone spawned
# `claude …` with no `--model` on any of its three invocations, so one mission
# ran on two different model policies depending on which laptop held it — and
# the board's `modelMix` went to `[]` on the one that adopted it.
#
# It rides as ONE FLAT STRING, `estModels`: `key=tier` pairs comma-joined in the
# estimate's own stage order. Flat because every envelope field is read by the
# same by-key SCALAR reader (`lcars_handoff_field`); a nested object would need a
# second reader on both sides and would not survive that one. The consumer
# rebuilds `models` from these RECORDED pairs and never recomputes tiers from the
# criticalities — a recomputation is an inference, and it drifts from what the
# filing laptop actually chose.
#
# Absent estimate.json, or a cost block in a shape these readers do not
# understand, emits NOTHING — an absent fact stays absent rather than becoming a
# fabricated zero.

# lcars_ib_jscope <blob> <key> → the BODY (incl. braces) of "<key>": { … } inside
# a single-line JSON blob, braces MATCHED so a nested object cannot end it early.
# The same technique as run.sh's _json_scope_into, prefixed and local to this
# library for the reason stated at the top of the file (each script carries its
# own jq-free readers rather than sourcing a shared one).
lcars_ib_jscope() {
  printf '%s' "$1" | awk -v key="$2" '
    { s = $0; pat = "\"" key "\""
      i = index(s, pat); if (i == 0) exit
      r = substr(s, i + length(pat))
      ob = index(r, "{"); if (ob == 0) exit
      r = substr(r, ob); d = 0; out = ""; n = length(r)
      for (j = 1; j <= n; j++) {
        c = substr(r, j, 1); out = out c
        if (c == "{") d++
        else if (c == "}") { d--; if (d == 0) break }
      }
      print out }'
}

# lcars_ib_jscalar <blob> <key> → the scalar value of "<key>": a quoted string's
# body, else a bare number. Empty for absent, null, or anything else.
lcars_ib_jscalar() {
  local v
  v="$(printf '%s' "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1)"
  if [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
  printf '%s' "$1" \
    | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\(-\{0,1\}[0-9][0-9.eE+-]*\).*/\1/p" \
    | head -1
}

# lcars_ib_estimate_kv <mission-dir> → the envelope's estimate key/value chunk
# (leading comma included), or nothing.
lcars_ib_estimate_kv() {
  local est="$1/estimate.json"
  [ -f "$est" ] || return 0
  local blob; blob="$(tr -d '\n' <"$est" 2>/dev/null)"
  [ -n "$blob" ] || return 0
  local reason impl costb unit band low high out=""
  reason="$(lcars_ib_jscalar "$blob" reasoningCriticality)"
  impl="$(lcars_ib_jscalar "$blob" implCriticality)"
  case "$reason" in low|medium|high) : ;; *) reason="" ;; esac
  case "$impl"   in low|medium|high) : ;; *) impl="" ;; esac

  costb="$(lcars_ib_jscope "$blob" cost)"
  if [ -n "$costb" ]; then
    unit="$(lcars_ib_jscalar "$costb" unit)"
    case "$unit" in
      usd|premiumRequests) band="$(lcars_ib_jscope "$costb" "$unit")" ;;
      *) unit=""; band="" ;;
    esac
    if [ -n "$band" ]; then
      low="$(lcars_ib_jscalar "$band" low)"
      high="$(lcars_ib_jscalar "$band" high)"
    fi
    # A band with neither end is no band at all (and `status:"unavailable"`
    # estimates land here) — say nothing rather than half a pill.
    if [ -z "${low:-}" ] && [ -z "${high:-}" ]; then unit=""; fi
  fi

  # The per-stage model map, flattened to `key=tier,key=tier…` IN THE ESTIMATE'S
  # OWN ORDER (the order the estimator emitted, which is the order the board
  # renders). Each pair is validated on the way out — a key that is not a bare
  # identifier, or a tier that is not a bare alias token, is DROPPED rather than
  # escaped into the envelope, so nothing a worker wrote can reshape the field.
  local models mstr=""
  models="$(lcars_ib_jscope "$blob" models)"
  if [ -n "$models" ]; then
    mstr="$(printf '%s' "$models" | awk '
      { s = $0; out = ""; sep = ""
        while (match(s, /"[A-Za-z][A-Za-z0-9_]*"[ \t]*:[ \t]*"[^"]*"/)) {
          p = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
          k = p; sub(/^"/, "", k); sub(/".*$/, "", k)
          v = p; sub(/^"[^"]*"[ \t]*:[ \t]*"/, "", v); sub(/"$/, "", v)
          if (v !~ /^[A-Za-z0-9][A-Za-z0-9._-]*$/) continue
          out = out sep k "=" v; sep = ","
        }
        print out }')"
  fi

  [ -n "$unit" ] && out="$out,\"estCostUnit\":$(lcars_ib_jstr "$unit")"
  [ -n "$unit" ] && [ -n "${low:-}" ]  && out="$out,\"estCostLow\":$low"
  [ -n "$unit" ] && [ -n "${high:-}" ] && out="$out,\"estCostHigh\":$high"
  [ -n "$reason" ] && out="$out,\"estReasoning\":$(lcars_ib_jstr "$reason")"
  [ -n "$impl" ]   && out="$out,\"estImpl\":$(lcars_ib_jstr "$impl")"
  [ -n "$mstr" ]   && out="$out,\"estModels\":$(lcars_ib_jstr "$mstr")"
  printf '%s' "$out"
}

lcars_handoff_envelope() {
  local mdir="$1"; shift
  local state="$mdir/state.json"

  local o_id="" o_branch="" o_base="" o_type="" o_engine="" o_parent="" o_attach="" o_parked=""
  local kv k v
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    case "$k" in
      id)          o_id="$v" ;;
      branch)      o_branch="$v" ;;
      base)        o_base="$v" ;;
      type)        o_type="$v" ;;
      engine)      o_engine="$v" ;;
      parentIssue) o_parent="$v" ;;
      attachments) o_attach="$v" ;;
      parked)      o_parked="$v" ;;
      *) : ;;
    esac
  done

  local id branch base type engine parent attach
  id="${o_id:-$(lcars_ib_str "$state" id)}"
  [ -n "$id" ] || id="$(basename "$mdir")"
  branch="${o_branch:-$(lcars_ib_str "$state" branch)}"
  base="${o_base:-$(lcars_ib_str "$state" base)}"
  type="${o_type:-$(lcars_ib_str "$state" type)}"

  # engine: the SAME resolution that produced state.json's workerBin, reduced to
  # the engine's own name. Never inferred from $LCARS_WORKER_BIN here — that env
  # var loses to a persisted workerBin, and guessing is exactly the drift this
  # envelope exists to prevent.
  engine="$o_engine"
  [ -n "$engine" ] || engine="$(lcars_ib_str "$state" workerBin)"
  [ -n "$engine" ] && engine="$(basename "$engine")"

  parent="${o_parent:-$(lcars_ib_raw "$state" parentIssue)}"
  case "$parent" in ''|null|0) parent="null" ;; *[!0-9]*) parent="null" ;; esac

  attach="$o_attach"
  [ -n "$attach" ] || attach="$(lcars_ib_attach_count "$state")"
  case "$attach" in ''|*[!0-9]*) attach="0" ;; esac

  local parked=""
  [ "$o_parked" = "true" ] && parked=',"parked":true'

  # S196 A5 — the ESTIMATE facts (the three pill values and the per-stage model
  # map), when the mission records them. They ride at the END so every byte
  # before them is unchanged from S188's envelope, and they are ADDITIVE within
  # v1: `lcars_handoff_field` reads by key, so an older LCARS parsing this
  # envelope sees exactly what it saw before, and a body from before this round
  # simply carries none of them.
  local estkv; estkv="$(lcars_ib_estimate_kv "$mdir")"

  printf '<!-- lcars:handoff %s {"id":%s,"branch":%s,"base":%s,"type":%s,"engine":%s,"parentIssue":%s,"attachments":%s%s%s} -->' \
    "$LCARS_HANDOFF_SCHEMA" \
    "$(lcars_ib_jstr "$id")" \
    "$(lcars_ib_jstr "$branch")" \
    "$(lcars_ib_jstr "$base")" \
    "$(lcars_ib_jstr "$type")" \
    "$(lcars_ib_jstr "$engine")" \
    "$parent" "$attach" "$parked" "$estkv"
}

# ===========================================================================
# The parse helper — S189's import surface. Shares the golden-body tests.
# ===========================================================================

# lcars_ib_scan <body-file> <json|ver> → the LAST envelope's JSON payload, or its
# schema token. ONE scanner, so `_json` and `_version` can never disagree about
# which envelope is "the" envelope.
#
# It matches NON-GREEDILY: the payload ends at the FIRST ` -->` after an opening
# `<!-- lcars:handoff `, never the last one on the line. `grep -o '… .* -->'` was
# greedy, so a line carrying TWO envelopes returned one blob spanning both — not
# JSON at all. A body this library composes cannot contain such a line, but S189
# calls these helpers on ARBITRARY GitHub bodies, where anyone can type one.
#
# Envelopes are scanned in order across every line and the LAST one wins: the
# envelope is APPENDED, so anything earlier is quoted prose in a PRD (a fake
# envelope pasted into a spec must not hijack the parse) — that property predates
# this fix and is preserved by it.
lcars_ib_scan() {
  local f="${1:-}" want="${2:-json}"
  [ -n "$f" ] && [ -f "$f" ] || return 0
  awk -v want="$want" '
    {
      s = $0
      while ((i = index(s, "<!-- lcars:handoff ")) > 0) {
        s = substr(s, i)
        j = index(s, " -->")            # FIRST terminator: the non-greedy match
        if (j == 0) break
        cand = substr(s, 1, j + 3)
        rest = substr(cand, 20)         # past "<!-- lcars:handoff "
        k = index(rest, " ")
        if (k > 1) {
          v = substr(rest, 1, k - 1)
          if (v ~ /^v[0-9]+$/) {
            lastv = v
            lastj = substr(rest, k + 1, length(rest) - k - 4)
          }
        }
        s = substr(s, j + 4)
      }
    }
    END {
      if (want == "ver") { if (lastv != "") print lastv }
      else               { if (lastj != "") print lastj }
    }
  ' "$f" 2>/dev/null
}

# lcars_handoff_json <body-file> → the envelope's JSON object text, or NOTHING.
lcars_handoff_json() { lcars_ib_scan "${1:-}" json; }

# lcars_handoff_version <body-file> → e.g. "v1", or NOTHING when there is no
# envelope. A consumer that does not understand the version must refuse, not
# guess — which is the whole point of stamping it. See lcars_handoff_require_v1,
# which is how a consumer actually does that.
lcars_handoff_version() { lcars_ib_scan "${1:-}" ver; }

# lcars_handoff_require_v1 <body-file> → 0 when the body carries an envelope THIS
# library understands; non-zero, with a reason on stderr, otherwise.
#
# The header has always said a consumer must REFUSE an unknown schema rather than
# guess, but nothing enforced it: `<!-- lcars:handoff v2 {…} -->` parsed straight
# through _field / _parse as if it were v1, so a future v2 that RENAMED a key
# would be misread in silence. This is the gate a consumer (S189's adopt) calls
# before it trusts a single field.
lcars_handoff_require_v1() {
  local f="${1:-}" v
  v="$(lcars_handoff_version "$f")"
  if [ -z "$v" ]; then
    printf 'lcars handoff: no lcars:handoff envelope in %s — this issue predates the handoff payload.\n' \
      "${f:-<no file>}" >&2
    return 1
  fi
  [ "$v" = "$LCARS_HANDOFF_SCHEMA" ] && return 0
  printf 'lcars handoff: envelope schema %s in %s, but this LCARS understands %s — refusing to guess. Update LCARS (`lcars update`).\n' \
    "$v" "${f:-<no file>}" "$LCARS_HANDOFF_SCHEMA" >&2
  return 1
}

# lcars_handoff_field <body-file> <key> → the value, or NOTHING (also for null).
lcars_handoff_field() {
  local j v; j="$(lcars_handoff_json "${1:-}")"
  [ -n "$j" ] || return 0
  # String form first. The value class is "runs of ordinary characters, with
  # backslash-escapes between them" — written WITHOUT `\|`, because BRE
  # alternation is a GNU extension and BSD/macOS sed does not have it (that is a
  # silent no-match there, not an error).
  v="$(printf '%s' "$j" | sed -n "s/.*\"$2\":\"\\([^\"\\\\]*\\(\\\\.[^\"\\\\]*\\)*\\)\".*/\\1/p")"
  if [ -n "$v" ]; then
    # One shared un-escaper (lcars_ib_unesc) rather than a pair of substitutions
    # applied in sequence: those got `\\n` (an escaped backslash then an `n`)
    # wrong, and knew nothing of the \n / \u003E forms lcars_ib_esc now emits.
    lcars_ib_unesc "$v"; return 0
  fi
  v="$(printf '%s' "$j" | sed -n "s/.*\"$2\":\\([^,}\"]*\\).*/\\1/p")"
  case "$v" in null|'') return 0 ;; esac
  printf '%s' "$v"
}

# lcars_handoff_parse <body-file> → one `key<TAB>value` line per key PRESENT in
# the envelope (a null value yields an empty value, not a missing line). A body
# with no envelope — every issue filed before this round — prints NOTHING and
# exits 0. That is the contract: pre-round issues parse EMPTY, never error.
lcars_handoff_parse() {
  local f="${1:-}" j k
  j="$(lcars_handoff_json "$f")"
  [ -n "$j" ] || return 0
  for k in id branch base type engine parentIssue attachments parked \
           estCostUnit estCostLow estCostHigh estReasoning estImpl estModels; do
    case "$j" in *"\"$k\":"*) : ;; *) continue ;; esac
    printf '%s\t%s\n' "$k" "$(lcars_handoff_field "$f" "$k")"
  done
}

# ===========================================================================
# The composer
# ===========================================================================

# lcars_issue_body_compose <mission-dir> <park|align> [estimate-text] [k=v…]
#
#   park  — the fast-lane park body: the captain's verbatim idea (idea.md) + the
#           STANDBY note. No PRD exists yet; the envelope carries "parked":true.
#   align — the aligned body: prd.md → adr.md → the rendered "## Estimate"
#           section, each separated by `\n\n---\n\n`, exactly as the filing lanes
#           composed it inline before S188. The estimate section is OPTIONAL and
#           absent exactly like an absent adr.md (the load-bearing degradation).
#
# The base body is emitted BYTE-FOR-BYTE as the lanes emitted it. The envelope is
# then APPENDED after a single blank line, and nothing above it moves.
# lcars_ib_provenance <mission-dir> [key=value…] → the `> 🐞 Logged via …` lead-in
# a `lcars log` bug mission's body opens with, or NOTHING for every other mission.
#
# This is the one part of a body the composer could not previously rebuild, and
# so the one part a refresh DELETED: `lcars log` wrote it inline at filing time
# and the Verify-entry recompose replaced the whole body with prd.md alone,
# taking the provenance off the issue permanently. It is reproduced here from
# state.json's own `origin`/`parentMission`/`parentIssue` — the same three values
# log.sh had in hand when it wrote the line — so filing and refreshing emit the
# same bytes, and a bounced-and-re-grilled logged bug refreshes its SPEC while
# KEEPING its provenance.
#
# Overrides are accepted for `lcars log` itself, which composes the body BEFORE
# it writes state.json (the issue number it is about to create goes IN there).
lcars_ib_provenance() {
  local mdir="$1"; shift
  local state="$mdir/state.json"
  local o_origin="" o_pm="" o_pi="" have_pi=0 kv k v
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    case "$k" in
      origin)        o_origin="$v" ;;
      parentMission) o_pm="$v" ;;
      parentIssue)   o_pi="$v"; have_pi=1 ;;
      *) : ;;
    esac
  done

  local origin parent pissue
  origin="${o_origin:-$(lcars_ib_str "$state" origin)}"
  [ "$origin" = "log" ] || return 0
  parent="${o_pm:-$(lcars_ib_str "$state" parentMission)}"
  [ -n "$parent" ] || return 0

  if [ "$have_pi" -eq 1 ]; then pissue="$o_pi"; else pissue="$(lcars_ib_raw "$state" parentIssue)"; fi
  case "$pissue" in ''|null) pissue="" ;; *[!0-9]*) pissue="" ;; esac

  # BYTE-FOR-BYTE the line log.sh emitted inline before S188 — including the
  # `(#n)` half being omitted when the parent has no issue number.
  printf '> 🐞 Logged via `lcars log` against %s' "$parent"
  [ -n "$pissue" ] && printf ' (#%s)' "$pissue"
  printf '.\n\n'
}

# lcars_ib_stage_parts <mdir> <body> <prov-file|""> <has-adr> <adr-src|""> <has-est> <est-text>
#
# WRITE DOWN THE PARTS THIS COMPOSE JUST EMITTED. The composer is the only thing
# in LCARS that knows, as a FACT, which parts a body is made of and where each
# one begins and ends; every attempt to recover that afterwards by reading the
# finished text has been beaten (see the fix-round history above
# lcars_issue_body_refresh). So it is not recovered afterwards any more — it is
# recorded here, at the one moment it is known.
#
# The record is STAGED, not published: `lcars_issue_body_record` promotes it to
# `$MISSION_DIR/.issue-body.parts/` only when the body it is handed is the body
# these parts came from (a checksum, not a guess). A compose whose body never
# reached GitHub therefore never becomes "what the issue carries".
#
# Layout of the staged/published record:
#   sum     the cksum of the WHOLE composed body, digits only — the pairing
#   flags   prov=0|1  adr=0|1  est=0|1 — whether the composer emitted that part
#   prov    the provenance lead-in bytes  (empty when it emitted none)
#   adr     the ADR set bytes, WITHOUT the `\n\n---\n\n` rule that introduces it
#   est     the "## Estimate" section, as `printf '%s\n'` wrote it
#
# `flags` and the content files are separate on purpose: "the composer appended
# an ADR that happened to be empty" and "the composer appended no ADR" are
# different facts, and only the flag can tell them apart. Deleting a content
# file is the captain's way of telling the composer to FORGET that part — see
# the ADR-removal note in lcars_issue_body_refresh.
lcars_ib_stage_parts() {
  local mdir="$1" body="$2" provf="$3" hadr="$4" asrc="$5" hest="$6" etext="$7"
  local st="$mdir/.issue-body.parts.staged"
  [ -d "$mdir" ] || return 0
  rm -rf "$st" 2>/dev/null
  mkdir -p "$st" 2>/dev/null || return 0
  : >"$st/prov" 2>/dev/null || return 0
  : >"$st/adr"; : >"$st/est"
  local hprov=0
  if [ -n "$provf" ] && [ -s "$provf" ]; then
    cat "$provf" >"$st/prov" 2>/dev/null && hprov=1
  fi
  [ "$hadr" = 1 ] && cat "$asrc" >"$st/adr" 2>/dev/null
  [ "$hest" = 1 ] && printf '%s\n' "$etext" >"$st/est" 2>/dev/null
  printf 'prov=%s\nadr=%s\nest=%s\n' "$hprov" "$hadr" "$hest" >"$st/flags" 2>/dev/null
  cksum <"$body" 2>/dev/null | tr -d ' \n' >"$st/sum" 2>/dev/null
  return 0
}

lcars_issue_body_compose() {
  local mdir="$1" mode="$2" est="${3:-}"
  if [ "$#" -ge 3 ]; then shift 3; else shift "$#"; fi

  local tmp provtmp full adr_src="" has_adr=0 has_est=0
  tmp="$(mktemp)" || return 1
  provtmp="$(mktemp)" || { rm -f "$tmp"; return 1; }
  case "$mode" in
    park)
      local pid; pid="$(lcars_ib_str "$mdir/state.json" id)"
      [ -n "$pid" ] || pid="$(basename "$mdir")"
      {
        [ -f "$mdir/idea.md" ] && cat "$mdir/idea.md"
        printf '\n---\n\n'
        printf '_◇ STANDBY — parked awaiting alignment. Run `lcars file %s` to run the Align grill and complete this mission._\n' "$pid"
      } >"$tmp"
      set -- "$@" "parked=true"
      ;;
    align)
      # PART SOURCES. Each part comes from the mission dir by default; the
      # refresh (and ONLY the refresh) overrides a source when it has resolved
      # that part to a CARRY-FORWARD payload instead — see the part table above
      # lcars_issue_body_refresh. Unset ⇒ the mission dir, exactly as before, so
      # every filing lane's bytes are untouched.
      #   LCARS_IB_PROV_SRC  a file whose contents ARE the provenance lead-in
      #                      (an empty file ⇒ no lead-in). Unset ⇒ rebuild it.
      #   LCARS_IB_ADR_SRC   the file to append as the adr (empty ⇒ no adr).
      #                      Unset ⇒ $mdir/adr.md.
      adr_src="${LCARS_IB_ADR_SRC-$mdir/adr.md}"
      if [ -n "${LCARS_IB_PROV_SRC+set}" ]; then
        [ -f "$LCARS_IB_PROV_SRC" ] && cat "$LCARS_IB_PROV_SRC" >"$provtmp"
      else
        lcars_ib_provenance "$mdir" "$@" >"$provtmp"
      fi
      [ -n "$adr_src" ] && [ -f "$adr_src" ] && has_adr=1
      [ -n "$est" ] && has_est=1
      {
        cat "$provtmp"
        [ -f "$mdir/prd.md" ] && cat "$mdir/prd.md"
        if [ "$has_adr" = 1 ]; then printf '\n\n---\n\n'; cat "$adr_src"; fi
        if [ "$has_est" = 1 ]; then printf '\n\n---\n\n'; printf '%s\n' "$est"; fi
      } >"$tmp"
      ;;
    *)
      rm -f "$tmp" "$provtmp"
      printf 'lcars issue-body: unknown compose mode "%s" (want park|align).\n' "$mode" >&2
      return 1 ;;
  esac

  full="$(mktemp)" || { rm -f "$tmp" "$provtmp"; return 1; }
  {
    cat "$tmp"
    # A body that does not already end in a newline gets one, so the envelope is
    # always alone on the last line. `$(tail -c 1)` is empty exactly when that
    # byte IS a newline (command substitution strips it), so this adds nothing
    # to the bodies the lanes produce today.
    if [ -s "$tmp" ] && [ -n "$(tail -c 1 "$tmp")" ]; then printf '\n'; fi
    printf '\n%s\n' "$(lcars_handoff_envelope "$mdir" "$@")"
  } >"$full"

  lcars_ib_stage_parts "$mdir" "$full" "$provtmp" "$has_adr" "$adr_src" "$has_est" "$est"
  cat "$full"
  rm -f "$tmp" "$provtmp" "$full"
}

# ===========================================================================
# The refresh — transfer points ONLY (see the header)
# ===========================================================================

# lcars_ib_render_estimate <mission-dir> → the "## Estimate" issue section, or
# NOTHING. Shells out to run.sh's render-estimate (the ONE renderer) exactly the
# way file.sh does; an absent estimate.json prints nothing and exits non-zero,
# and that degradation is deliberate.
lcars_ib_render_estimate() {
  local mdir="$1" rb id
  rb="${LCARS_ISSUE_BODY_RUN_BIN:-${LCARS_RUN_BIN:-$LCARS_IB_DIR/run.sh}}"
  [ -f "$rb" ] || return 0
  [ -f "$mdir/estimate.json" ] || return 0
  id="$(lcars_ib_str "$mdir/state.json" id)"
  [ -n "$id" ] || id="$(basename "$mdir")"
  bash "$rb" render-estimate --mission "$id" --surface issue 2>/dev/null || true
}

# ===========================================================================
# PART-AWARE COMPOSITION — a refresh builds PARTS, it does not judge TEXT
# ===========================================================================
# The composer builds a body out of whatever is on disk RIGHT NOW. That is
# correct when the disk is whole and catastrophic when it is not: a crashed
# re-grill worker leaves a 0-byte prd.md, a hand-cleaned mission has no
# estimate.json, a mission dir is half-restored from a backup. Pushing that
# recompose UNCONDITIONALLY deletes content off the GitHub issue that nothing
# can put back — the spec, the "## Estimate" section (and with it ALL THREE
# board pills the github adapter scrapes), a lead-in the composer cannot
# rebuild. GitHub keeps an edit history a human can dig through; LCARS does not
# read it, so for every automated consumer the loss is permanent.
#
# S188 FIX ROUND 1 answered that with a WHOLE-BODY REGRESSION GUARD: recompose,
# then compare the finished text against the last pushed body and refuse when
# the result "looked" lossy — under half the size, fewer `^---$` rules, a
# missing marker. A fresh tester beat it four ways the same evening:
#
#   N1  the `^---$` count counted THE CAPTAIN'S OWN horizontal rules inside the
#       PRD. A re-grill that dropped one was refused, and the message blamed the
#       adr/estimate. It protected a PRD construct by accident.
#   N2  an honest hard scope cut (60 acceptance criteria re-grilled down to 3)
#       tripped the size ratio and was refused PERMANENTLY and SILENTLY — no
#       force flag, no env override, both call sites `>/dev/null 2>&1 || true`,
#       and the breadcrumb file had zero readers. The issue kept the OLD spec:
#       precisely the defect S188 exists to close, reached by a legitimate act.
#   N3  a missing / empty `.issue-body.last` disarmed the ratio and the rule
#       count entirely — and the park lane never wrote one, so for every mission
#       filed before that round the original defects were simply not cured.
#   N4  (the un-escaper, cured above.)
#
# THE ROOT ERROR is that a whole-body guard tries to infer FROM THE FINISHED
# TEXT whether a loss was legitimate. It cannot know that. Nothing can. LCARS
# has been here before: S157 built an anti-gutting guard, took it through five
# successive versions, had each one beaten (one of them caught false-failing an
# honest repair), and finally cured it by DELETING ~1,000 lines in favour of one
# source-blind check (roadmap row 10 / the S163 post-mortem). So the question is
# not asked any more. There is no ratio, no separator count, and no marker
# search anywhere below.
#
# WHAT REPLACES IT. The composer knows exactly which parts it assembles, so
# each part's presence is decided BEFORE anything is composed, as a FACT ABOUT
# ITS SOURCE. At refresh time each part is exactly one of:
#
#   REBUILDABLE     its source is present and valid → build it from source.
#   CARRY-FORWARD   its source is gone, but the last body this repo pushed
#                   carries that part → reuse that part VERBATIM.
#   REFUSE          the part is required here, its source is invalid, and there
#                   is nothing to carry forward → refuse the whole push, NAMING
#                   the part and the reason.
#
#   part        source          rebuildable when      carried forward     required
#   ----------  --------------  --------------------  ------------------  --------
#   provenance  state.json      origin=log + parent   from the RECORD     no
#   spec        prd.md          non-empty             NEVER — carrying a   YES
#                                                     stale spec forward
#                                                     IS the S188 defect
#   adr         adr.md          present, non-empty    from the RECORD     no
#   estimate    estimate.json   render-estimate       from the RECORD      see
#                               prints something                           below
#
# The two asymmetries, deliberate:
#
#   * The SPEC is the one hard refusal, and it is a PRECONDITION ON THE INPUT
#     (`prd.md` exists but is 0 bytes ⇒ an interrupted re-grill wrote nothing),
#     never a diff of the output. `prd.md` ABSENT is not a fault at all — that
#     mission has never been aligned, and there is nothing to refresh.
#
#   * The ESTIMATE is required when the refresh cannot PROVE the issue has none.
#     With a part record the answer is a fact the composer wrote down: the last
#     pushed body either carried the section (carry it forward) or it did not
#     (the part is absent). With NO record the refresh is blind, and pushing
#     blind is how D4 deleted all three board pills — so it refuses and says so.
#     The ADR does NOT get that treatment: an absent `adr.md` is the NORMAL
#     state of a trivial mission, so its absence is evidence of nothing, and
#     refusing every legacy trivial mission would be far worse than the hole it
#     closes.
#
# ---------------------------------------------------------------------------
# S188 FIX ROUND 3 — WHERE A CARRIED PART COMES FROM
# ---------------------------------------------------------------------------
# Round 2's part model was right; its CARRY-FORWARD HELPERS reintroduced the
# same disease at a smaller scale, because they located each part in the last
# pushed body BY GREPPING THE CAPTAIN'S PROSE. A fresh tester beat them twice:
#
#   NEW-1  SILENT BODY CORRUPTION. `lcars_ib_carry_estimate` was tail-anchored
#          on `grep -n '^## Estimate$' | tail -1`. With no real Estimate section
#          that grep still matched an `## Estimate` heading inside the PRD or
#          ADR, so the "carried estimate" was everything from that heading to
#          the end of the body — the PRD tail plus the whole ADR set, appended a
#          second time. It PUSHED, wrote the dedup marker, and left no
#          breadcrumb; every later refresh reproduced it.
#   NEW-2  PERMANENT FALSE REFUSAL. `lcars_ib_prev_has_adr` grepped the WHOLE
#          body for `**Context:**` / `**Decision:**` / `**Alternatives
#          considered:**` / `**Consequences:**`. A PRD that merely DOCUMENTS the
#          ADR format matches all four, so a mission that never had an ADR read
#          as carrying one; the slice then could not find it and the push was
#          refused at every transfer point, for ever, leaving the issue on the
#          OLD SPEC — the defect S188 exists to close. Round 2 documented and
#          accepted that ("only ever costs a refusal, never a deletion"); the
#          judgement was wrong, because a permanent refusal IS a stale spec.
#
# This captain writes PRDs ABOUT LCARS, a system whose own documentation is full
# of ADR field names and `## Estimate` headings. Neither case is exotic.
#
# THE CURE IS THAT NOTHING IS LOCATED ANY MORE. The composer knows exactly which
# parts it emitted, so it WRITES THEM DOWN at the moment it emits them
# (`lcars_ib_stage_parts` → `$MISSION_DIR/.issue-body.parts/`, promoted by
# `lcars_issue_body_record` only for a body that actually reached GitHub). A
# carry-forward is a copy out of that record. Consequently:
#
#   * NEW-1 is IMPOSSIBLE, not handled: the estimate that gets carried is the
#     estimate file the composer wrote, and no heading anywhere in the body is
#     read. `est=0` in `flags` is a positive statement that the issue carries no
#     Estimate section, so nothing can be mistaken for one.
#   * NEW-2 is IMPOSSIBLE, not handled: "does the issue carry an ADR" is a flag
#     the composer set (`adr=1`), and the four ADR field names appear nowhere in
#     this library. A PRD that documents them is ordinary prose and pushes.
#   * A part that genuinely cannot be located is still a NAMED refusal — never a
#     silent allow, and never a silent duplication.
#
# `.issue-body.last` is therefore NO LONGER A CORRECTNESS ORACLE and no longer a
# carry SOURCE either. Nothing compares the new body against it and nothing
# slices it. It is the PAIRING EVIDENCE: a record is honoured only while its
# `sum` still matches that file byte for byte, so a truncated, hand-written,
# stale or absent baseline reads as NO RECORD. A record written by an LCARS that
# predates this layout has no `flags` and reads as NO RECORD too — the same
# honest degradation, self-healing at the first successful push.
#
# A refusal is LOUD but never fatal: the reason goes to stderr AND to
# $MISSION_DIR/.issue-body.refused, which `lcars status` READS. It writes NO
# dedup marker and NO new baseline, so once the source is restored the NEXT
# transfer point heals the issue by itself and deletes the breadcrumb.
#
# A CARRY-FORWARD IS LOUD TOO, as of this round. It used to be completely
# silent: a captain whose estimate.json had vanished got no signal that his
# board pills were a fossil rather than a rebuild, and a captain who deleted
# adr.md got no signal that the ADR had been resurrected. A successful push that
# carried anything writes $MISSION_DIR/.issue-body.carried — one line per
# carried part, naming the part, the missing source, and what to do — and
# `lcars status` renders it beside the refusals. A fully rebuilt body deletes
# that file, so the surface never describes a state that has passed.

# ---------------------------------------------------------------------------
# READING THE RECORD
# ---------------------------------------------------------------------------
# `$MISSION_DIR/.issue-body.parts/` is what `lcars_issue_body_record` promoted
# out of the last compose whose body actually reached GitHub. Two facts make it
# trustworthy, and neither is a judgement about text:
#
#   PROVENANCE  only lcars_ib_stage_parts writes it, and only from the parts the
#               composer had in hand.
#   PAIRING     `sum` is the checksum of the body that was pushed. A record is
#               honoured only when it still matches `.issue-body.last` byte for
#               byte, so a hand-edited, truncated, stale or half-restored
#               baseline reads as NO RECORD rather than as a record of something
#               else.
#
# A record written by an LCARS that predates this layout has no `flags`, so it
# also reads as NO RECORD — the same honest degradation a baseline with no
# envelope already gets. It re-seeds itself at the first successful push.

# lcars_ib_rec_ok <mission-dir> → 0 when this mission has a usable part record.
lcars_ib_rec_ok() {
  local mdir="$1" rec="$mdir/.issue-body.parts"
  [ -s "$mdir/.issue-body.last" ] || return 1
  grep -q '^<!-- lcars:handoff v[0-9][0-9]* .* -->$' "$mdir/.issue-body.last" || return 1
  [ -f "$rec/sum" ] && [ -f "$rec/flags" ] || return 1
  [ "$(cat "$rec/sum" 2>/dev/null)" \
    = "$(cksum <"$mdir/.issue-body.last" 2>/dev/null | tr -d ' \n')" ] || return 1
  return 0
}

# lcars_ib_rec_has <mission-dir> <prov|adr|est> → 0 when the last pushed body
# carried that part AND the record still holds its bytes.
#
# This is the whole of "does the issue carry an X?" — a flag the composer wrote,
# never a search of the captain's prose. An `## Estimate` heading inside a PRD
# and a PRD that documents `**Context:**` / `**Decision:**` are invisible to it,
# which is the point.
lcars_ib_rec_has() {
  local rec="$1/.issue-body.parts" part="$2"
  [ -f "$rec/flags" ] || return 1
  grep -q "^$part=1\$" "$rec/flags" 2>/dev/null || return 1
  [ -f "$rec/$part" ] || return 1
  return 0
}

# lcars_ib_refuse <mission-dir> <issue> <part> <why> <fix>
# One refusal path: stderr (for anyone watching a raw run) AND the breadcrumb
# `lcars status` renders. TAB-separated so the status view can lay it out:
#   <utc>  <issue>  <part>  <why>  <what to do>
#
# THE `fix` FIELD IS A PROMISE. It is the one line the captain reads in
# `lcars status`, so it must name a remedy that is true FOR THIS CASE — never a
# generic "restore it from somewhere". Round 2 told him to restore
# `…/adr.md from the mission history` for a mission that had never had an
# adr.md; he would have gone looking for a file that never existed. Every fix
# string below names a file that provably exists in the case that emits it, or
# an act (a deletion) that is always available.
lcars_ib_refuse() {
  local mdir="$1" issue="$2" part="$3" why="$4" fix="$5"
  printf 'lcars issue-body: REFUSED to refresh issue #%s — cannot build %s: %s → %s\n' \
    "$issue" "$part" "$why" "$fix" >&2
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" "$issue" "$part" "$why" "$fix" \
    >"$mdir/.issue-body.refused" 2>/dev/null || true
  # `.issue-body.carried` is deliberately NOT cleared here. It describes the body
  # that is ON the issue right now, and a refusal changes nothing on the issue —
  # so if the last body that reached GitHub carried a part forward, that is still
  # true, and `lcars status` should keep saying so alongside the refusal.
  rm -rf "$mdir/.issue-body.parts.staged" 2>/dev/null || true
  return 0
}

# lcars_issue_body_record <mission-dir> <body-file>
# Remember the body that just reached GitHub, and — the point of this round —
# PROMOTE the part record the compose that produced it staged, but ONLY when the
# staged record is a record of THIS body. `cksum` is the pairing test: a lane
# that composed twice, or a refresh whose push failed, leaves a staged record
# for a body nobody pushed, and that must read as no record rather than as a
# description of the issue.
#
# Every filing lane calls this after a successful create/edit (the park lane
# included), and the refresh calls it after a successful push. It never fails
# its caller.
lcars_issue_body_record() {
  local mdir="${1:-}" body="${2:-}"
  [ -d "$mdir" ] && [ -f "$body" ] || return 0
  cp "$body" "$mdir/.issue-body.last" 2>/dev/null || true
  local st="$mdir/.issue-body.parts.staged" rec="$mdir/.issue-body.parts"
  rm -rf "$rec" 2>/dev/null || true
  if [ -f "$st/sum" ] \
     && [ "$(cat "$st/sum" 2>/dev/null)" = "$(cksum <"$body" 2>/dev/null | tr -d ' \n')" ]; then
    mv "$st" "$rec" 2>/dev/null || {
      mkdir -p "$rec" 2>/dev/null && cp "$st/flags" "$st/sum" "$st/prov" "$st/adr" "$st/est" \
        "$rec/" 2>/dev/null
    }
  fi
  rm -rf "$st" 2>/dev/null || true
  return 0
}

# lcars_issue_body_refresh <mission-dir> [estimate-text]
#
# Recompose the ALIGN body and push it to the mission's issue. Call this ONLY at
# the two transfer points named in the header. Best-effort throughout — it never
# fails its caller — but it does NOT lie: the "already pushed" marker is written
# only after the host op actually succeeds, so a failed push is retried at the
# next transfer point.
#
# Returns 0 when the body is current (pushed now, or already pushed), 1 when a
# push was attempted and failed, 2 when a REQUIRED part could not be built.
lcars_issue_body_refresh() {
  local mdir="$1" est="${2-__LCARS_IB_AUTO__}"
  local state="$mdir/state.json"
  [ -f "$state" ] || return 0

  # PART: the SPEC — precondition 1 of 2. No prd.md AT ALL is not a fault: the
  # mission has never been aligned (a parked idea), so there is nothing to
  # refresh and nothing to say about it.
  [ -f "$mdir/prd.md" ] || return 0

  local issue; issue="$(lcars_ib_raw "$state" githubIssue)"
  case "$issue" in ''|null|0) return 0 ;; *[!0-9]*) return 0 ;; esac

  local mid; mid="$(lcars_ib_str "$state" id)"
  [ -n "$mid" ] || mid="$(basename "$mdir")"
  local refused="$mdir/.issue-body.refused" carried="$mdir/.issue-body.carried"
  local rec="$mdir/.issue-body.parts"

  # Carried-forward parts accumulate here and are published only if the push
  # lands. TAB-separated, one line per part: <utc> <issue> <label> <what to do>.
  local carriedlines=""
  local now; now="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  _ib_carried() { carriedlines="$carriedlines$now	$issue	$1	$2
"; }

  # PART: the SPEC — precondition 2 of 2. A prd.md that EXISTS but is 0 bytes is
  # what a crashed or interrupted re-grill worker leaves behind. It composed
  # into a body whose entire spec section was two blank lines, which then went to
  # GitHub and wiped the spec (D3). The spec is the one REQUIRED part and it is
  # never carried forward — carrying a stale spec forward is the very defect
  # S188 exists to close — so this is the one genuine hard refusal.
  if [ ! -s "$mdir/prd.md" ]; then
    lcars_ib_refuse "$mdir" "$issue" 'the spec (prd.md)' \
      'prd.md is present but 0 bytes — an interrupted re-grill wrote nothing' \
      "restore $mdir/prd.md (or re-run the Align re-grill); the next transfer point pushes it"
    unset -f _ib_carried
    return 2
  fi

  local provf adrf
  provf="$(mktemp)" || { unset -f _ib_carried; return 0; }
  adrf="$(mktemp)"  || { rm -f "$provf"; unset -f _ib_carried; return 0; }

  local have_rec=0
  lcars_ib_rec_ok "$mdir" && have_rec=1

  # ---- PART: the PROVENANCE lead-in --------------------------------------
  # REBUILDABLE from state.json (origin=log + parentMission). CARRIED FORWARD
  # when state.json has lost the parent: the record holds the exact bytes.
  lcars_ib_provenance "$mdir" >"$provf"
  if [ ! -s "$provf" ] && [ "$have_rec" -eq 1 ] && lcars_ib_rec_has "$mdir" prov; then
    if cat "$rec/prov" >"$provf" 2>/dev/null && [ -s "$provf" ]; then
      _ib_carried 'Provenance line carried forward; state.json no longer names the parent mission' \
        "restore \"parentMission\" in $mdir/state.json to rebuild it from source"
    else
      : >"$provf"
    fi
  fi

  # ---- PART: the ADR set --------------------------------------------------
  # adr.md PRESENT and non-empty → rebuilt from source (the composer reads it).
  # adr.md PRESENT and 0 bytes   → REFUSE. The Validate stage rewrites adr.md
  #   from a worker's output (run.sh copies $odir/adr.md back), so a 0-byte
  #   adr.md is the same crash artifact a 0-byte prd.md is, and pushing it would
  #   delete the ADR set off the issue behind a dangling `---`.
  # adr.md ABSENT                → carried forward when the record says the
  #   issue carries one; simply absent when the record says it does not, or when
  #   there is no record (an absent adr.md is the NORMAL state of a trivial
  #   mission, so its absence is evidence of nothing).
  #
  # NEW-3 — REMOVING AN ADR FROM AN ISSUE. Deleting adr.md NEVER removes the ADR
  # from the issue, with or without a simultaneous re-grill. Before this round
  # those two acts disagreed: the deletion alone silently resurrected the ADR,
  # while deletion + re-grill refused the whole push for ever. One act, two
  # opposite answers, is not a design. The answer kept is CARRY, because the
  # issue is the handoff document and `.git/lcars/` is a cache: losing a cache
  # file must never delete content off GitHub, and nothing can tell a deliberate
  # deletion from a half-restored mission dir.
  #
  # So removal is an explicit act on the RECORD, not on the cache:
  #     rm -f <mission-dir>/adr.md <mission-dir>/.issue-body.parts/adr
  # — the composer then has no ADR to build and no ADR to carry, and the next
  # transfer point pushes the body without one. `lcars status` prints that exact
  # command on the line that announces the carry, so it is discoverable from the
  # only surface the captain reads.
  local adr_override=0
  if [ -f "$mdir/adr.md" ]; then
    if [ ! -s "$mdir/adr.md" ]; then
      rm -f "$provf" "$adrf"
      lcars_ib_refuse "$mdir" "$issue" 'the appended ADR set (adr.md)' \
        'adr.md is present but 0 bytes — an interrupted Validate re-write wrote nothing' \
        "restore $mdir/adr.md, or delete it to keep the ADR set the issue already carries"
      unset -f _ib_carried
      return 2
    fi
  elif [ "$have_rec" -eq 1 ] && lcars_ib_rec_has "$mdir" adr; then
    if cat "$rec/adr" >"$adrf" 2>/dev/null; then
      adr_override=1
      _ib_carried 'ADR set carried forward; adr.md is missing' \
        "restore $mdir/adr.md to change it, or delete $mdir/.issue-body.parts/adr as well to drop the ADR from the issue"
    fi
  fi

  # ---- PART: the ESTIMATE --------------------------------------------------
  # An explicit estimate argument (the `lcars log` lane passes one) is taken as
  # given. Otherwise: rebuild from estimate.json, else carry the recorded
  # section forward, else — only when there is NO record to consult — refuse,
  # because pushing blind is how D4 deleted all three board pills.
  if [ "$est" = "__LCARS_IB_AUTO__" ]; then
    est="$(lcars_ib_render_estimate "$mdir")"
    if [ -z "$est" ]; then
      if [ "$have_rec" -eq 1 ]; then
        if lcars_ib_rec_has "$mdir" est; then
          est="$(cat "$rec/est" 2>/dev/null)"
          _ib_carried 'Estimate carried forward; estimate.json is missing (the board pills on this issue are the ones last pushed, not a rebuild)' \
            "re-run the estimator (\`lcars run $mid --step\`) to rebuild it from source"
        fi
        # The record says the issue carries no Estimate section. Absent.
      else
        rm -f "$provf" "$adrf"
        lcars_ib_refuse "$mdir" "$issue" 'the "## Estimate" section' \
          'estimate.json is gone and there is no record of what the last pushed body carried, so a refresh cannot tell whether this issue has an Estimate section (losing it takes all three board pills with it)' \
          "restore $mdir/estimate.json (\`lcars run $mid --step\` re-runs the estimator); once any refresh succeeds the part record is seeded and this cannot recur"
        unset -f _ib_carried
        return 2
      fi
    fi
  fi

  # ---- compose from the resolved parts ------------------------------------
  # The part-source overrides go on as TEMPORARY assignments, scoped to the one
  # call (bash restores them on return — verified, not assumed), so no other
  # caller of the composer can ever see them and nothing has to unset them.
  # Never turn these into exports.
  local tmp; tmp="$(mktemp)" || { rm -f "$provf" "$adrf"; unset -f _ib_carried; return 0; }
  if [ "$adr_override" -eq 1 ]; then
    LCARS_IB_PROV_SRC="$provf" LCARS_IB_ADR_SRC="$adrf" \
      lcars_issue_body_compose "$mdir" align "$est" >"$tmp" \
      || { rm -f "$tmp" "$provf" "$adrf"; unset -f _ib_carried; return 0; }
  else
    LCARS_IB_PROV_SRC="$provf" \
      lcars_issue_body_compose "$mdir" align "$est" >"$tmp" \
      || { rm -f "$tmp" "$provf" "$adrf"; unset -f _ib_carried; return 0; }
  fi
  rm -f "$provf" "$adrf"
  unset -f _ib_carried

  # _ib_carry_publish — the carry breadcrumb is written (or cleared) at every
  # exit where the issue is CURRENT, so `lcars status` describes what the issue
  # carries right now and nothing older.
  _ib_publish_carried() {
    if [ -n "$carriedlines" ]; then printf '%s' "$carriedlines" >"$carried" 2>/dev/null || true
    else rm -f "$carried" 2>/dev/null || true; fi
  }

  # Skip an identical re-push: this is what keeps a Verify re-entry (reconcile,
  # a second drive pass) from spamming issue edits.
  local sum marker; marker="$mdir/.issue-body.sha"
  sum="$(cksum <"$tmp" | tr -d ' \n')"
  if [ -f "$marker" ] && [ "$(cat "$marker" 2>/dev/null)" = "$sum" ]; then
    rm -f "$tmp" "$refused"
    rm -rf "$mdir/.issue-body.parts.staged" 2>/dev/null || true
    _ib_publish_carried; unset -f _ib_publish_carried; return 0
  fi

  if lcars_ib_host issue-edit-body "$issue" <"$tmp" >/dev/null 2>&1; then
    printf '%s' "$sum" >"$marker" 2>/dev/null || true
    lcars_issue_body_record "$mdir" "$tmp"
    rm -f "$tmp" "$refused"
    _ib_publish_carried; unset -f _ib_publish_carried; return 0
  fi
  rm -f "$tmp"
  rm -rf "$mdir/.issue-body.parts.staged" 2>/dev/null || true
  unset -f _ib_publish_carried
  return 1
}
