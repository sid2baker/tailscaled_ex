defmodule Tailscaled.Test.Fixture do
  @moduledoc false
  alias Tailscaled.{Controller, LocalAPI}
  alias Tailscaled.Test.UnixHTTP

  # Exercise the application's actual tree with isolated OTP start arguments.
  def child_spec(opts) do
    %{
      id: Tailscaled.Supervisor,
      start: {Tailscaled.Application, :start, [:normal, opts]},
      type: :supervisor
    }
  end

  def daemon(opts \\ []) do
    state = %{
      prefs: %{
        "Hostname" => "",
        "CorpDNS" => true,
        "RouteAll" => false,
        "RunSSH" => false,
        "AdvertiseRoutes" => nil,
        "WantRunning" => false,
        "Unmanaged" => "kept"
      },
      serve: nil,
      etag: 1,
      requests: [],
      failures: %{},
      status: %{"BackendState" => "NeedsLogin", "Self" => nil, "Peer" => %{}, "Health" => []}
    }

    UnixHTTP.start_link(Keyword.merge([handler: &handle/2, state: state], opts))
  end

  def initial(state), do: %{"Version" => "1.102.3", "InitialStatus" => state.status}

  defp handle(request, state) do
    # The fixture records only whether a key was sent, never its plaintext value.
    body = if request.body == "", do: %{}, else: JSON.decode!(request.body)

    recorded = %{
      request
      | body: if(Map.has_key?(body, "AuthKey"), do: %{"AuthKey" => :redacted}, else: body)
    }

    state = %{state | requests: state.requests ++ [recorded]}
    failure = state.failures[{request.method, request.path}]

    if failure,
      do: {{:json, failure, %{"error" => "rejected"}, []}, state},
      else: route(request, body, state)
  end

  defp route(%{path: "/localapi/v0/watch-ipn-bus?" <> _}, _body, state),
    do: {{:watch, initial(state)}, state}

  defp route(%{method: "GET", path: "/localapi/v0/prefs"}, _body, state),
    do: {ok(state.prefs), state}

  defp route(%{method: "PATCH", path: "/localapi/v0/prefs"}, body, state) do
    prefs =
      Enum.reduce(body, state.prefs, fn {key, value}, prefs ->
        if body[key <> "Set"] == true, do: Map.put(prefs, key, value), else: prefs
      end)

    {ok(prefs), %{state | prefs: prefs}}
  end

  defp route(%{method: "GET", path: "/localapi/v0/serve-config"}, _body, state),
    do: {{:json, 200, state.serve, [{"etag", to_string(state.etag)}]}, state}

  defp route(%{method: "POST", path: "/localapi/v0/serve-config", headers: headers}, body, state) do
    if headers["if-match"] == to_string(state.etag),
      do: {ok(:empty), %{state | serve: body, etag: state.etag + 1}},
      else: {{:json, 412, :empty, []}, state}
  end

  defp route(%{path: "/localapi/v0/status?peers=false"}, _body, state),
    do: {ok(state.status), state}

  defp route(%{path: path}, _body, state)
       when path in [
              "/localapi/v0/start",
              "/localapi/v0/login-interactive",
              "/localapi/v0/logout"
            ],
       do: {{:json, 204, :empty, []}, state}

  defp route(_request, _body, state), do: {{:json, 404, :empty, []}, state}

  defp ok(body), do: {:json, 200, body, []}

  def options(module, socket, extra \\ []) do
    names =
      for key <- [:supervisor, :table, :monitor, :controller, :daemon],
          do: {key, Module.concat(module, key |> Atom.to_string() |> Macro.camelize())}

    Keyword.merge(
      names ++
        [
          manage_daemon: false,
          socket: socket,
          data_dir:
            Path.join(System.tmp_dir!(), "tsx-data-#{System.unique_integer([:positive])}"),
          retry_min: 20,
          retry_max: 100
        ],
      extra
    )
  end

  # Locally: a manually created test key. In CI: a fresh key through GitHub OIDC.
  def auth_key do
    cond do
      key = System.get_env("TAILSCALED_TEST_AUTH_KEY") -> {:ok, key}
      System.get_env("ACTIONS_ID_TOKEN_REQUEST_URL") -> Tailscaled.Testing.auth_key()
      true -> {:error, "set TAILSCALED_TEST_AUTH_KEY to a test auth key"}
    end
  end

  def await_enrolled(opts, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_enrolled_until(opts, deadline)
  end

  defp await_enrolled_until(opts, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, {:enrollment_deadline, PropertyTable.get(opts[:table], ["auth", "state"])}}
    else
      identity = enrolled_identity(Keyword.put(opts, :timeout, min(remaining, 1_000)))

      if identity do
        {:ok, identity}
      else
        Process.sleep(min(remaining, 100))
        await_enrolled_until(opts, deadline)
      end
    end
  end

  defp enrolled_identity(opts) do
    with :authenticated <- PropertyTable.get(opts[:table], ["auth", "state"]),
         :online <- PropertyTable.get(opts[:table], ["state"]),
         true <-
           tailscale_address?(PropertyTable.get(opts[:table], ["ipv4"])) or
             tailscale_address?(PropertyTable.get(opts[:table], ["ipv6"])),
         {:ok, %{"Self" => %{"ID" => id, "Online" => true} = self}, _} <-
           LocalAPI.request(opts, "GET", "status?peers=false"),
         true <- is_binary(id) and Regex.match?(~r/\A[a-zA-Z0-9]+\z/, id) do
      # Never pass raw status (which can include login URLs) to assertions.
      %{
        node_id: id,
        tags: self["Tags"],
        ipv4: PropertyTable.get(opts[:table], ["ipv4"]),
        ipv6: PropertyTable.get(opts[:table], ["ipv6"])
      }
    else
      _ -> nil
    end
  end

  defp tailscale_address?({100, second, _, _}) when second in 64..127, do: true
  defp tailscale_address?({0xFD7A, 0x115C, 0xA1E0, _, _, _, _, _}), do: true
  defp tailscale_address?(_), do: false

  # Logout removes an ephemeral node from the tailnet; deleting files does not.
  def cleanup_authenticated_daemon(opts, directory, hostname) do
    logout = safely(fn -> Controller.logout(opts[:controller]) end)

    stopped =
      safely(fn ->
        if pid = Process.whereis(opts[:supervisor]), do: Supervisor.stop(pid, :shutdown, 15_000)
        :ok
      end)

    removed = if stopped == :ok, do: File.rm_rf(directory), else: :error

    if logout == :ok and stopped == :ok and match?({:ok, _}, removed) do
      :ok
    else
      # No raw errors, status responses, URLs, or process state in failure output.
      {:error, "Cleanup failed; check/remove test node #{hostname} in the tailnet Machines page"}
    end
  end

  defp safely(fun) do
    fun.()
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  def eventually(fun, tries \\ 100)
  def eventually(fun, 0), do: fun.()

  def eventually(fun, tries) do
    fun.()
  rescue
    ExUnit.AssertionError ->
      Process.sleep(20)
      eventually(fun, tries - 1)
  end
end
