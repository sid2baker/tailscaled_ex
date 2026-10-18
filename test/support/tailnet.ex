defmodule Tailscaled.Test.Tailnet do
  @moduledoc false
  # Test tooling for .github/workflows/tailnet.yml. Credentials stay in memory, are
  # masked in GitHub output, and errors carry only a stage and HTTP status.
  alias Tailscaled.Controller

  @api "https://api.tailscale.com/api/v2"
  @capabilities %{reusable: false, ephemeral: true, preauthorized: true, tags: ["tag:ci"]}

  @derive {Inspect, only: [:hostname, :key_id]}
  defstruct [:hostname, :token, :key_id, :key, :request]

  # GitHub OIDC JWT -> temporary API token -> single-use ephemeral tag:ci auth key.
  def create_key(hostname, opts \\ []) do
    env = Keyword.get(opts, :env, &System.get_env/1)
    tailnet = %__MODULE__{hostname: hostname, request: Keyword.get(opts, :request, &request/4)}
    audience = URI.encode_www_form(env.("TS_AUDIENCE"))
    oidc = env.("ACTIONS_ID_TOKEN_REQUEST_URL") <> "&audience=" <> audience
    form = &URI.encode_query(%{client_id: env.("TS_OAUTH_CLIENT_ID"), jwt: &1})

    body = %{
      keyType: "auth",
      description: hostname,
      expirySeconds: 600,
      capabilities: %{devices: %{create: @capabilities}}
    }

    with {:ok, jwt} <-
           tailnet
           |> call(:github_oidc, :get, oidc, env.("ACTIONS_ID_TOKEN_REQUEST_TOKEN"))
           |> secret("value"),
         {:ok, token} <-
           tailnet
           |> call(:token_exchange, :post, "/oauth/token-exchange", nil, {:form, form.(jwt)})
           |> secret("access_token"),
         {:ok, %{"id" => id} = key} <-
           call(tailnet, :create_key, :post, "/tailnet/-/keys", token, {:json, body}),
         true <- id?(id),
         {:ok, secret} <- secret({:ok, key}, "key") do
      {:ok, %{tailnet | token: token, key_id: id, key: secret}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, {:create_key, :invalid_response}}
    end
  end

  # Enrollment uses the library's own auth-key path, never a runner login.
  def login(%__MODULE__{key: key}, controller) do
    if Controller.login(controller, {:auth_key, key}) == :ok, do: :ok, else: {:error, :login}
  catch
    :exit, _ -> {:error, :login}
  end

  def device(%__MODULE__{} = tailnet, node_id) do
    with true <- id?(node_id),
         {:ok, %{} = device} <-
           call(tailnet, :device, :get, "/device/#{node_id}?fields=all", tailnet.token) do
      {:ok, Map.take(device, ~w(nodeId hostname tags authorized isEphemeral))}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, {:device, :invalid_response}}
    end
  end

  # After logout: delete leftover nodes with this run's random hostname and tag:ci
  # (never others), then revoke the key. Already-absent resources are fine.
  def cleanup(%__MODULE__{} = tailnet) do
    query = URI.encode_query(%{hostname: tailnet.hostname, fields: "all"})

    nodes =
      delete_nodes(
        tailnet,
        call(tailnet, :find_node, :get, "/tailnet/-/devices?" <> query, tailnet.token)
      )

    key = delete(tailnet, :revoke_key, "/tailnet/-/keys/#{tailnet.key_id}")
    if nodes == :ok and key == :ok, do: :ok, else: {:error, %{nodes: nodes, key: key}}
  end

  defp delete_nodes(tailnet, {:ok, %{"devices" => devices}}) when is_list(devices) do
    devices
    |> Enum.filter(&owned?(tailnet, &1))
    |> Enum.map(&delete(tailnet, :delete_node, "/device/#{&1["nodeId"]}"))
    |> Enum.find(:ok, &(&1 != :ok))
  end

  defp delete_nodes(_tailnet, {:error, reason}), do: {:error, reason}
  defp delete_nodes(_tailnet, _), do: {:error, {:find_node, :invalid_response}}

  defp owned?(tailnet, device) do
    device["hostname"] == tailnet.hostname and device["tags"] == ["tag:ci"] and
      id?(device["nodeId"])
  end

  defp delete(tailnet, stage, path) do
    case call(tailnet, stage, :delete, path, tailnet.token) do
      {:ok, _} -> :ok
      {:error, {^stage, {:http, 404}}} -> :ok
      error -> error
    end
  end

  defp call(tailnet, stage, method, url, token, body \\ nil) do
    url = if String.starts_with?(url, "/"), do: @api <> url, else: url
    headers = if token, do: [{"authorization", "Bearer " <> token}], else: []

    case tailnet.request.(method, url, headers, encode(body)) do
      {:ok, status, ""} when status in 200..299 -> {:ok, nil}
      {:ok, status, data} when status in 200..299 -> decode(stage, data)
      {:ok, status, _} -> {:error, {stage, {:http, status}}}
      _ -> {:error, {stage, :transport}}
    end
  rescue
    _ -> {:error, {stage, :transport}}
  end

  defp encode({:json, data}), do: {"application/json", JSON.encode!(data)}
  defp encode({:form, data}), do: {"application/x-www-form-urlencoded", data}
  defp encode(nil), do: nil

  defp decode(stage, data) do
    case JSON.decode(data) do
      {:ok, value} -> {:ok, value}
      _ -> {:error, {stage, :invalid_response}}
    end
  end

  defp secret({:ok, body}, field) do
    value = if is_map(body), do: body[field]

    if is_binary(value) and Regex.match?(~r/\A[\x21-\x7e]+\z/, value) do
      IO.puts("::add-mask::" <> value)
      {:ok, value}
    else
      {:error, {:invalid_response, field}}
    end
  end

  defp secret(error, _field), do: error

  defp id?(id), do: is_binary(id) and Regex.match?(~r/\A[a-zA-Z0-9]{1,64}\z/, id)

  # One request, verified TLS, no redirects; bodies never leave this module.
  defp request(method, url, headers, body) do
    headers = for {name, value} <- headers, do: {~c"#{name}", ~c"#{value}"}

    request =
      case body do
        nil -> {~c"#{url}", headers}
        {type, data} -> {~c"#{url}", headers, ~c"#{type}", data}
      end

    ssl = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]

    options = [ssl: ssl, timeout: 20_000, connect_timeout: 20_000, autoredirect: false]

    case :httpc.request(method, request, options, body_format: :binary) do
      {:ok, {{_, status, _}, _headers, data}} -> {:ok, status, data}
      _ -> {:error, :transport}
    end
  end
end
