# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), with an explicit section
for breaking changes, and versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Added

- Bootstrap installation before target dependencies compile by preloading the Mix
  task from source with an explicit architecture.
- Explicit installer version and SHA-256 pins, verified archive caching, offline
  installation, and reuse of identical installed binaries without rewriting them.
- `Tailscaled.Installer.install!/2` for setup scripts without Mix or application startup.

## 0.4.0 - 2026-10-19

### Added

- `Tailscaled.Testing.auth_key/1` creates short-lived, single-use auth keys for tests
  and CI from a GitHub Actions OIDC identity through Tailscale workload identity
  federation.

## 0.3.0 - 2026-10-15

### Breaking changes

- Use `/data/tailscaled_ex` on Nerves and `~/.local/share/tailscaled_ex` elsewhere
  for default identity storage.

## 0.2.0 - 2026-10-15

### Breaking changes

- Default `accept_dns` to `false` for complete configuration replacement and reset.
  Startup, login, and partial updates do not override saved DNS preferences.

### Added

- Supervised daemon management and external-daemon attachment through LocalAPI.
- Browser and auth-key login, logout, HTTPS Serve, cached state, and subscriptions.
- Partial configuration updates that preserve omitted settings.
- `refresh_configuration/0` to explicitly refresh cached settings after external changes,
  including Serve edits that do not emit daemon notifications.
- `up/0` and `down/0` commands with running-preference readback, without logging out
  or resetting configuration. These do not guarantee termination of existing forwarding.
- Target-aware installation of the tested daemon with SHA-256 verification.

### Fixed

- Reject a hostname change combined with nonempty Serve configuration before writing,
  rather than binding Serve to the previous DNS name.
- Clear cached identity, peers, and authentication state when the daemon resets its profile.
- Return a validation error for invalid UTF-8 Serve targets instead of crashing the controller.

### Security

- Redact enrollment URLs and raw notifications from formatted monitor status and crash
  reports, and redact HTTP(S) URLs in health warnings printed by `info/0`.
- Keep auth keys out of controller diagnostic output, including OTP debug logs.

### Compatibility

- Requires Linux, Elixir 1.19 or later, and OTP 28 or later.
- Tested with Tailscale 1.102.3; later 1.x versions require compatibility testing.
