defmodule Tailscaled do
  @moduledoc """
  Supervised integration with the `tailscaled` daemon for Elixir and Nerves.

  The daemon owns configuration, identity, authentication, and persistence.
  This library manages its lifecycle, issues commands, and caches observations.
  The OTP application starts automatically; do not add it to your supervision tree.
  Commands wait for the observer's initial snapshot, returning an error if unavailable.
  Cache reads and subscriptions never perform daemon I/O.

  ## Application options

  Set these with `config :tailscaled_ex, option: value`. They are read at application
  startup; change running daemon settings with `update_configuration/1` instead.

  | Option | Default | Purpose |
  | --- | --- | --- |
  | `:manage_daemon` | `true` | Start and supervise a daemon; `false` attaches to an existing one. |
  | `:daemon_path` | `"tailscaled"` | Executable name on PATH or path on the running device. |
  | `:tun` | `:kernel` | `:kernel` uses `tailscale0`; `:userspace` needs no TUN; a string names a TUN interface. |
  | `:data_dir` | See below | Base directory for managed daemon storage. |
  | `:state_dir` | `<data_dir>/identity` | Daemon identity and profile storage. |
  | `:socket` | See below | LocalAPI Unix socket. |
  | `:port` | `0` | Managed daemon UDP port; `0` chooses automatically. |
  | `:config` | `%{}` | Managed defaults for `reset_to_defaults/0`, never applied at startup. |
  | `:timeout` | `5_000` | LocalAPI request and command readiness timeouts, in milliseconds. |
  | `:initial_timeout` | `10_000` | Milliseconds to receive an initial watch snapshot. |
  | `:retry_min`, `:retry_max` | `200`, `30_000` | Backoff bounds in milliseconds for restarts, reconnects, and failed reads. |
  | `:auth_url_ttl` | `600_000` | Maximum cached login URL lifetime in milliseconds. |
  | `:max_body`, `:max_frame` | `4_194_304` each | Byte limits for HTTP response bodies and watch frames. |

  `data_dir` defaults to `/data/tailscaled_ex` when Nerves.Runtime is available,
  otherwise `~/.local/share/tailscaled_ex`. Use durable writable storage for identity.
  The managed socket defaults to `<data_dir>/run/tailscaled.sock`.

  To attach to an existing daemon:

      config :tailscaled_ex,
        manage_daemon: false,
        socket: "/var/run/tailscale/tailscaled.sock"

  This is also the default socket in external mode. The application needs permission
  to use it; commands change that daemon's settings. Launch options such as `:tun`,
  `:daemon_path`, and `:state_dir` do not reconfigure an external daemon.

  Userspace mode supports Serve without root or a TUN device, but creates no
  host-wide interface. Kernel mode requires TUN support and OS permissions;
  kernel subnet routing also needs IP forwarding. Userspace subnet routing has
  protocol limitations. Advertising routes still requires tailnet route approval.
  Tailscale SSH needs tailnet SSH policy, local OS accounts, and permission to start
  their sessions; it is not restricted to kernel mode. See Tailscale's
  [routing modes](https://tailscale.com/kb/1177/kernel-vs-userspace-routers) and
  [SSH setup](https://tailscale.com/kb/1193/tailscale-ssh) for prerequisites.

  Tailscale 1.102.3 is the tested protocol baseline. The observer accepts 1.102.3+
  within 1.x, but later versions still need compatibility testing.

  ## Managed settings

  Both configuration APIs accept an atom-keyed map of these fields only:

  | Field | Library default | Values |
  | --- | --- | --- |
  | `:hostname` | `""` | DNS label up to 63 characters, normalized to lowercase; empty uses the daemon's default hostname. |
  | `:accept_dns` | `false` | Whether to accept tailnet DNS configuration; opt in with `true`. |
  | `:accept_routes` | `false` | Whether to accept advertised subnet routes. |
  | `:ssh` | `false` | Whether to enable Tailscale SSH. |
  | `:advertise_routes` | `[]` | CIDR strings or `{ip_tuple, prefix_length}`; normalized to sorted, unique network CIDRs. |
  | `:advertise_tags` | `[]` | Requested ACL tags, sorted and deduplicated. `tag:` followed by an ASCII letter, then ASCII letters, digits or `-`; case is preserved. |
  | `:serve` | `[]` | `[%{https: port, to: "http://127.0.0.1:4000"}]`; unique ports in `1..65535`, HTTP(S) targets without userinfo or fragments. |

  DNS management is opt-in: `accept_dns: false` leaves it to the device's network
  stack and avoids `/etc/resolv.conf` write errors on read-only Nerves filesystems.
  This does not disable tailnet connectivity or inbound Serve, but does not configure
  the device to resolve other peers' MagicDNS names.

  `configure/1` replaces all of these fields; `update_configuration/1` preserves
  omitted fields. Startup only reads settings, and login does not apply these defaults.
  `reset_to_defaults/0` explicitly applies `:config` with library defaults for its
  omitted fields. A fresh or existing daemon may still have DNS enabled; use
  `update_configuration(%{accept_dns: false})` to disable it without resetting other
  settings.

  Set `:advertise_tags` before `login/1` to request tags on first registration.
  Tags require permission through the tailnet's `tagOwners`; the node cannot grant
  itself tags. Auth-key tags can also contribute to granted tags. Tagged nodes are
  tag-owned and have key expiry disabled by default.

  `:advertise_tags` is a request, not proof of a grant. Read `get(["self", "tags"])`
  for granted tags. On Tailscale 1.104.1, preference updates send new `RequestTags`
  even while running; the CLI takes its `Start` path for tag changes. Neither that
  client source nor successful preference readback guarantees the server accepts
  every existing-node tag transition without re-authentication. The library only
  writes preferences; it never logs out, restarts registration, or forces re-auth.
  If the server requires re-authentication, it must be operator-authorized.

  Setting `:serve` replaces all top-level TCP/Web listeners and disables Funnel,
  including settings made outside this library. Separate Tailscale Services are
  preserved; active foreground Serve configurations cause an error. Each endpoint
  proxies `/` over HTTPS on the observed tailnet DNS name. Enable MagicDNS and HTTPS
  in the tailnet first. This does not replace the upstream app's authentication.

  Writes are serialized between library callers and verified by readback, not
  automatically retried. Preferences and Serve are separate operations and may
  partially apply. Concurrent external changes can cause a conflict; inspect
  `get_configuration/0` before deciding whether to retry. Settings made before
  enrollment can be lost on daemon restart.

  ## Properties

  Subscribe **before** reading an initial value. Properties are cached observations,
  not a live connectivity check. Runtime properties are never persisted.

  * `["state"]`: `:unavailable | :offline | :online`. Online means backend Running;
    unavailable means the observer cannot determine connectivity.
  * `["backend_state"]`: `:unknown | :no_state | :in_use_other_user | :needs_login |
    :needs_machine_auth | :stopped | :starting | :running`.
  * `["ipv4"]`, `["ipv6"]`: Erlang IP tuples; absent until assigned.
  * `["hostname"]`, `["dns_name"]`: self host and tailnet DNS names.
  * `["self", "tags"]`: control-plane-granted self tags; `[]` when absent or nil.
    These are independent of requested `:advertise_tags` in the configuration cache.
  * `["auth", "state"]`: `:unknown | :needs_login | :authenticating |
    :needs_approval | :authenticated | :stopped | :error`.
  * `["auth", "url"]`: secret HTTPS enrollment URL, removed on completion, error,
    disconnect, profile reset, or cache expiry. `:auth_url_ttl` does not extend the server's URL validity.
  * `["auth", "error"]`: sanitized failure category, absent on success.
  * `["peers", id, field]`: stable node ID (numeric fallback), with `"hostname"`,
    `"dns_name"`, `"ipv4"`, `"ipv6"`, `"online"`, and `"tags"` fields. Peer tags are
    control-plane-granted and default to `[]`; other missing values are absent.
  * `["health"]`: raw daemon health warning strings; these can contain login URLs.
    `info/0` redacts HTTP(S) URLs when displaying them.
  * `["configuration", "value"]`: cached managed configuration, absent when preferences
    are unreadable. The `:serve` field is omitted when Serve cannot be read or represented.
  * `["configuration", "state"]`: `:ready | :applying | :error` (latest operation/read).
  * `["configuration", "error"]`: sanitized failure reason, absent on a successful read.
  * `["monitor", "connected"]`, `["monitor", "generation"]`, `["monitor", "error"]`:
    stream diagnostics. `["version"]` is the daemon version.
  * `["daemon", "state"]`: `:external | :running | :restarting`; process status,
    not tailnet connectivity.

  Disconnects and profile resets clear cached identity and peers. A stopped backend
  can retain assigned addresses; use `["state"]`, not an address, to check online status.
  Treat login URLs and raw health text as sensitive, including subscription messages.
  See the README for installation and a quick start.
  """

  alias Tailscaled.Controller

  @type path :: [String.t()]
  @type pattern :: [String.t() | :_]
  @type configuration :: %{
          optional(:hostname) => String.t(),
          optional(:accept_dns) => boolean(),
          optional(:accept_routes) => boolean(),
          optional(:ssh) => boolean(),
          optional(:advertise_routes) => [String.t() | {:inet.ip_address(), non_neg_integer()}],
          optional(:advertise_tags) => [String.t()],
          optional(:serve) => [%{https: 1..65_535, to: String.t()}]
        }
  @type result :: :ok | {:error, term()}

  @doc """
  Replace the complete managed configuration. Omitted fields use library defaults.
  Returns the LocalAPI apply/readback result, not a guarantee of disk durability;
  failed writes are never queued or retried. Preferences and Serve are not one
  transaction: an error can leave partial changes.
  Persistence follows the daemon's profile lifecycle (unenrolled profiles are memory-only).
  Authentication keys and unknown fields are rejected. `:advertise_tags` requests
  tags; set it before `login/1` for first registration. A successful write does not
  mean the server granted them; observe `["self", "tags"]`.

  Changing hostname and setting nonempty Serve in the same call is rejected before
  writes (`:hostname_change_requires_separate_serve`). Rename first, wait for the new
  `["dns_name"]`, then explicitly reapply Serve; existing listeners are not automatically
  rebound when the hostname changes.
  """
  @spec configure(configuration()) :: result()
  def configure(config), do: Controller.configure(Controller, config)

  @doc """
  Change selected managed settings while running. Omitted fields are preserved;
  lists are replaced, not appended (`serve: []` removes all managed listeners;
  `advertise_tags: []` clears the request, not a promise to revoke granted tags).
  Changing requested tags never triggers logout or re-authentication.

  Serializes library callers and writes only supplied preference fields. Omitted
  Serve settings are left untouched, even if this library cannot represent them.
  A failure to observe omitted Serve settings does not fail a preference update;
  it is reported through the configuration cache instead. Validation, readback,
  and persistence semantics are otherwise the same as `configure/1`.
  External writes and the separate preferences/Serve operations are not transactional.
  """
  @spec update_configuration(configuration()) :: result()
  def update_configuration(changes), do: Controller.update_configuration(Controller, changes)

  @doc """
  Return cached daemon settings, or nil when preferences are unavailable.
  The `:serve` field is omitted when unreadable or unsupported; see
  `["configuration", "error"]` for the reason. Missing Serve is not an empty list.

  This never performs daemon I/O. External Serve changes may not emit notifications;
  call `refresh_configuration/0` first when a fresh observation is needed.
  """
  @spec get_configuration() :: configuration() | nil
  def get_configuration, do: get(["configuration", "value"])

  @doc """
  Read preferences and Serve from the daemon and update the configuration cache.
  Returns `:ok` or a read error; use `get_configuration/0` to read the result.
  Waits for observer readiness and serializes with library commands, but never writes
  daemon settings. Failed reads use the existing observation retry mechanism.
  """
  @spec refresh_configuration() :: result()
  def refresh_configuration, do: Controller.refresh_configuration(Controller)

  @doc """
  Apply the `:config` map read at application startup, filling omitted fields with
  library defaults. For example, `config :tailscaled_ex, config: %{accept_dns: true}`
  makes an explicit reset enable Tailscale DNS management and reset all other managed fields.
  With no `:config`, this is equivalent to `configure(%{})`. It does not log out
  or delete identity. The validation and partial-write semantics of `configure/1` apply.
  """
  @spec reset_to_defaults() :: result()
  def reset_to_defaults, do: Controller.reset(Controller)

  @doc "Read a cached property, returning `default` if absent."
  @spec get(path(), term()) :: term()
  def get(path, default \\ nil), do: PropertyTable.get(Tailscaled.Properties, path, default)

  @doc "Return cached `{path, value}` pairs matching a prefix (or `:_` wildcard)."
  @spec get_by_prefix(pattern()) :: [{path(), term()}]
  def get_by_prefix(path), do: PropertyTable.match(Tailscaled.Properties, path)

  @doc """
  Subscribe the calling process to a prefix/wildcard, before reading its initial value.
  No initial snapshot is sent. For example, `["auth"]` matches all auth properties,
  and `["peers", :_, "online"]` matches each peer's online status.
  Messages are `{Tailscaled, path, old, new, %{old_timestamp: old_ts, new_timestamp: ts}}`.
  Timestamps use native monotonic time units; deleted values are `nil`.
  """
  @spec subscribe(pattern()) :: :ok
  def subscribe(path), do: PropertyTable.subscribe(Tailscaled.Properties, path)

  @doc "Stop the calling process's subscription for this exact pattern."
  @spec unsubscribe(pattern()) :: :ok
  def unsubscribe(path), do: PropertyTable.unsubscribe(Tailscaled.Properties, path)

  @doc """
  Request that Tailscale run by setting only `WantRunning=true`.
  Does not initiate login or reset configuration; use `login/1` if authentication
  is needed. `:ok` confirms preference readback, not that the device is online.
  Observe `["state"]` through `get/1` or subscriptions for connectivity.
  The command is serialized with other library writes and is never automatically retried.
  """
  @spec up() :: result()
  def up, do: Controller.set_running(Controller, true)

  @doc """
  Request that Tailscale stop by setting only `WantRunning=false`.
  Does not log out, delete identity, reset configuration, or terminate the daemon;
  LocalAPI remains available. `:ok` confirms preference readback, not that every
  existing proxy session or in-flight packet has terminated. This is not a verified
  forwarding barrier and does not change startup behavior.
  The command is serialized with other library writes and is never automatically retried.
  """
  @spec down() :: result()
  def down, do: Controller.set_running(Controller, false)

  @doc """
  Return `{:ok, url}` for browser enrollment, or `:ok` if already running.
  Waits up to 30 seconds for the URL after initiating login, never for browser
  completion. Override this URL wait with `timeout: milliseconds`. A timeout
  does not cancel enrollment; call again after an interruption or URL expiration.

  With `auth_key: key`, returns `:ok` after initiating unattended enrollment, not
  confirmation that the key was accepted. Read `["state"]` or `["auth", "state"]`,
  or subscribe to `["auth"]`, for completion and failures. Machine approval is
  reported as `{:error, :needs_approval}` for browser login.

  Use either `timeout: milliseconds` or `auth_key: key`, not both. The URL timeout
  starts after login initiation; it is not an overall command deadline. The library
  does not persist keys or login URLs; the daemon stores the enrolled identity.
  Keep keys out of application configuration and treat login URLs as secrets.
  """
  @spec login(keyword()) :: result() | {:ok, String.t()}
  def login(opts \\ [])
  def login([]), do: login(timeout: 30_000)

  def login(timeout: timeout) when is_integer(timeout) and timeout in 1..4_294_967_295 do
    with :ok <- Controller.login(Controller, :interactive) do
      Tailscaled.Monitor.await_login(Tailscaled.Monitor, timeout)
    end
  end

  def login(auth_key: key) when is_binary(key) and byte_size(key) in 1..4096 do
    Controller.login(Controller, {:auth_key, key})
  end

  def login(auth_key: _), do: {:error, :invalid_auth_key}

  def login(_), do: {:error, :invalid_options}

  @doc "Log out without deleting the daemon's identity store."
  @spec logout() :: result()
  def logout, do: Controller.logout(Controller)

  @doc """
  Print cached status, configuration, and peers without daemon I/O.
  Omits the auth URL and redacts all HTTP(S) URLs in health warnings, including
  expired login URLs. Raw properties and subscription messages are not redacted.
  """
  @spec info() :: :ok
  def info, do: Tailscaled.Info.print()
end
