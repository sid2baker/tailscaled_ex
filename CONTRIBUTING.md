# Contributing

## Development

Use Linux, Elixir 1.19+, and OTP 28+. Run:

```sh
mix deps.get
mix ci
mix docs --warnings-as-errors
mix hex.build
```

`mix ci` checks compilation, formatting, tests, Credo, Dialyzer, duplication, and
architecture rules. Tests do not start the default application or attach to a
workstation daemon. Keep new integration tests isolated, with temporary state and
sockets; do not change host networking.

To include real-daemon tests, set `TAILSCALED_TEST_BINARY` to an absolute path.
`TAILSCALED_TEST_NETWORK=1` additionally enables tests that contact Tailscale's
control plane. These tests do not establish enrolled-tailnet or hardware support.

### Real authentication (manual, protected)

`.github/workflows/tailnet.yml` is the only workflow with `id-token: write`. It runs
only via manual dispatch on `main`, in the `tailnet-ci` environment:

```sh
gh workflow run tailnet.yml --ref main
```

Setup:

- **GitHub:** create environment `tailnet-ci`, restricted to `main`, with
  environment secrets `TS_OAUTH_CLIENT_ID` and `TS_AUDIENCE`.
- **Tailscale:** create a dedicated
  [OIDC trust credential](https://tailscale.com/kb/1581/workload-identity-federation):
  - Issuer: `https://token.actions.githubusercontent.com`
  - Subject: `repo:sid2baker/tailscaled_ex:environment:tailnet-ci`
  - Custom claims:
    - `repository=sid2baker/tailscaled_ex`
    - `ref=refs/heads/main`
    - `workflow_ref=sid2baker/tailscaled_ex/.github/workflows/tailnet.yml@refs/heads/main`
    - `event_name=workflow_dispatch`
  - Scopes: `auth_keys` and `devices:core` (write).
  - Tag: `tag:ci`.

  Do not broaden this credential or tailnet policy to make the test pass.

The test exchanges a GitHub OIDC token for a temporary API token. It then creates
a 10-minute, single-use, ephemeral, preauthorized `tag:ci` key and enrolls an
isolated userspace daemon through `Tailscaled`'s own auth-key login. It verifies:

- the daemon is online with a Tailscale address;
- through the API, the node is authorized, ephemeral and tagged `tag:ci`;
- the identity survives a daemon restart;
- logout takes effect.

**Peer connectivity, routing and HTTPS Serve are not tested.**

Credentials stay in memory and are masked in the logs. Errors report only the
failing step and HTTP status; see Tailscale's **Trust credentials** page for
token-exchange details. On success or failure, the test logs out, deletes leftover
nodes with its random `tsx-auth-…` hostname and `tag:ci`, and revokes the key.

If the runner dies mid-test, check **Machines** for the logged hostname.
Tailscale removes [offline ephemeral nodes](https://tailscale.com/kb/1111/ephemeral-nodes)
on its own, and unused keys expire after 10 minutes.

Include regression tests for behavior changes. Describe user-visible changes in
`CHANGELOG.md` under `Unreleased`.
Do not use commit logs, test counts, or internal refactors as release notes.

When reporting problems, include library/daemon versions and the platform.
Never post auth keys, identity files, enrollment URLs, or unredacted daemon logs.

## Release checklist

Publication is manual. Building the package or pushing a commit does not publish it.

1. Choose the version, update `mix.exs`, and move `Unreleased` entries into a
   `## X.Y.Z - YYYY-MM-DD` section. Keep an empty `Unreleased` section above it.
2. Update the README's dependency version.
3. Run the checks above, including isolated real-daemon tests. Inspect the package
   contents: include source and documentation, never downloaded binaries or state.
4. Test the built package in a fresh consumer project without starting its application.
5. Commit the reviewed release changes and publish the Hex package and HexDocs.
6. Push the matching `vX.Y.Z` tag and create the GitHub Release. Its title must be
   exactly the tag; its body must be exactly the matching changelog section body,
   excluding the version heading. Use a notes file, not generated release notes.
7. Verify the registry version, HexDocs, remote tag, and GitHub Release contents.

Before 1.0, breaking API changes belong in a new minor version; document them
explicitly rather than treating every 0.x change as implicitly compatible.
