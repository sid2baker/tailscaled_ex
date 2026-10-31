defmodule Tailscaled.ControllerTest do
  use ExUnit.Case, async: true
  import Tailscaled.Test.Fixture, only: [eventually: 1]
  alias Tailscaled.{Controller, Monitor}
  alias Tailscaled.Test.{Fixture, UnixHTTP}

  setup do
    {:ok, daemon} = Fixture.daemon()

    opts =
      Fixture.options(__MODULE__, UnixHTTP.socket(daemon),
        auth_url_ttl: 80,
        config: %{hostname: "app-default", accept_dns: true}
      )

    start_supervised!({Fixture, opts})
    on_exit(fn -> File.rm_rf(opts[:data_dir]) end)
    assert :ok = Monitor.ready(opts[:monitor])

    eventually(fn ->
      assert PropertyTable.get(opts[:table], ["configuration", "state"]) == :ready
    end)

    %{daemon: daemon, opts: opts, controller: opts[:controller], table: opts[:table]}
  end

  test "startup reads daemon settings; only explicit reset applies application defaults", ctx do
    assert configuration(ctx).hostname == ""
    assert configuration(ctx).accept_dns
    assert writes(UnixHTTP.state(ctx.daemon)) == 0
    assert :ok = Controller.update_configuration(ctx.controller, %{accept_dns: false})
    refute configuration(ctx).accept_dns
    assert :ok = Controller.reset(ctx.controller)
    assert configuration(ctx).hostname == "app-default"
    assert configuration(ctx).accept_dns
    assert UnixHTTP.state(ctx.daemon).prefs["Unmanaged"] == "kept"
  end

  test "running commands write only WantRunning and verify it without changing authentication or Serve",
       ctx do
    UnixHTTP.update(ctx.daemon, fn state ->
      %{
        state
        | prefs:
            Map.merge(state.prefs, %{
              "Hostname" => "existing",
              "AdvertiseRoutes" => ["10.0.0.0/24"],
              "LoggedOut" => true,
              "Persist" => %{"PrivateNodeKey" => "fixture-key"}
            }),
          serve: %{"TCP" => %{"443" => %{"HTTPS" => true}}}
      }
    end)

    original = UnixHTTP.state(ctx.daemon)

    for running <- [false, true, true, false] do
      before = length(UnixHTTP.state(ctx.daemon).requests)
      assert :ok = Controller.set_running(ctx.controller, running)
      actual = UnixHTTP.state(ctx.daemon)
      assert actual.prefs == Map.put(original.prefs, "WantRunning", running)
      assert actual.serve == original.serve

      assert [
               %{method: "PATCH", path: "/localapi/v0/prefs", body: body},
               %{method: "GET", path: "/localapi/v0/prefs"}
             ] = Enum.drop(actual.requests, before)

      assert body == %{"WantRunning" => running, "WantRunningSet" => true}
    end

    assert PropertyTable.get(ctx.table, ["state"]) == :offline
    assert PropertyTable.get(ctx.table, ["auth", "state"]) == :needs_login
  end

  test "running commands report write and readback failures without replay", ctx do
    for {method, status, reason, applied} <- [
          {"PATCH", 403, {:http, 403}, false},
          {"PATCH", 200, :preferences_readback_mismatch, false},
          {"GET", 503, {:http, 503}, true}
        ] do
      UnixHTTP.update(ctx.daemon, fn state ->
        %{
          state
          | prefs: Map.put(state.prefs, "WantRunning", false),
            failures: %{{method, "/localapi/v0/prefs"} => status}
        }
      end)

      assert {:error, ^reason} = Controller.set_running(ctx.controller, true)
      assert UnixHTTP.state(ctx.daemon).prefs["WantRunning"] == applied
      count = writes(UnixHTTP.state(ctx.daemon))
      UnixHTTP.update(ctx.daemon, &%{&1 | failures: %{}})
      UnixHTTP.notify(ctx.daemon, %{"Prefs" => %{}})
      Process.sleep(150)
      assert writes(UnixHTTP.state(ctx.daemon)) == count
    end
  end

  test "tag preferences are writable before login, replace lists, and do not enroll", ctx do
    assert PropertyTable.get(ctx.table, ["auth", "state"]) == :needs_login

    assert :ok =
             Controller.configure(ctx.controller, %{advertise_tags: ["tag:b", "tag:a", "tag:a"]})

    assert configuration(ctx).advertise_tags == ["tag:a", "tag:b"]
    assert UnixHTTP.state(ctx.daemon).prefs["AdvertiseTags"] == ["tag:a", "tag:b"]
    assert :ok = Controller.update_configuration(ctx.controller, %{advertise_tags: ["tag:ci"]})
    assert configuration(ctx).advertise_tags == ["tag:ci"]
    assert :ok = Controller.update_configuration(ctx.controller, %{hostname: "tagged"})
    assert configuration(ctx).advertise_tags == ["tag:ci"]
    assert :ok = Controller.update_configuration(ctx.controller, %{advertise_tags: []})
    assert configuration(ctx).advertise_tags == []
    assert PropertyTable.get(ctx.table, ["self", "tags"]) == []
    refute Enum.any?(UnixHTTP.state(ctx.daemon).requests, &(&1.method == "POST"))
  end

  test "changing requested tags while running neither grants them nor reauthenticates", ctx do
    UnixHTTP.notify(ctx.daemon, %{
      "State" => 6,
      "SelfChange" => %{"ID" => 1, "Tags" => ["tag:old"]}
    })

    eventually(fn -> assert PropertyTable.get(ctx.table, ["self", "tags"]) == ["tag:old"] end)
    before = length(UnixHTTP.state(ctx.daemon).requests)
    assert :ok = Controller.update_configuration(ctx.controller, %{advertise_tags: ["tag:new"]})
    assert configuration(ctx).advertise_tags == ["tag:new"]
    assert PropertyTable.get(ctx.table, ["self", "tags"]) == ["tag:old"]
    assert PropertyTable.get(ctx.table, ["auth", "state"]) == :authenticated
    requests = Enum.drop(UnixHTTP.state(ctx.daemon).requests, before)
    refute Enum.any?(requests, &(&1.method == "POST"))

    UnixHTTP.notify(ctx.daemon, %{"SelfChange" => %{"ID" => 1, "Tags" => ["tag:new"]}})
    eventually(fn -> assert PropertyTable.get(ctx.table, ["self", "tags"]) == ["tag:new"] end)
  end

  test "tag readback mismatch is a configuration error, not a fabricated grant", ctx do
    UnixHTTP.update(ctx.daemon, &%{&1 | failures: %{{"PATCH", "/localapi/v0/prefs"} => 200}})

    assert {:error, :preferences_readback_mismatch} =
             Controller.update_configuration(ctx.controller, %{advertise_tags: ["tag:ci"]})

    assert PropertyTable.get(ctx.table, ["self", "tags"]) == []
  end

  test "running commands serialize with configuration updates", ctx do
    tasks = [
      Task.async(fn -> Controller.set_running(ctx.controller, true) end),
      Task.async(fn ->
        Controller.update_configuration(ctx.controller, %{hostname: "updated"})
      end),
      Task.async(fn -> Controller.update_configuration(ctx.controller, %{accept_dns: false}) end)
    ]

    assert Enum.all?(Task.await_many(tasks), &(&1 == :ok))

    assert %{"WantRunning" => true, "Hostname" => "updated", "CorpDNS" => false} =
             UnixHTTP.state(ctx.daemon).prefs
  end

  test "configuration replacement, removal, and idempotent readback", ctx do
    dns(ctx)
    config = %{hostname: "nerves", ssh: true, serve: [%{https: 443, to: "http://127.0.0.1"}]}
    assert :ok = Controller.update_configuration(ctx.controller, %{hostname: "nerves"})
    assert :ok = Controller.configure(ctx.controller, config)
    assert configuration(ctx).hostname == "nerves"
    assert configuration(ctx).serve == config.serve
    first = UnixHTTP.state(ctx.daemon)
    assert first.prefs["Unmanaged"] == "kept"
    assert first.serve["TCP"]["443"] == %{"HTTPS" => true}
    assert :ok = Controller.configure(ctx.controller, config)
    assert writes(UnixHTTP.state(ctx.daemon)) == writes(first)
    assert :ok = Controller.configure(ctx.controller, %{})
    assert UnixHTTP.state(ctx.daemon).serve["TCP"] == %{}
    assert UnixHTTP.state(ctx.daemon).prefs["RunSSH"] == false
    assert UnixHTTP.state(ctx.daemon).prefs["CorpDNS"] == false
    assert configuration(ctx).serve == []
  end

  test "concurrent calls serialize complete configuration replacements", ctx do
    tasks =
      for index <- 1..8,
          do:
            Task.async(fn ->
              Controller.configure(ctx.controller, %{hostname: "node-#{index}"})
            end)

    assert Enum.all?(Task.await_many(tasks), &(&1 == :ok))
    assert UnixHTTP.state(ctx.daemon).prefs["Hostname"] == configuration(ctx).hostname
  end

  test "updates preserve omitted fields and replace or remove lists", ctx do
    dns(ctx)

    original = %{
      hostname: "existing",
      accept_dns: true,
      accept_routes: true,
      ssh: true,
      advertise_routes: ["10.0.0.0/24"],
      advertise_tags: [],
      serve: [%{https: 443, to: "http://localhost:4000"}]
    }

    assert :ok = Controller.update_configuration(ctx.controller, %{hostname: "existing"})
    assert :ok = Controller.configure(ctx.controller, original)

    changes = %{
      advertise_routes: ["192.168.1.0/24"],
      serve: [%{https: 8443, to: "http://localhost:8080"}]
    }

    assert :ok = Controller.update_configuration(ctx.controller, changes)
    assert configuration(ctx) == Map.merge(original, changes)
    assert UnixHTTP.state(ctx.daemon).serve["TCP"] == %{"8443" => %{"HTTPS" => true}}
    assert UnixHTTP.state(ctx.daemon).prefs["Unmanaged"] == "kept"

    assert :ok = Controller.update_configuration(ctx.controller, %{ssh: false})
    assert configuration(ctx) == original |> Map.merge(changes) |> Map.put(:ssh, false)

    assert :ok =
             Controller.update_configuration(ctx.controller, %{serve: [], advertise_routes: []})

    assert configuration(ctx).serve == []
    assert configuration(ctx).advertise_routes == []
    assert configuration(ctx).hostname == "existing"
    assert configuration(ctx).accept_routes
    assert configuration(ctx).accept_dns
    refute configuration(ctx).ssh

    before = writes(UnixHTTP.state(ctx.daemon))
    assert :ok = Controller.update_configuration(ctx.controller, %{})
    assert writes(UnixHTTP.state(ctx.daemon)) == before
  end

  test "updates read fresh preferences and Serve rather than merging the cached snapshot", ctx do
    dns(ctx)
    assert :ok = Controller.configure(ctx.controller, %{hostname: "cached"})
    endpoints = [%{https: 8443, to: "http://localhost:8080"}]
    {:ok, serve} = Tailscaled.Serve.build(%{}, endpoints, "device.ts.net")

    UnixHTTP.update(ctx.daemon, fn state ->
      %{
        state
        | prefs: Map.merge(state.prefs, %{"Hostname" => "external.example", "CorpDNS" => true}),
          serve: serve,
          etag: 2
      }
    end)

    before = length(UnixHTTP.state(ctx.daemon).requests)
    assert :ok = Controller.update_configuration(ctx.controller, %{accept_dns: false})
    assert configuration(ctx).hostname == "external.example"
    assert configuration(ctx).serve == endpoints
    refute configuration(ctx).accept_dns

    requests = ctx.daemon |> UnixHTTP.state() |> Map.fetch!(:requests) |> Enum.drop(before)

    assert [
             %{method: "GET", path: "/localapi/v0/prefs"},
             %{method: "PATCH", path: "/localapi/v0/prefs", body: body},
             %{method: "GET", path: "/localapi/v0/prefs"},
             %{method: "GET", path: "/localapi/v0/serve-config"}
           ] = requests

    assert body == %{"CorpDNS" => false, "CorpDNSSet" => true}
  end

  test "concurrent updates preserve all disjoint changes", ctx do
    dns(ctx)

    expected = %{
      hostname: "concurrent",
      accept_dns: false,
      accept_routes: true,
      ssh: true,
      advertise_routes: ["10.0.0.0/24"],
      advertise_tags: ["tag:ci"],
      serve: [%{https: 443, to: "http://localhost:4000"}]
    }

    tasks =
      for {key, value} <- expected do
        Task.async(fn -> Controller.update_configuration(ctx.controller, %{key => value}) end)
      end

    assert Enum.all?(Task.await_many(tasks), &(&1 == :ok))
    assert configuration(ctx) == expected
  end

  test("failed preference reads clear the cache and never write or replay changes", ctx) do
    assert :ok = Controller.configure(ctx.controller, %{hostname: "retained", accept_dns: false})
    before = writes(UnixHTTP.state(ctx.daemon))
    UnixHTTP.update(ctx.daemon, &put_in(&1.failures[{"GET", "/localapi/v0/prefs"}], 503))

    assert {:error, {:http, 503}} =
             Controller.update_configuration(ctx.controller, %{hostname: "must-not-apply"})

    assert configuration(ctx) == nil
    assert PropertyTable.get(ctx.table, ["configuration", "error"]) == {:http, 503}
    assert writes(UnixHTTP.state(ctx.daemon)) == before
    UnixHTTP.update(ctx.daemon, &%{&1 | failures: %{}})
    eventually(fn -> assert %{hostname: "retained", accept_dns: false} = configuration(ctx) end)
    assert writes(UnixHTTP.state(ctx.daemon)) == before
  end

  test "failed update writes are not retried and leave existing settings intact", ctx do
    assert :ok = Controller.configure(ctx.controller, %{hostname: "retained", accept_dns: false})
    UnixHTTP.update(ctx.daemon, &put_in(&1.failures[{"PATCH", "/localapi/v0/prefs"}], 503))
    assert {:error, {:http, 503}} = Controller.update_configuration(ctx.controller, %{ssh: true})
    assert configuration(ctx).hostname == "retained"
    refute configuration(ctx).accept_dns
    refute configuration(ctx).ssh
    assert PropertyTable.get(ctx.table, ["configuration", "error"]) == {:http, 503}
    before = writes(UnixHTTP.state(ctx.daemon))
    UnixHTTP.update(ctx.daemon, &%{&1 | failures: %{}})
    UnixHTTP.notify(ctx.daemon, %{"Prefs" => %{}})

    eventually(fn ->
      assert PropertyTable.get(ctx.table, ["configuration", "state"]) == :ready
    end)

    assert writes(UnixHTTP.state(ctx.daemon)) == before
    refute configuration(ctx).ssh
  end

  test "an acknowledged but ignored preference write fails readback before touching Serve", ctx do
    dns(ctx)
    # Return a successful HTTP response without applying the PATCH.
    UnixHTTP.update(ctx.daemon, &put_in(&1.failures[{"PATCH", "/localapi/v0/prefs"}], 200))

    assert {:error, :preferences_readback_mismatch} =
             Controller.configure(ctx.controller, %{
               ssh: true,
               serve: [%{https: 443, to: "http://localhost:4000"}]
             })

    refute configuration(ctx).ssh
    assert configuration(ctx).serve == []
    assert UnixHTTP.state(ctx.daemon).serve == nil

    assert PropertyTable.get(ctx.table, ["configuration", "error"]) ==
             :preferences_readback_mismatch
  end

  test "failed mutations return errors and are never retried, even after a notification", ctx do
    for status <- [503, 400] do
      UnixHTTP.update(ctx.daemon, &put_in(&1.failures[{"PATCH", "/localapi/v0/prefs"}], status))

      assert {:error, {:http, ^status}} =
               Controller.configure(ctx.controller, %{hostname: "rejected"})

      assert PropertyTable.get(ctx.table, ["configuration", "error"]) == {:http, status}
      assert configuration(ctx).hostname == ""
      count = writes(UnixHTTP.state(ctx.daemon))
      UnixHTTP.update(ctx.daemon, &%{&1 | failures: %{}})
      UnixHTTP.notify(ctx.daemon, %{"Prefs" => %{}})
      Process.sleep(150)
      assert writes(UnixHTTP.state(ctx.daemon)) == count
      assert UnixHTTP.state(ctx.daemon).prefs["Hostname"] == ""
    end

    assert :ok = Controller.configure(ctx.controller, %{hostname: "caller-retried"})
    assert configuration(ctx).hostname == "caller-retried"
  end

  test "external preference changes and reconnects refresh the cache without writes", ctx do
    UnixHTTP.update(ctx.daemon, &put_in(&1.prefs["Hostname"], "external"))
    UnixHTTP.notify(ctx.daemon, %{"Prefs" => %{}})
    eventually(fn -> assert %{hostname: "external"} = configuration(ctx) end)
    UnixHTTP.disconnect(ctx.daemon)
    eventually(fn -> assert PropertyTable.get(ctx.table, ["monitor", "generation"]) >= 2 end)
    eventually(fn -> assert %{hostname: "external"} = configuration(ctx) end)
    assert writes(UnixHTTP.state(ctx.daemon)) == 0
  end

  test "failed background reads clear the cache and retry only reads", ctx do
    UnixHTTP.update(ctx.daemon, &put_in(&1.failures[{"GET", "/localapi/v0/prefs"}], 503))
    UnixHTTP.notify(ctx.daemon, %{"Prefs" => %{}})
    eventually(fn -> assert configuration(ctx) == nil end)
    assert PropertyTable.get(ctx.table, ["configuration", "error"]) == {:http, 503}
    UnixHTTP.update(ctx.daemon, &%{&1 | failures: %{}})
    eventually(fn -> assert is_map(configuration(ctx)) end)
    assert writes(UnixHTTP.state(ctx.daemon)) == 0
  end

  test "failed configure readback recovers the cache without replaying the mutation", ctx do
    UnixHTTP.update(ctx.daemon, &put_in(&1.failures[{"GET", "/localapi/v0/serve-config"}], 503))

    assert {:error, {:http, 503}} =
             Controller.configure(ctx.controller, %{hostname: "partially-applied"})

    assert configuration(ctx).hostname == "partially-applied"
    refute Map.has_key?(configuration(ctx), :serve)
    assert UnixHTTP.state(ctx.daemon).prefs["Hostname"] == "partially-applied"
    count = writes(UnixHTTP.state(ctx.daemon))
    UnixHTTP.update(ctx.daemon, &%{&1 | failures: %{}})
    eventually(fn -> assert Map.has_key?(configuration(ctx), :serve) end)
    assert configuration(ctx).hostname == "partially-applied"
    assert writes(UnixHTTP.state(ctx.daemon)) == count
  end

  test "hostname changes and nonempty Serve must be separate, before any writes", ctx do
    dns(ctx)
    endpoints = [%{https: 443, to: "http://localhost:4000"}]

    for command <- [&Controller.configure/2, &Controller.update_configuration/2] do
      assert {:error, :hostname_change_requires_separate_serve} =
               command.(ctx.controller, %{hostname: "renamed", ssh: true, serve: endpoints})
    end

    assert writes(UnixHTTP.state(ctx.daemon)) == 0
    assert configuration(ctx).hostname == ""
    refute configuration(ctx).ssh

    assert :ok = Controller.update_configuration(ctx.controller, %{hostname: "renamed"})

    UnixHTTP.notify(ctx.daemon, %{
      "SelfChange" => %{"ID" => 1, "Name" => "renamed.ts.net."}
    })

    eventually(fn -> assert PropertyTable.get(ctx.table, ["dns_name"]) == "renamed.ts.net" end)

    # Including an unchanged hostname is safe, as is renaming while removing Serve.
    assert :ok = Controller.configure(ctx.controller, %{hostname: "renamed", serve: endpoints})
    assert Map.keys(UnixHTTP.state(ctx.daemon).serve["Web"]) == ["renamed.ts.net:443"]
    assert :ok = Controller.update_configuration(ctx.controller, %{hostname: "again", serve: []})
    assert configuration(ctx).serve == []
  end

  test "Serve without DNS fails immediately and is not applied after login", ctx do
    config = %{serve: [%{https: 443, to: "http://localhost:80"}]}
    assert {:error, :awaiting_dns_name} = Controller.configure(ctx.controller, config)
    assert writes(UnixHTTP.state(ctx.daemon)) == 0
    dns(ctx)
    UnixHTTP.notify(ctx.daemon, %{"State" => 6})
    Process.sleep(150)
    assert UnixHTTP.state(ctx.daemon).serve == nil
    assert :ok = Controller.configure(ctx.controller, config)
    assert UnixHTTP.state(ctx.daemon).serve["Web"]["device.ts.net:443"]
  end

  test "partial changes are observed and Serve CAS conflicts require an explicit retry", ctx do
    dns(ctx)
    UnixHTTP.update(ctx.daemon, &put_in(&1.failures[{"POST", "/localapi/v0/serve-config"}], 412))
    config = %{ssh: true, serve: [%{https: 443, to: "http://localhost"}]}
    assert {:error, {:http, 412}} = Controller.configure(ctx.controller, config)
    assert configuration(ctx).ssh
    assert configuration(ctx).serve == []
    count = writes(UnixHTTP.state(ctx.daemon))
    UnixHTTP.update(ctx.daemon, &%{&1 | failures: %{}, etag: 9})
    Process.sleep(150)
    assert writes(UnixHTTP.state(ctx.daemon)) == count
    assert :ok = Controller.configure(ctx.controller, config)
    assert configuration(ctx).serve == config.serve

    assert Enum.any?(UnixHTTP.state(ctx.daemon).requests, fn request ->
             request.method == "POST" and request.path == "/localapi/v0/serve-config" and
               request.headers["if-match"] == "9"
           end)
  end

  test("unsupported Serve stays untouched and does not block preference updates", ctx) do
    unsupported = %{"TCP" => %{"80" => %{"HTTP" => true}}}
    UnixHTTP.update(ctx.daemon, &%{&1 | serve: unsupported})
    UnixHTTP.notify(ctx.daemon, %{"Prefs" => %{}})

    eventually(fn ->
      assert PropertyTable.get(ctx.table, ["configuration", "error"]) ==
               :unsupported_serve_configuration
    end)

    assert configuration(ctx).hostname == ""
    refute Map.has_key?(configuration(ctx), :serve)
    assert :ok = Controller.update_configuration(ctx.controller, %{hostname: "independent"})
    assert configuration(ctx).hostname == "independent"
    refute Map.has_key?(configuration(ctx), :serve)
    assert UnixHTTP.state(ctx.daemon).serve == unsupported
    assert writes(UnixHTTP.state(ctx.daemon)) == 1

    assert PropertyTable.get(ctx.table, ["configuration", "error"]) ==
             :unsupported_serve_configuration

    assert :ok = Controller.update_configuration(ctx.controller, %{serve: []})
    assert configuration(ctx).serve == []
    assert configuration(ctx).hostname == "independent"
  end

  test "interactive login watches first and never reapplies application defaults", ctx do
    UnixHTTP.update(ctx.daemon, &put_in(&1.prefs["Hostname"], "existing"))
    assert :ok = Controller.login(ctx.controller, :interactive)
    assert UnixHTTP.state(ctx.daemon).prefs["Hostname"] == "existing"
    assert UnixHTTP.state(ctx.daemon).prefs["CorpDNS"] == true
    paths = Enum.map(UnixHTTP.state(ctx.daemon).requests, & &1.path)
    assert hd(paths) =~ "watch-ipn-bus"
    assert "/localapi/v0/start" in paths
    assert "/localapi/v0/login-interactive" in paths
    refute PropertyTable.get(ctx.table, ["state"]) == :online
    UnixHTTP.notify(ctx.daemon, %{"BrowseToURL" => "https://login.tailscale.com/a/test"})
    eventually(fn -> assert PropertyTable.get(ctx.table, ["auth", "url"]) != nil end)
    eventually(fn -> assert PropertyTable.get(ctx.table, ["auth", "error"]) == :url_expired end)
    assert :ok = Controller.login(ctx.controller, :interactive)

    UnixHTTP.notify(ctx.daemon, %{
      "BrowseToURL" => "https://login.tailscale.com/a/new",
      "State" => 6
    })

    eventually(fn -> assert PropertyTable.get(ctx.table, ["state"]) == :online end)
    before = writes(UnixHTTP.state(ctx.daemon))
    assert :ok = Controller.login(ctx.controller, :interactive)
    assert writes(UnixHTTP.state(ctx.daemon)) == before
  end

  test "auth-key is sent via Start and activates a new profile without being retained", ctx do
    assert :ok = Controller.login(ctx.controller, {:auth_key, "tskey-not-a-real-key"})
    assert UnixHTTP.state(ctx.daemon).prefs["CorpDNS"] == true
    requests = UnixHTTP.state(ctx.daemon).requests

    assert Enum.any?(
             requests,
             &(&1.path == "/localapi/v0/start" and &1.body == %{"AuthKey" => :redacted})
           )

    assert Enum.any?(requests, &(&1.path == "/localapi/v0/login-interactive"))
    refute inspect(:sys.get_state(ctx.controller)) =~ "tskey-not-a-real-key"
    refute inspect(configuration(ctx)) =~ "tskey"
    assert :ok = Controller.logout(ctx.controller)
    assert PropertyTable.get(ctx.table, ["auth", "url"]) == nil
  end

  test "key enrollment with an existing node key does not trigger interactive login", ctx do
    UnixHTTP.update(ctx.daemon, &put_in(&1.status["HaveNodeKey"], true))
    assert :ok = Controller.login(ctx.controller, {:auth_key, "tskey-test-existing"})

    refute Enum.any?(
             UnixHTTP.state(ctx.daemon).requests,
             &(&1.path == "/localapi/v0/login-interactive")
           )

    assert UnixHTTP.state(ctx.daemon).prefs["LoggedOut"] == false
  end

  test "a successful replacement reuses verified responses without another refresh", ctx do
    dns(ctx)
    :sys.get_state(ctx.controller)
    before = length(UnixHTTP.state(ctx.daemon).requests)
    config = %{ssh: true, serve: [%{https: 443, to: "http://localhost:4000"}]}
    assert :ok = Controller.configure(ctx.controller, config)
    requests = Enum.drop(UnixHTTP.state(ctx.daemon).requests, before)

    assert Enum.map(requests, &{&1.method, &1.path}) == [
             {"GET", "/localapi/v0/prefs"},
             {"PATCH", "/localapi/v0/prefs"},
             {"GET", "/localapi/v0/prefs"},
             {"GET", "/localapi/v0/serve-config"},
             {"POST", "/localapi/v0/serve-config"},
             {"GET", "/localapi/v0/serve-config"}
           ]

    assert configuration(ctx).ssh == config.ssh
    assert configuration(ctx).serve == config.serve
  end

  test "unreadable omitted Serve does not fail a verified preference update", ctx do
    UnixHTTP.update(ctx.daemon, &put_in(&1.failures[{"GET", "/localapi/v0/serve-config"}], 503))
    assert :ok = Controller.update_configuration(ctx.controller, %{hostname: "independent"})
    assert configuration(ctx).hostname == "independent"
    refute Map.has_key?(configuration(ctx), :serve)
    assert PropertyTable.get(ctx.table, ["configuration", "error"]) == {:http, 503}
    count = writes(UnixHTTP.state(ctx.daemon))
    UnixHTTP.update(ctx.daemon, &%{&1 | failures: %{}})
    eventually(fn -> assert configuration(ctx)[:serve] == [] end)
    assert writes(UnixHTTP.state(ctx.daemon)) == count
  end

  test "foreground Serve conflicts are isolated from preference-only updates", ctx do
    serve = %{"Foreground" => %{"session" => %{}}}
    UnixHTTP.update(ctx.daemon, &%{&1 | serve: serve})
    assert :ok = Controller.update_configuration(ctx.controller, %{hostname: "independent"})
    assert UnixHTTP.state(ctx.daemon).serve == serve

    assert {:error, :serve_foreground_conflict} =
             Controller.update_configuration(ctx.controller, %{serve: []})

    assert UnixHTTP.state(ctx.daemon).serve == serve
    assert configuration(ctx).hostname == "independent"
    refute Map.has_key?(configuration(ctx), :serve)
  end

  test "successful notification refresh cancels backoff and ignores stale retry tokens", ctx do
    :sys.replace_state(ctx.controller, &%{&1 | delay: 5_000})
    UnixHTTP.update(ctx.daemon, &put_in(&1.failures[{"GET", "/localapi/v0/prefs"}], 503))
    UnixHTTP.notify(ctx.daemon, %{"Prefs" => %{}})
    eventually(fn -> assert configuration(ctx) == nil end)
    {timer, token} = :sys.get_state(ctx.controller).timer
    UnixHTTP.update(ctx.daemon, &%{&1 | failures: %{}})
    UnixHTTP.notify(ctx.daemon, %{"Prefs" => %{}})
    eventually(fn -> assert is_map(configuration(ctx)) end)
    assert :sys.get_state(ctx.controller).timer == nil
    assert Process.read_timer(timer) == false
    before = UnixHTTP.state(ctx.daemon).requests
    send(ctx.controller, {:refresh, token})
    :sys.get_state(ctx.controller)
    assert UnixHTTP.state(ctx.daemon).requests == before
  end

  defp dns(ctx) do
    UnixHTTP.notify(ctx.daemon, %{"SelfChange" => %{"ID" => 1, "Name" => "device.ts.net."}})
    eventually(fn -> assert PropertyTable.get(ctx.table, ["dns_name"]) == "device.ts.net" end)
  end

  defp configuration(ctx), do: PropertyTable.get(ctx.table, ["configuration", "value"])
  defp writes(state), do: Enum.count(state.requests, &(&1.method in ["POST", "PATCH"]))
end
