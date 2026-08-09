# Security policy

## Supported scope

This pre-release scaffold has no network service, account system, analytics, or
active cloud entitlement. Security findings may still affect local files,
privacy declarations, dependency choices, or future capture/export code.

Private CloudKit backup is opt-in and operator-configured only; no default
container, public/shared database, background synchronization, or automatic
upload is present. Treat unexpected access before explicit Check/List/Back up/
Recover, unsafe scratch cleanup, malformed archive recovery, permission-copy
errors, or privacy-manifest drift as reportable issues.

## Reporting

Please do not disclose a suspected vulnerability in a public issue. Use the
repository's private security-advisory feature when it is enabled, or contact
the project maintainers through a verified project channel and include:

- a concise impact statement;
- affected file, version, or commit;
- safe reproduction steps;
- suggested mitigation, if known.

Do not attach real room captures, location data, or private photos unless the
maintainers have explicitly arranged a secure transfer.

## Response expectations

Maintainers should acknowledge a report, assess reproducibility, coordinate a
fix before public disclosure, and document any security-relevant release note.
Release decisions still require independent macOS, device, CloudKit development
container, and App Store privacy validation; host-static checks do not replace
those gates.
