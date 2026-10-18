defmodule Tailscaled.DaemonIntegrationTest do
  use ExUnit.Case, async: false
  import Tailscaled.Test.Fixture, only: [eventually: 1, eventually: 2]
  alias Tailscaled.{Controller, LocalAPI, Monitor}
  alias Tailscaled.Test.{Fixture, Tailnet}

  @moduletag :integration
  @moduletag timeout: 90_000

  setup ctx do
    binary = System.fetch_env!("TAILSCALED_TEST_BINARY")
    hostname = "tsx-auth-#{Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)}"

    tailnet =
      if ctx[:real_auth] do
        IO.puts("Real-auth test node: #{hostname}")
        assert {:ok, tailnet} = Tailnet.create_key(hostname)
        tailnet
      end

    directory = Path.join(System.tmp_dir!(), hostname)
    File.mkdir!(directory)
    File.chmod!(directory, 0o700)

    opts =
      Fixture.options(__MODULE__, Path.join(directory, "run/tailscaled.sock"),
        data_dir: directory,
        daemon_path: binary,
        manage_daemon: true,
        tun: :userspace,
        config: %{hostname: "must-not-apply", accept_dns: false},
        retry_min: 100,
        retry_max: 500
      )

    if tailnet do
      on_exit(fn ->
        # Logout removes the ephemeral node; the API then removes any leftovers.
        local = Fixture.cleanup_authenticated_daemon(opts, directory, hostname)
        assert {local, Tailnet.cleanup(tailnet)} == {:ok, :ok}
      end)

      # ExUnit stops supervised children before on_exit. Keep this owned tree alive
      # until the callback can log out, including after assertion failures/timeouts.
      {:ok, pid} = Tailscaled.Application.start(:normal, opts)
      Process.unlink(pid)
    else
      start_supervised!({Fixture, opts})
      on_exit(fn -> File.rm_rf(directory) end)
    end

    assert :ok = Monitor.ready(opts[:monitor], 10_000)

    eventually(fn ->
      assert PropertyTable.get(opts[:table], ["configuration", "state"]) == :ready
    end)

    %{opts: opts, table: opts[:table], directory: directory, hostname: hostname, tailnet: tailnet}
  end

  test "real daemon owns preferences, including memory-only preferences before enrollment", ctx do
    assert PropertyTable.get(ctx.table, ["state"]) == :offline
    assert configuration(ctx).hostname == ""
    assert configuration(ctx).accept_dns

    assert :ok =
             Controller.configure(ctx.opts[:controller], %{hostname: "tsx-integration"})

    assert configuration(ctx).hostname == "tsx-integration"

    assert {:ok, %{"Hostname" => "tsx-integration", "CorpDNS" => false}, _} =
             LocalAPI.request(ctx.opts, "GET", "prefs")

    assert :ok = Controller.update_configuration(ctx.opts[:controller], %{accept_routes: true})

    assert {:ok, %{"Hostname" => "tsx-integration", "CorpDNS" => false, "RouteAll" => true}, _} =
             LocalAPI.request(ctx.opts, "GET", "prefs")

    # Restarting the controller rehydrates from the still-running daemon, not defaults.
    assert :ok = Supervisor.terminate_child(ctx.opts[:supervisor], Controller)
    PropertyTable.delete(ctx.table, ["configuration", "value"])
    assert {:ok, _} = Supervisor.restart_child(ctx.opts[:supervisor], Controller)
    eventually(fn -> assert PropertyTable.get(ctx.table, ["configuration", "value"]) != nil end)
    assert configuration(ctx).hostname == "tsx-integration"

    # A fresh unenrolled profile has nowhere to persist Serve configuration yet.
    assert {:ok, nil, headers} = LocalAPI.request(ctx.opts, "GET", "serve-config")
    assert List.keyfind(headers, "etag", 0)

    assert {:error, :awaiting_dns_name} =
             Tailscaled.Serve.reconcile(ctx.opts, [%{https: 443, to: "http://127.0.0.1:80"}], nil)

    assert {:ok, []} = Tailscaled.Serve.reconcile(ctx.opts, [], nil)

    identity = Path.join(ctx.directory, "identity")
    File.write!(Path.join(identity, "preserve-marker"), "identity storage must survive")
    daemon_pid = :sys.get_state(ctx.opts[:daemon]).pid
    generation = PropertyTable.get(ctx.table, ["monitor", "generation"])
    :ok = PropertyTable.subscribe(ctx.table, ["state"])
    GenServer.stop(daemon_pid, :shutdown)
    assert_receive {Tailscaled, ["state"], _, :unavailable, _}, 10_000

    eventually(
      fn -> assert PropertyTable.get(ctx.table, ["monitor", "generation"]) > generation end,
      500
    )

    eventually(fn ->
      assert PropertyTable.get(ctx.table, ["configuration", "state"]) == :ready
    end)

    assert File.read!(Path.join(identity, "preserve-marker")) == "identity storage must survive"

    # tailscaled does not persist prefs until enrollment creates a saved profile.
    # The library reports that reality rather than secretly reapplying configuration.
    assert {:ok, %{"Hostname" => "", "CorpDNS" => true}, _} =
             LocalAPI.request(ctx.opts, "GET", "prefs")

    assert configuration(ctx).hostname == ""
    assert configuration(ctx).accept_dns
    PropertyTable.unsubscribe(ctx.table, ["state"])
    stop_supervised(Tailscaled.Supervisor)
    start_supervised!({Fixture, ctx.opts})
    assert PropertyTable.get(ctx.table, ["state"]) != :online
    assert :ok = Monitor.ready(ctx.opts[:monitor], 10_000)

    eventually(fn ->
      assert PropertyTable.get(ctx.table, ["configuration", "state"]) == :ready
    end)

    assert configuration(ctx).hostname == ""
  end

  test "real daemon accepts running preference changes without enrollment or process restart",
       ctx do
    assert :ok =
             Controller.update_configuration(ctx.opts[:controller], %{hostname: "tsx-control"})

    daemon_pid = :sys.get_state(ctx.opts[:daemon]).pid

    assert {:ok, original, _} = LocalAPI.request(ctx.opts, "GET", "prefs")
    assert {:ok, original_serve, _} = LocalAPI.request(ctx.opts, "GET", "serve-config")

    for running <- [true, false, false, true] do
      assert :ok = Controller.set_running(ctx.opts[:controller], running)
      assert {:ok, actual, _} = LocalAPI.request(ctx.opts, "GET", "prefs")
      assert actual["WantRunning"] == running
      assert Map.delete(actual, "WantRunning") == Map.delete(original, "WantRunning")
      assert {:ok, ^original_serve, _} = LocalAPI.request(ctx.opts, "GET", "serve-config")
      assert :sys.get_state(ctx.opts[:daemon]).pid == daemon_pid
    end

    assert PropertyTable.get(ctx.table, ["state"]) != :online
    # Preference readback does not establish termination of active forwarding sessions.
  end

  @tag :network
  test "real browser enrollment emits a URL and preserves the generated machine identity on restart",
       ctx do
    assert :ok = Controller.login(ctx.opts[:controller], :interactive)

    login_url_received =
      case Monitor.await_login(ctx.opts[:monitor], 40_000) do
        {:ok, "https://" <> _} -> true
        _ -> false
      end

    assert login_url_received
    assert PropertyTable.get(ctx.table, ["auth", "state"]) == :authenticating
    path = Path.join(ctx.directory, "identity/tailscaled.state")
    fingerprint = machine_fingerprint(path)
    assert is_binary(fingerprint)
    generation = PropertyTable.get(ctx.table, ["monitor", "generation"])
    GenServer.stop(:sys.get_state(ctx.opts[:daemon]).pid, :shutdown)

    eventually(
      fn -> assert PropertyTable.get(ctx.table, ["monitor", "generation"]) > generation end,
      500
    )

    assert machine_fingerprint(path) == fingerprint
    # No browser completion, account enrollment, or end-to-end HTTPS assertion here.
  end

  @tag :network
  test "real invalid auth-key enrollment reaches the control server and emits a sanitized error",
       ctx do
    assert :ok =
             Controller.login(
               ctx.opts[:controller],
               {:auth_key, "tskey-auth-intentionally-invalid"}
             )

    eventually(
      fn -> assert PropertyTable.get(ctx.table, ["auth", "error"]) == :authentication_failed end,
      2_000
    )

    login_url_absent = is_nil(PropertyTable.get(ctx.table, ["auth", "url"]))
    assert login_url_absent
    assert PropertyTable.get(ctx.table, ["state"]) != :online
  end

  @tag :real_auth
  @tag timeout: 240_000
  test "auth-key enrollment becomes online and retains the enrolled identity after restart",
       ctx do
    # DNS, routes, and kernel networking stay untouched; no Serve or peer traffic.
    assert :ok =
             Controller.configure(ctx.opts[:controller], %{
               hostname: ctx.hostname,
               accept_dns: false,
               accept_routes: false
             })

    assert :ok = Tailnet.login(ctx.tailnet, ctx.opts[:controller])
    assert {:ok, identity} = Fixture.await_enrolled(ctx.opts, 60_000)
    assert {:ok, device} = Tailnet.device(ctx.tailnet, identity.node_id)

    assert device == %{
             "nodeId" => identity.node_id,
             "hostname" => ctx.hostname,
             "tags" => ["tag:ci"],
             "authorized" => true,
             "isEphemeral" => true
           }

    generation = PropertyTable.get(ctx.table, ["monitor", "generation"])
    daemon_pid = :sys.get_state(ctx.opts[:daemon]).pid
    assert :ok = GenServer.stop(daemon_pid, :shutdown)

    eventually(
      fn -> assert PropertyTable.get(ctx.table, ["monitor", "generation"]) > generation end,
      500
    )

    assert :sys.get_state(ctx.opts[:daemon]).pid != daemon_pid
    # No second login and a fresh monitor generation: not cached success.
    assert {:ok, restarted_identity} = Fixture.await_enrolled(ctx.opts, 60_000)
    assert restarted_identity == identity
    assert {:ok, ^device} = Tailnet.device(ctx.tailnet, restarted_identity.node_id)

    assert :ok = Controller.logout(ctx.opts[:controller])

    eventually(fn ->
      assert PropertyTable.get(ctx.table, ["auth", "state"]) == :needs_login
      assert PropertyTable.get(ctx.table, ["state"]) == :offline
      assert PropertyTable.get(ctx.table, ["ipv4"]) == nil
      assert PropertyTable.get(ctx.table, ["ipv6"]) == nil
    end)
  end

  defp configuration(ctx), do: PropertyTable.get(ctx.table, ["configuration", "value"])

  defp machine_fingerprint(path) do
    with {:ok, data} <- File.read(path),
         {:ok, %{"_machinekey" => key}} when is_binary(key) <- JSON.decode(data) do
      :crypto.hash(:sha256, key)
    else
      _ -> nil
    end
  end
end
