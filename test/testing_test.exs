defmodule Tailscaled.TestingTest do
  # Not async: these tests change process-global environment variables.
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias Tailscaled.Testing

  @env %{
    "TS_OAUTH_CLIENT_ID" => "client",
    "TS_AUDIENCE" => "api.tailscale.com/client",
    "TS_TAGS" => "tag:ci, tag:test",
    "ACTIONS_ID_TOKEN_REQUEST_URL" => "https://oidc.example/token?api-version=2.0",
    "ACTIONS_ID_TOKEN_REQUEST_TOKEN" => "github-bearer",
    "GITHUB_ACTIONS" => "true"
  }

  setup do
    saved = Map.new(@env, fn {name, _} -> {name, System.get_env(name)} end)
    System.put_env(@env)

    on_exit(fn ->
      Enum.each(saved, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)
  end

  test "creates a single-use ephemeral key from the environment, masking credentials" do
    output =
      capture_io(fn -> assert {:ok, "tskey-auth-fake"} = Testing.auth_key(request: &api/4) end)

    assert output ==
             "::add-mask::fake-jwt\n::add-mask::fake-token\n::add-mask::tskey-auth-fake\n"

    assert_received {:create, body}

    assert body == %{
             "expirySeconds" => 600,
             "capabilities" => %{
               "devices" => %{
                 "create" => %{
                   "reusable" => false,
                   "ephemeral" => true,
                   "preauthorized" => true,
                   "tags" => ["tag:ci", "tag:test"]
                 }
               }
             }
           }
  end

  test "options override the environment" do
    System.delete_env("GITHUB_ACTIONS")
    System.put_env("TS_OAUTH_CLIENT_ID", "ignored")

    output =
      capture_io(fn ->
        assert {:ok, "tskey-auth-fake"} =
                 Testing.auth_key(client_id: "client", tags: ["tag:other"], request: &api/4)
      end)

    # Masking happens only under GitHub Actions.
    assert output == ""
    assert_received {:create, %{"capabilities" => %{"devices" => %{"create" => create}}}}
    assert create["tags"] == ["tag:other"]
  end

  test "errors name the missing setting or failed step, never credentials or bodies" do
    System.delete_env("TS_TAGS")
    assert {:error, "TS_TAGS is not set"} = Testing.auth_key(request: &api/4)

    System.delete_env("ACTIONS_ID_TOKEN_REQUEST_URL")

    assert {:error, "ACTIONS_ID_TOKEN_REQUEST_URL is not set"} =
             Testing.auth_key(tags: ["tag:ci"], request: &api/4)

    System.put_env(@env)

    for {response, message} <- [
          {{:ok, 401, "echoed-secret"}, "GitHub OIDC token request failed (HTTP 401)"},
          {{:ok, 200, "not json"}, "GitHub OIDC token request failed"},
          {{:error, :transport}, "GitHub OIDC token request failed"}
        ] do
      assert {:error, ^message} = Testing.auth_key(request: fn _, _, _, _ -> response end)
    end

    assert {:error, "GitHub OIDC token request failed"} =
             Testing.auth_key(request: fn _, _, _, _ -> raise "echoed-secret" end)

    rejected_key = fn
      :post, "https://api.tailscale.com/api/v2/tailnet/-/keys", _, _ -> {:ok, 403, "body"}
      method, url, headers, body -> api(method, url, headers, body)
    end

    capture_io(fn ->
      assert {:error, "Auth key creation failed (HTTP 403)"} =
               Testing.auth_key(request: rejected_key)
    end)
  end

  defp api(:get, url, headers, nil) do
    assert url == "https://oidc.example/token?api-version=2.0&audience=api.tailscale.com%2Fclient"
    assert headers == [{"authorization", "Bearer github-bearer"}]
    {:ok, 200, ~s({"value":"fake-jwt"})}
  end

  defp api(:post, "https://api.tailscale.com/api/v2/oauth/token-exchange", [], {type, body}) do
    assert type == "application/x-www-form-urlencoded"
    assert URI.decode_query(body) == %{"client_id" => "client", "jwt" => "fake-jwt"}
    {:ok, 200, ~s({"access_token":"fake-token"})}
  end

  defp api(:post, "https://api.tailscale.com/api/v2/tailnet/-/keys", headers, {type, body}) do
    assert type == "application/json"
    assert headers == [{"authorization", "Bearer fake-token"}]
    send(self(), {:create, JSON.decode!(body)})
    {:ok, 200, ~s({"id":"k123","key":"tskey-auth-fake"})}
  end
end
