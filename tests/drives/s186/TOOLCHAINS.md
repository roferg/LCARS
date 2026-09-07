# S186 — measured toolchain ground truth (2026-09-06)

Probed END TO END by the orchestrator before the session's first sub-agent, on
the captain's machine. These are RUN facts. A later session on another machine
MUST re-probe rather than trust this file — the whole point of the real-vs-
transcript ledger is that an arm is only proven where its toolchain exists.

| arm | toolchain | install needed? | proven cycle | verdict |
|-----|-----------|-----------------|--------------|---------|
| rust   | cargo 1.94.0 / rustc 1.94.0 | NONE | `cargo init` → `cargo test` → 1 passed | **REAL** |
| go     | go 1.26.4                   | NONE | `go mod init` + `_test.go` → `go test ./...` → ok 0.283s | **REAL** |
| dotnet | dotnet 10.0.107             | yes  | `dotnet new xunit` → Restore succeeded → `dotnet test` → Passed! 1/1 | **REAL** |
| ruby   | ruby 2.6.10, rspec 3.13.6, minitest 5.11.3 | yes | minitest `ruby -Itest` → 1 runs 0 failures; `rspec` → 1 example 0 failures | **REAL** (see wrinkle) |
| python | python3 3.14.6              | NONE for unittest | `python3 -m unittest discover` → Ran 1 test, OK | **REAL** (unittest only) |
| jvm    | — no java, no gradle, no mvn | n/a | NOT EXECUTED | **TRANSCRIPT ONLY — NOT PROVEN** |

## The ruby wrinkle — a real hazard, not a fixture quirk
The `rspec` binary is NOT on the default PATH. The gem resolves to
`~/.gem/ruby/2.6.0/gems/rspec-core-3.13.6/exe/rspec`, and running it needs
`~/.gem/ruby/2.6.0/bin` on PATH. So a declared `gem install rspec` lands in the
USER gem dir whose bin dir the shell does not search, and a probe-verified
install can install a runner it then cannot resolve. The ruby arm must not
assume `gem install` yields a runnable `rspec`.

Also: system ruby here is 2.6.10, so Ruby 3+ syntax (endless methods,
`def f(a,b) = a+b`) is a SyntaxError. Keep ruby fixtures 2.6-compatible.

## The python fork — settled on evidence
`pip3 install pytest` HARD-FAILS on this machine:

    error: externally-managed-environment
    … override … by passing --break-system-packages

(PEP 668; Homebrew python 3.14.) `python3 -m unittest` needs no install and
runs. Orchestrator ruling: python is stamped as a ZERO-INSTALL arm on
`unittest`, the same shape as rust and go. `pip`/`uv`/`poetry` remain
ALLOWLISTED — the table is what is PERMITTED, the PRD guidance is what is
RECOMMENDED, and they are deliberately not the same list. LCARS must NEVER emit
`--break-system-packages`: it trades a test runner for a broken OS python.

## The jvm ledger
Not proven. Captain ruling 2026-09-06 expanded S192's capstone to drive EVERY
arm live on Copilot; the jvm leg is blocked until a JDK + gradle exist on the
machine. That precondition is recorded in greenfield-dev.md's S192 entry.
