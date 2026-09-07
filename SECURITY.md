# Security policy

## Supported releases

Security fixes are made on the latest tagged release and `main`.

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability. Use GitHub's private vulnerability
reporting for `tyejcoleman/agent-deck`, or contact the repository owner through the private address
listed on their GitHub profile. Include the affected version, operating system, reproduction steps,
and whether credentials or task contents may have been exposed.

## Credential boundary

Agent Deck records account pointers, routing state, usage, and task handoffs under `.deck/`. It does
not intentionally store OAuth tokens or API keys there. Vendor CLIs retain OAuth credentials in their
own per-account configuration directories; API keys use the operating-system keychain when available
and otherwise a mode-0600 file outside `.deck/`.

Before sharing a deck, review task context, handoff, event, and run-log files. They may contain project
content or command output even though the protocol excludes credentials.

Installers verify the tagged `deck` binary against a release-specific SHA-256 digest. For independent
verification, download `SHA256SUMS` from the matching GitHub release.
