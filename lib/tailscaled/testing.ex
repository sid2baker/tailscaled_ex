defmodule Tailscaled.Testing do
  @moduledoc """
  Auth keys for tests and CI, created from the GitHub Actions job's OIDC identity.

      {:ok, key} = Tailscaled.Testing.auth_key()
      :ok = Tailscaled.login(auth_key: key)

  Keys are single-use, ephemeral, and preauthorized, and expire after 10 minutes if
  unused. Logging out removes the ephemeral node. This is a testing aid, not a
  production login method.

  ## Setup

  1. In Tailscale's **Trust credentials** page, create an OpenID Connect credential
     with issuer `https://token.actions.githubusercontent.com`, a subject matching your
     workflow (such as `repo:OWNER/REPO:environment:ENV`), the `auth_keys` write scope,
     and your tags. See
     [workload identity federation](https://tailscale.com/kb/1581/workload-identity-federation).
  2. Give the GitHub Actions job:

         permissions:
           contents: read
           id-token: write
         env:
           TS_OAUTH_CLIENT_ID: ${{ secrets.TS_OAUTH_CLIENT_ID }}
           TS_AUDIENCE: ${{ secrets.TS_AUDIENCE }}
           TS_TAGS: tag:ci

  GitHub provides the job's OIDC token only with `id-token: write`. Under GitHub
  Actions, the OIDC token, temporary API token, and key are masked in the job log.

  ## Local testing

  OIDC tokens exist only in CI. Locally, create an auth key for testing in the admin
  console (**Settings → Keys**), ideally in a separate tailnet: **Reusable**,
  **Ephemeral**, **Pre-approved**, and tagged, and pass it to `Tailscaled.login/1`:

      Tailscaled.login(auth_key: System.fetch_env!("TAILSCALED_TEST_AUTH_KEY"))
  """

  @api "https://api.tailscale.com/api/v2"

  @doc """
  Create an auth key.

  Settings come from environment variables, or from options with the same meaning:
  `:client_id` (`TS_OAUTH_CLIENT_ID`), `:audience` (`TS_AUDIENCE`), and `:tags`
  (`TS_TAGS`, comma-separated). Returns `{:error, message}` without credentials or
  response bodies. Nothing is retried.
  """
  @spec auth_key(keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def auth_key(opts \\ []) do
    request = Keyword.get(opts, :request, &request/4)

    with {:ok, client_id} <- setting(opts, :client_id, "TS_OAUTH_CLIENT_ID"),
         {:ok, audience} <- setting(opts, :audience, "TS_AUDIENCE"),
         {:ok, tags} <- setting(opts, :tags, "TS_TAGS"),
         {:ok, jwt} <- github_token(request, audience),
         {:ok, token} <- exchange(request, client_id, jwt) do
      create_key(request, token, tags)
    end
  end

  # GitHub sets these variables only for jobs with `id-token: write`.
  defp github_token(request, audience) do
    with {:ok, url} <- setting([], :url, "ACTIONS_ID_TOKEN_REQUEST_URL"),
         {:ok, bearer} <- setting([], :bearer, "ACTIONS_ID_TOKEN_REQUEST_TOKEN") do
      url = url <> "&audience=" <> URI.encode_www_form(audience)
      fetch(request, "GitHub OIDC token request", :get, url, bearer, nil, "value")
    end
  end

  defp exchange(request, client_id, jwt) do
    body =
      {"application/x-www-form-urlencoded", URI.encode_query(%{client_id: client_id, jwt: jwt})}

    url = @api <> "/oauth/token-exchange"
    fetch(request, "Tailscale token exchange", :post, url, nil, body, "access_token")
  end

  defp create_key(request, token, tags) do
    tags =
      if is_binary(tags),
        do: tags |> String.split(",", trim: true) |> Enum.map(&String.trim/1),
        else: tags

    create = %{reusable: false, ephemeral: true, preauthorized: true, tags: tags}
    body = JSON.encode!(%{expirySeconds: 600, capabilities: %{devices: %{create: create}}})
    url = @api <> "/tailnet/-/keys"
    fetch(request, "Auth key creation", :post, url, token, {"application/json", body}, "key")
  end

  defp setting(opts, key, name) do
    case Keyword.get_lazy(opts, key, fn -> System.get_env(name) end) do
      value when value in [nil, "", []] -> {:error, "#{name} is not set"}
      value -> {:ok, value}
    end
  end

  defp fetch(request, step, method, url, token, body, field) do
    headers = if token, do: [{"authorization", "Bearer " <> token}], else: []

    with {:ok, status, data} when status in 200..299 <- request.(method, url, headers, body),
         {:ok, %{^field => value}} when is_binary(value) <- JSON.decode(data) do
      if System.get_env("GITHUB_ACTIONS") == "true", do: IO.puts("::add-mask::" <> value)
      {:ok, value}
    else
      {:ok, status, _body} -> {:error, "#{step} failed (HTTP #{status})"}
      _ -> {:error, "#{step} failed"}
    end
  rescue
    _ -> {:error, "#{step} failed"}
  end

  # One request with verified TLS and no redirects.
  defp request(method, url, headers, body) do
    {:ok, _} = Application.ensure_all_started([:inets, :ssl])
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
