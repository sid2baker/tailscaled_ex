defmodule Tailscaled.MonitorTest do
  use ExUnit.Case, async: true
  import Tailscaled.Test.Fixture, only: [eventually: 1]
  import ExUnit.CaptureLog
  alias Tailscaled.{Monitor, Snapshot}
  alias Tailscaled.Test.{Fixture, UnixHTTP}

  setup do
    {:ok, daemon} = Fixture.daemon()
    opts = Fixture.options(__MODULE__, UnixHTTP.socket(daemon))
    start_supervised!({Fixture, opts})
    on_exit(fn -> File.rm_rf(opts[:data_dir]) end)
    assert :ok = Monitor.ready(opts[:monitor])
    %{daemon: daemon, opts: opts, table: opts[:table], monitor: opts[:monitor]}
  end

  test "initial snapshot, incremental peer replacements/removals and duplicate event suppression",
       ctx do
    assert :offline == PropertyTable.get(ctx.table, ["state"])
    :ok = PropertyTable.subscribe(ctx.table, ["peers", :_, "online"])

    peer = %{
      "ID" => 42,
      "StableID" => "n42",
      "Online" => true,
      "Addresses" => ["100.1.2.3/32"],
      "Name" => "peer.ts.net."
    }

    UnixHTTP.notify(ctx.daemon, %{"PeersChanged" => [peer]})

    assert_receive {Tailscaled, ["peers", "n42", "online"], nil, true,
                    %{new_timestamp: timestamp}}

    assert is_integer(timestamp)
    assert PropertyTable.get(ctx.table, ["peers", "n42", "ipv4"]) == {100, 1, 2, 3}
    UnixHTTP.notify(ctx.daemon, %{"PeersChanged" => [peer]})
    refute_receive {Tailscaled, ["peers", "n42", "online"], _, _, _}, 50

    UnixHTTP.notify(ctx.daemon, %{
      "PeersChanged" => [%{"ID" => 42, "StableID" => "n42", "Online" => false}]
    })

    assert_receive {Tailscaled, ["peers", "n42", "online"], true, false, _}
    eventually(fn -> assert PropertyTable.get(ctx.table, ["peers", "n42", "ipv4"]) == nil end)
    UnixHTTP.notify(ctx.daemon, %{"PeersRemoved" => [42]})
    assert_receive {Tailscaled, ["peers", "n42", "online"], false, nil, _}
  end

  test "disconnect marks unavailable, clears obsolete data and rebuilds an empty peer snapshot",
       ctx do
    UnixHTTP.notify(ctx.daemon, %{
      "State" => 6,
      "PeersChanged" => [%{"ID" => 1, "StableID" => "n1", "Online" => true}]
    })

    eventually(fn -> assert PropertyTable.get(ctx.table, ["state"]) == :online end)
    PropertyTable.subscribe(ctx.table, ["state"])
    UnixHTTP.disconnect(ctx.daemon)
    assert_receive {Tailscaled, ["state"], _, :unavailable, _}
    eventually(fn -> assert PropertyTable.get(ctx.table, ["monitor", "generation"]) >= 2 end)
    assert PropertyTable.match(ctx.table, ["peers"]) == []
    assert PropertyTable.get(ctx.table, ["state"]) == :offline
  end

  test "granted tags come from status and full node notifications, with empty defaults" do
    for tag_fields <- [%{}, %{"Tags" => nil}, %{"Tags" => ["tag:ci"]}] do
      expected = tag_fields["Tags"] || []

      initial =
        Snapshot.update(%Snapshot{}, %{
          "InitialStatus" => %{
            "BackendState" => "Running",
            "Self" => Map.merge(%{"ID" => "self"}, tag_fields),
            "Peer" => %{"key" => Map.merge(%{"NodeID" => 42, "ID" => "n42"}, tag_fields)}
          }
        })

      assert Snapshot.properties(initial)[["self", "tags"]] == expected
      assert Snapshot.properties(initial)[["peers", "n42", "tags"]] == expected

      updated =
        Snapshot.update(initial, %{
          "SelfChange" => Map.merge(%{"ID" => 1, "StableID" => "self"}, tag_fields),
          "PeersChanged" => [Map.merge(%{"ID" => 42, "StableID" => "n42"}, tag_fields)]
        })

      assert Snapshot.properties(updated)[["self", "tags"]] == expected
      assert Snapshot.properties(updated)[["peers", "n42", "tags"]] == expected
    end
  end

  test "tag notifications replace granted tags and preserve daemon health details", ctx do
    :ok = PropertyTable.subscribe(ctx.table, ["self", "tags"])
    UnixHTTP.notify(ctx.daemon, %{"SelfChange" => %{"ID" => 1, "Tags" => ["tag:ci"]}})
    assert_receive {Tailscaled, ["self", "tags"], [], ["tag:ci"], _}
    UnixHTTP.notify(ctx.daemon, %{"SelfChange" => %{"ID" => 1, "Tags" => nil}})
    assert_receive {Tailscaled, ["self", "tags"], ["tag:ci"], [], _}

    # Health text is daemon-provided, not a library-generated tag reason catalogue.
    warning = "Tag request denied by policy"

    UnixHTTP.notify(ctx.daemon, %{
      "Health" => %{"Warnings" => %{"fixture" => %{"Text" => warning}}}
    })

    eventually(fn -> assert PropertyTable.get(ctx.table, ["health"]) == [warning] end)
    assert PropertyTable.get(ctx.table, ["self", "tags"]) == []
  end

  test "quiet streams stay connected without periodic status or configuration requests", ctx do
    eventually(fn ->
      assert PropertyTable.get(ctx.table, ["configuration", "state"]) == :ready
    end)

    requests = UnixHTTP.state(ctx.daemon).requests
    Process.sleep(1_200)
    assert PropertyTable.get(ctx.table, ["monitor", "generation"]) == 1
    assert PropertyTable.get(ctx.table, ["monitor", "connected"]) == true
    assert UnixHTTP.state(ctx.daemon).requests == requests
    refute Enum.any?(requests, &String.contains?(&1.path, "/status"))
  end

  test "interrupted authentication removes a stale URL and accepts a new attempt", ctx do
    url = "https://login.tailscale.com/a/interrupted"
    UnixHTTP.notify(ctx.daemon, %{"BrowseToURL" => url})
    eventually(fn -> assert PropertyTable.get(ctx.table, ["auth", "url"]) == url end)
    PropertyTable.subscribe(ctx.table, ["auth", "url"])
    UnixHTTP.disconnect(ctx.daemon)
    assert_receive {Tailscaled, ["auth", "url"], ^url, nil, _}
    eventually(fn -> assert PropertyTable.get(ctx.table, ["monitor", "generation"]) >= 2 end)
    assert PropertyTable.get(ctx.table, ["auth", "url"]) == nil
    assert :ok = Tailscaled.Controller.login(ctx.opts[:controller], :interactive)
    UnixHTTP.notify(ctx.daemon, %{"BrowseToURL" => url <> "-new"})
    assert_receive {Tailscaled, ["auth", "url"], nil, new_url, _}
    assert new_url == url <> "-new"
  end

  test "a replaced stream cannot change state or trigger another reconnect", ctx do
    {:ready, %{worker: old_worker}} = :sys.get_state(ctx.monitor)
    UnixHTTP.disconnect(ctx.daemon)
    eventually(fn -> assert PropertyTable.get(ctx.table, ["monitor", "generation"]) == 2 end)
    {:ready, %{worker: worker}} = :sys.get_state(ctx.monitor)
    refute worker == old_worker

    assert {:error, :stale_stream} =
             :gen_statem.call(ctx.monitor, {:notification, old_worker, %{"State" => 6}})

    send(ctx.monitor, {:watch_ended, old_worker, {:error, :disconnected}})
    send(ctx.monitor, {:EXIT, old_worker, :normal})
    assert :ok = Monitor.ready(ctx.monitor)
    assert {:ready, %{worker: ^worker, generation: 2}} = :sys.get_state(ctx.monitor)
    assert PropertyTable.get(ctx.table, ["state"]) == :offline
  end

  test "authentication URL notifications, completion and error redaction", ctx do
    UnixHTTP.notify(ctx.daemon, %{"BrowseToURL" => "https://login.tailscale.com/a/example"})

    eventually(fn ->
      assert PropertyTable.get(ctx.table, ["auth", "state"]) == :authenticating
    end)

    UnixHTTP.notify(ctx.daemon, %{"State" => 6})
    eventually(fn -> assert PropertyTable.get(ctx.table, ["auth", "state"]) == :authenticated end)
    assert PropertyTable.get(ctx.table, ["auth", "url"]) == nil
    UnixHTTP.notify(ctx.daemon, %{"State" => 2, "ErrMessage" => "secret backend error"})

    eventually(fn ->
      assert PropertyTable.get(ctx.table, ["auth", "error"]) == :authentication_failed
    end)
  end

  test "OTP status and crash reports redact auth state and raw notifications", ctx do
    url = "https://login.tailscale.com/a/crash-secret"
    secret = "tskey-reflected-in-error"
    assert :ok = Monitor.auth(ctx.monitor, {:url, url})
    refute inspect(:sys.get_status(ctx.monitor), limit: :infinity) =~ url
    :ok = :sys.log(ctx.monitor, true)
    assert :ok = Monitor.auth(ctx.monitor, {:url, url})
    pid = Process.whereis(ctx.monitor)
    ref = Process.monitor(pid)

    log =
      capture_log(fn ->
        UnixHTTP.notify(ctx.daemon, %{
          "Health" => %{"Warnings" => %{"malformed" => 1}},
          "ErrMessage" => secret
        })

        assert_receive {:DOWN, ^ref, :process, _, _}, 1_000
      end)

    assert log =~ "terminating"
    refute log =~ url
    refute log =~ secret
    refute log =~ "format_status"
    eventually(fn -> assert Process.whereis(ctx.monitor) not in [nil, pid] end)
    assert :ok = Monitor.ready(ctx.monitor)
  end

  test "profile resets clear identity and peers, while stopping retains them" do
    initial =
      Snapshot.update(%Snapshot{}, %{
        "InitialStatus" => %{
          "BackendState" => "Running",
          "Self" => %{"ID" => "self", "DNSName" => "old.ts.net.", "TailscaleIPs" => ["100.1.2.3"]},
          "Peer" => %{"pubkey" => %{"NodeID" => 10, "ID" => "n10", "Online" => true}}
        }
      })

    stopped = Snapshot.update(initial, %{"State" => 4})
    assert stopped.self == initial.self
    assert stopped.peers == initial.peers

    for reset <- [0, "NoState"] do
      snapshot =
        initial |> Snapshot.update(%{"State" => reset}) |> Snapshot.update(%{"State" => 2})

      assert snapshot.backend == :needs_login
      assert snapshot.self == %{}
      assert snapshot.peers == %{}
      properties = Snapshot.properties(snapshot)
      refute Map.has_key?(properties, ["ipv4"])
      refute Map.has_key?(properties, ["dns_name"])
      refute Map.has_key?(properties, ["peers", "n10", "online"])
    end
  end

  test "profile resets clear authentication URLs, errors and attempts" do
    for reset <- [0, "NoState"],
        snapshot <- [
          %Snapshot{url: "https://login.tailscale.com/a/old", auth_attempt: true},
          %Snapshot{error: :authentication_failed}
        ] do
      snapshot =
        snapshot |> Snapshot.update(%{"State" => reset}) |> Snapshot.update(%{"State" => 2})

      assert snapshot.url == nil
      assert snapshot.error == nil
      refute snapshot.auth_attempt
      assert Snapshot.properties(snapshot)[["auth", "state"]] == :needs_login
    end
  end

  test "profile resets resolve pending login waiters", ctx do
    assert :ok = Monitor.auth(ctx.monitor, :starting)
    login = Task.async(fn -> Monitor.await_login(ctx.monitor, 5_000) end)
    eventually(fn -> assert map_size(elem(:sys.get_state(ctx.monitor), 1).login_waiters) == 1 end)
    UnixHTTP.notify(ctx.daemon, %{"State" => 0})
    assert Task.await(login) == {:error, :logged_out}
    assert elem(:sys.get_state(ctx.monitor), 1).login_waiters == %{}
  end

  test "profile resets remove the published URL and cancel its expiry", ctx do
    :sys.replace_state(ctx.monitor, fn {phase, data} ->
      {phase, %{data | opts: Keyword.put(data.opts, :auth_url_ttl, 200)}}
    end)

    url = "https://login.tailscale.com/a/old-profile"
    assert :ok = Monitor.auth(ctx.monitor, :starting)
    assert :ok = Monitor.auth(ctx.monitor, {:url, url})
    PropertyTable.subscribe(ctx.table, ["auth", "url"])
    UnixHTTP.notify(ctx.daemon, %{"State" => 0})
    assert_receive {Tailscaled, ["auth", "url"], ^url, nil, _}
    UnixHTTP.notify(ctx.daemon, %{"State" => 2})
    eventually(fn -> assert PropertyTable.get(ctx.table, ["auth", "state"]) == :needs_login end)
    Process.sleep(250)
    assert PropertyTable.get(ctx.table, ["auth", "error"]) == nil
    assert PropertyTable.get(ctx.table, ["auth", "state"]) == :needs_login
  end

  test "login waiters have independent deadlines and are cleared on completion", ctx do
    assert :ok = Monitor.auth(ctx.monitor, :starting)
    short = Task.async(fn -> Monitor.await_login(ctx.monitor, 100) end)
    long = Task.async(fn -> Monitor.await_login(ctx.monitor, 5_000) end)
    eventually(fn -> assert map_size(elem(:sys.get_state(ctx.monitor), 1).login_waiters) == 2 end)
    assert :ok = Monitor.ready(ctx.monitor)
    assert Task.await(short) == {:error, :timeout}
    assert map_size(elem(:sys.get_state(ctx.monitor), 1).login_waiters) == 1
    url = "https://login.tailscale.com/a/shared"
    UnixHTTP.notify(ctx.daemon, %{"BrowseToURL" => url})
    assert Task.await(long) == {:ok, url}
    assert {:ready, %{login_waiters: %{}}} = :sys.get_state(ctx.monitor)
    assert elem(:sys.get_state(ctx.monitor), 1).login_waiters == %{}
  end

  test "starting from stopped waits for a URL or a running notification", ctx do
    UnixHTTP.notify(ctx.daemon, %{"State" => 4})
    eventually(fn -> assert PropertyTable.get(ctx.table, ["backend_state"]) == :stopped end)
    assert :ok = Monitor.auth(ctx.monitor, :starting)
    login = Task.async(fn -> Monitor.await_login(ctx.monitor, 5_000) end)
    eventually(fn -> assert map_size(elem(:sys.get_state(ctx.monitor), 1).login_waiters) == 1 end)
    UnixHTTP.notify(ctx.daemon, %{"State" => 6})
    assert Task.await(login) == :ok
  end

  test "a stopped snapshot preserves a new login across unrelated notifications" do
    snapshot = %Snapshot{backend: :stopped, auth_attempt: true}
    snapshot = Snapshot.update(snapshot, %{"Prefs" => %{}})
    assert snapshot.auth_attempt

    url = "https://login.tailscale.com/a/resuming"
    snapshot = Snapshot.update(snapshot, %{"BrowseToURL" => url})
    assert snapshot.url == url
    assert snapshot.auth_attempt

    failed = Snapshot.update(snapshot, %{"ErrMessage" => "private error"})
    assert failed.error == :authentication_failed
    assert failed.url == nil
    assert Snapshot.update(failed, %{"Prefs" => %{}}).error == :authentication_failed

    stopped = Snapshot.update(snapshot, %{"State" => 4})
    assert stopped.url == nil
    refute stopped.auth_attempt
  end

  test "snapshot tolerates missing fields and removes missing values on replacement" do
    snapshot =
      Snapshot.update(%Snapshot{}, %{
        "InitialStatus" => %{
          "Peer" => %{"pubkey" => %{"NodeID" => 10, "ID" => "n10", "Online" => true}}
        }
      })

    assert Snapshot.properties(snapshot)[["peers", "n10", "online"]]
    snapshot = Snapshot.update(snapshot, %{"PeersRemoved" => [10], "State" => 999})
    assert snapshot.peers == %{}
    assert snapshot.backend == :unknown
    assert Snapshot.properties(snapshot)[["state"]] == :unavailable
    assert Snapshot.update(snapshot, %{}) == snapshot
  end
end
