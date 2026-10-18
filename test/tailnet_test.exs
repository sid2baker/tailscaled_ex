defmodule Tailscaled.TailnetTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO
  alias Tailscaled.Test.Tailnet

  @hostname "tsx-auth-0123456789abcdef"
  @env %{
    "TS_OAUTH_CLIENT_ID" => "client",
    "TS_AUDIENCE" => "api.tailscale.com/client",
    "ACTIONS_ID_TOKEN_REQUEST_URL" => "https://oidc.example/token?api-version=2.0",
    "ACTIONS_ID_TOKEN_REQUEST_TOKEN" => "github-bearer"
  }

  test "provisions a single-use ephemeral tag:ci key through GitHub OIDC, masking credentials" do
    output =
      capture_io(fn ->
        assert {:ok, tailnet} = Tailnet.create_key(@hostname, env: &@env[&1], request: &api/4)
        assert tailnet.key == "tskey-auth-fake" and tailnet.key_id == "k123"
        refute inspect(tailnet) =~ "fake"
      end)

    assert output ==
             "::add-mask::fake-jwt\n::add-mask::fake-token\n::add-mask::tskey-auth-fake\n"
  end

  test "errors expose only the stage and HTTP status" do
    for {response, reason} <- [
          {{:ok, 401, "echoed-secret"}, {:github_oidc, {:http, 401}}},
          {{:error, :timeout}, {:github_oidc, :transport}},
          {{:ok, 200, "not json"}, {:github_oidc, :invalid_response}},
          {{:ok, 200, ~s({"value":"bad\\nvalue"})}, {:invalid_response, "value"}}
        ] do
      request = fn _, _, _, _ -> response end
      assert {:error, ^reason} = Tailnet.create_key(@hostname, env: &@env[&1], request: request)
    end
  end

  test "cleanup deletes only this run's tagged node, revokes the key, and accepts absence" do
    tailnet =
      tailnet(fn
        :get, "/api/v2/tailnet/-/devices" ->
          devices = [
            %{"nodeId" => "nOurs", "hostname" => @hostname, "tags" => ["tag:ci"]},
            %{"nodeId" => "nUntagged", "hostname" => @hostname, "tags" => []},
            %{"nodeId" => "nOther", "hostname" => "tsx-auth-other", "tags" => ["tag:ci"]}
          ]

          {:ok, 200, JSON.encode!(%{"devices" => devices})}

        :delete, "/api/v2/tailnet/-/keys/k123" ->
          {:ok, 404, ""}

        :delete, path ->
          send(self(), {:deleted, path})
          {:ok, 200, ""}
      end)

    assert :ok = Tailnet.cleanup(tailnet)
    assert_received {:deleted, "/api/v2/device/nOurs"}
    refute_received {:deleted, _}

    failing =
      tailnet(fn
        :get, _ -> {:ok, 200, ~s({"devices":[]})}
        :delete, _ -> {:ok, 403, "withheld"}
      end)

    assert {:error, %{nodes: :ok, key: {:error, {:revoke_key, {:http, 403}}}}} =
             Tailnet.cleanup(failing)
  end

  defp tailnet(handler) do
    request = fn method, url, _headers, nil -> handler.(method, URI.parse(url).path) end
    %Tailnet{hostname: @hostname, token: "fake-token", key_id: "k123", request: request}
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

  defp api(:post, "https://api.tailscale.com/api/v2/tailnet/-/keys", headers, {_, body}) do
    assert headers == [{"authorization", "Bearer fake-token"}]

    assert JSON.decode!(body) == %{
             "keyType" => "auth",
             "description" => @hostname,
             "expirySeconds" => 600,
             "capabilities" => %{
               "devices" => %{
                 "create" => %{
                   "reusable" => false,
                   "ephemeral" => true,
                   "preauthorized" => true,
                   "tags" => ["tag:ci"]
                 }
               }
             }
           }

    {:ok, 200, ~s({"id":"k123","key":"tskey-auth-fake"})}
  end
end
