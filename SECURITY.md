# Security policy

## Report vulnerabilities privately

Do not put vulnerabilities, exploit details, credentials, or sensitive logs in
public issues or pull requests. If GitHub private vulnerability reporting is
enabled, use **Security > Advisories > Report a vulnerability** at
https://github.com/roferg/LCARS/security/advisories/new. This creates a private
report for repository maintainers, not a public issue.

If that option is unavailable, the alternative private channel is
**[PLACEHOLDER: OWNER MUST SET A PRIVATE SECURITY REPORTING CONTACT]**.
This placeholder is not a working contact. Until the owner configures a private
route, do not publish sensitive details as a workaround. This policy does not
enable GitHub reporting or change any repository setting.

Include the LCARS version or commit, host AI CLI and version, operating system,
affected skill or component, impact, and minimal reproduction steps. Use a
disposable repository; redact tokens, private source, and personal data.
Coordinate disclosure privately. There is no guaranteed response or fix SLA.

## Scope and supported versions

Reports are welcome for LCARS-owned skills, shell scripts, installer, harness,
and viewscreen, including command injection, unexpected writes outside intended
repositories, credential exposure, and failures of stated execution boundaries.
The latest released version is the maintenance target; older versions receive
no promised security backports. Mention older-version findings anyway if the
current release may also be affected. Ordinary bugs belong in public issues.

Issues confined to an upstream AI CLI, model provider, GitHub, or a dependency
should be reported to that project's private security channel. Report LCARS's
unsafe integration with those components here. Intended command execution is
not itself a vulnerability; bypasses of documented restrictions may be.

## Trust model: this software executes code

LCARS runs AI agents that execute shell commands and write to repositories.
It can run builds and tests, install dependencies, create branches, and use
authenticated GitHub operations. Workers act with the permissions, credentials,
network access, and filesystem access of their host CLI and account. LCARS is
not a security sandbox; prompts, tests, and human review are not isolation.

Treat repository content, issues, prompts, dependencies, and agent output as
potentially hostile input. Before pointing LCARS at anything valuable, use a
disposable clone or an isolated environment, keep backups, restrict credentials
and permissions, and review generated commands and diffs. Do not expose secrets
or repositories that an unattended worker must not read or modify. Data sent to
an AI provider is governed by that provider's configuration and policies.

**Unattended execution requires trusting the working directory.** That trust
loads the directory's hooks and plugins, as well as skills and MCP servers;
hooks can themselves execute shell commands. Only trust directories whose
provenance and executable configuration you control. Tool approval alone is
not directory trust. In Copilot, `--allow-all-tools` only approves tools, while
`COPILOT_ALLOW_ALL=true` (exactly `true`) also trusts the directory. Do not set
blanket trust for an unfamiliar checkout. See the
[unattended setup contract](skills/lcars-buddy/AUTOPILOT.md#unattended-copilot-setup-trust-the-working-directory-before-launch)
before launching without supervision.
