# Tailscaled for Elixir and Nerves

Supervise the `tailscaled` daemon and use its LocalAPI for configuration, login,
HTTPS Serve, and state subscriptions.
Requires Linux, Elixir 1.19+, and OTP 28+. Tested with Tailscale **1.102.3**.

## 1. Install

Add the Hex dependency to `mix.exs`:

```elixir
{:tailscaled_ex, "~> 0.4.0"}
```

For Nerves, download the daemon into your firmware overlay:

```sh
export MIX_TARGET=rpi4 # Change to your firmware target.
mix deps.get
mix tailscaled.install rootfs_overlay/usr/sbin/tailscaled
```

```elixir
# config/config.exs
config :nerves, :firmware, rootfs_overlay: "rootfs_overlay"
config :tailscaled_ex, daemon_path: "/usr/sbin/tailscaled", tun: :userspace
```

On a Linux host, use `mix deps.get` and `mix tailscaled.install ./bin/tailscaled`,
then set `daemon_path` to its absolute runtime path and `tun: :userspace`.
The installer verifies the checksum and detects the target architecture;
see `mix help tailscaled.install` for overrides. Use separate overlays per architecture.

The application starts automatically—do not add it to your supervision tree.
Userspace mode supports Serve without root or TUN. For a host-wide network interface,
use `tun: :kernel` with TUN support and OS permissions.

Store identity on durable writable storage. `data_dir` defaults to
`/data/tailscaled_ex` on Nerves and `~/.local/share/tailscaled_ex` elsewhere.
For an existing daemon or other options, see the
[API reference](https://github.com/sid2baker/tailscaled_ex/blob/main/lib/tailscaled.ex).

## 2. Configure and log in

In your application's IEx session:

```elixir
:ok = Tailscaled.update_configuration(%{hostname: "my-device", accept_dns: false})
Tailscaled.login() # Returns {:ok, url}; open it in a browser. Already online: :ok.
Tailscaled.info()
```

The library defaults to `accept_dns: false`, leaving system DNS to the device's
network stack and avoiding `/etc/resolv.conf` write errors on read-only Nerves
filesystems. Set it to `true` to opt into tailnet DNS. The explicit update above
is still needed because startup and login do not apply library defaults.

For unattended login, use `Tailscaled.login(auth_key: key)` with a key from your
secret source. Login initiates enrollment; observe `["state"]` for `:online`.
Browser login waits up to 30 seconds for a URL, not browser completion.
Treat keys and login URLs as secrets.

`update_configuration/1` preserves omitted fields; `configure/1` resets them to
library defaults. Startup only reads settings. The daemon owns persistence;
settings made before enrollment may be lost on restart. Commands return errors
without retrying writes, and multi-setting changes can partially apply.

Use `Tailscaled.down()` and `Tailscaled.up()` to set the daemon's `WantRunning`
preference without logging out or resetting configuration. `:ok` confirms readback,
not connectivity or termination of every existing proxy session. The daemon stays
running; startup behavior is unchanged. `up/0` does not initiate login.

## 3. Serve your app over HTTPS

Enable MagicDNS and HTTPS in your tailnet. After login, check
`Tailscaled.get(["dns_name"])` for the expected name, then:

```elixir
:ok = Tailscaled.update_configuration(%{
  serve: [%{https: 443, to: "http://127.0.0.1:4000"}]
})
```

Visit `https://<dns_name>/` from an authorized tailnet device. This is not public
Funnel access or a replacement for app authentication. Setting `serve` replaces
all top-level listeners and clears Funnel; `serve: []` removes them.
Rename separately, wait for the new DNS name, then reapply Serve.

## 4. Read state and subscribe

Subscribe before reading; events report changes, not an initial snapshot:

```elixir
:ok = Tailscaled.subscribe(["state"])
Tailscaled.get(["state"]) # :unavailable | :offline | :online
Tailscaled.get(["ipv4"])
Tailscaled.get_by_prefix(["peers"])
# Messages: {Tailscaled, path, old_value, new_value, timestamps}
```

Reads are cached. `:online` means the backend reports Running, not a successful
internet or peer-reachability probe. Use `Tailscaled.info()` for a readable report.
External Serve edits may not emit notifications; call `Tailscaled.refresh_configuration()`
before `Tailscaled.get_configuration()` when you need a fresh configuration observation.
There is no background polling.
See the [API reference](https://github.com/sid2baker/tailscaled_ex/blob/main/lib/tailscaled.ex)
for settings, properties, login options, and logout.

## 5. Test your Tailscale integration

Test most of your code without a daemon, and keep one opt-in test that joins a real
test tailnet.

### Ordinary tests: no daemon

This library's application also starts during your tests. Keep it from starting a
daemon in `config/test.exs`:

```elixir
config :tailscaled_ex, manage_daemon: false, socket: "/nonexistent/tailscaled.sock"
```

State then reads `:unavailable`, and commands return `{:error, :unavailable}`.
To test how your code reacts to Tailscale, send your process the messages a
subscription would deliver:

```elixir
send(pid, {Tailscaled, ["state"], :offline, :online, %{old_timestamp: 0, new_timestamp: 0}})
```

Replace your own calls to `Tailscaled` with a test double where you need specific
command results.

### A real tailnet test, on request

When `TAILSCALED_TEST_BINARY` is set, give tests their own userspace daemon with fresh
state in `config/runtime.exs`. It runs alongside any `tailscaled` already on the
machine without touching it:

```elixir
binary = System.get_env("TAILSCALED_TEST_BINARY")

if config_env() == :test and binary do
  dir = Path.join(System.tmp_dir!(), "my_app-tailscaled-#{System.os_time()}")

  config :tailscaled_ex,
    manage_daemon: true,
    daemon_path: binary,
    tun: :userspace,
    data_dir: dir,
    socket: Path.join(dir, "run/tailscaled.sock")
end
```

Exclude the test by default with `ExUnit.start(exclude: [:tailnet])` in
`test/test_helper.exs`:

```elixir
defmodule MyApp.TailnetTest do
  use ExUnit.Case, async: false
  @moduletag :tailnet
  @moduletag timeout: 120_000

  setup do
    on_exit(fn -> Tailscaled.logout() end) # removes the ephemeral node
  end

  test "joins the test tailnet" do
    {:ok, key} =
      case System.get_env("TAILSCALED_TEST_AUTH_KEY") do
        nil -> Tailscaled.Testing.auth_key()
        key -> {:ok, key}
      end

    :ok = Tailscaled.subscribe(["state"])
    :ok = Tailscaled.login(auth_key: key)
    assert_receive {Tailscaled, ["state"], _, :online, _}, 60_000

    # Then exercise your own workflow, such as applying your Serve configuration.
  end
end
```

**Locally**, create an auth key for testing in the admin console (**Settings → Keys**):
**Reusable**, **Ephemeral**, **Pre-approved**, and tagged, ideally in a tailnet used
only for testing. Then run:

```sh
mix tailscaled.install /tmp/tailscaled-test/tailscaled
TAILSCALED_TEST_AUTH_KEY=tskey-auth-... TAILSCALED_TEST_BINARY=/tmp/tailscaled-test/tailscaled \
  mix test --only tailnet
```

**In GitHub Actions**, `Tailscaled.Testing.auth_key/1` creates a short-lived,
single-use key from the job's OIDC identity, so no key is stored. Create the Tailscale
trust credential described in its
[module docs](https://github.com/sid2baker/tailscaled_ex/blob/main/lib/tailscaled/testing.ex),
then:

```yaml
jobs:
  tailnet:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      id-token: write
    env:
      MIX_ENV: test
      TS_OAUTH_CLIENT_ID: ${{ secrets.TS_OAUTH_CLIENT_ID }}
      TS_AUDIENCE: ${{ secrets.TS_AUDIENCE }}
      TS_TAGS: tag:ci
    steps:
      - uses: actions/checkout@v4
      - uses: erlef/setup-beam@v1
        with:
          otp-version: "28"
          elixir-version: "1.19"
      - run: mix deps.get
      - run: mix tailscaled.install "$RUNNER_TEMP/tailscaled"
      - run: TAILSCALED_TEST_BINARY="$RUNNER_TEMP/tailscaled" mix test --only tailnet
```

This shows that login works and that your settings reach the daemon, not that other
devices can reach your app. For Nerves projects, run it on the host; it does not cover
the device, firmware, or kernel networking.

## Development

Run `mix deps.get && mix ci`. To include isolated real-daemon tests:

```sh
TAILSCALED_TEST_BINARY=/absolute/path/to/tailscaled mix ci
```

Add `TAILSCALED_TEST_NETWORK=1` to enable control-plane URL and invalid-key tests.
Tests never attach to a host daemon; they do not cover enrolled-tailnet HTTPS or hardware.
Run `mix docs --warnings-as-errors` to build the API documentation. See
[CONTRIBUTING.md](CONTRIBUTING.md) for development and release checks.

## License

[Apache License 2.0](https://github.com/sid2baker/tailscaled_ex/blob/main/LICENSE)
