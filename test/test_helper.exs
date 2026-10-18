# mix test uses --no-start: boot dependencies, not a default networking instance.
Application.load(:tailscaled_ex)

for app <- Application.spec(:tailscaled_ex, :applications) do
  {:ok, _} = Application.ensure_all_started(app)
end

exclude = if System.get_env("TAILSCALED_TEST_BINARY"), do: [], else: [integration: true]

exclude =
  if System.get_env("TAILSCALED_TEST_NETWORK") == "1",
    do: exclude,
    else: [network: true] ++ exclude

exclude =
  if System.get_env("TAILSCALED_TEST_AUTH") == "1" do
    # Explicit opt-in with missing credentials is a failure, never a silent skip.
    for name <- [
          "TAILSCALED_TEST_BINARY",
          "TS_OAUTH_CLIENT_ID",
          "TS_AUDIENCE",
          "ACTIONS_ID_TOKEN_REQUEST_URL",
          "ACTIONS_ID_TOKEN_REQUEST_TOKEN"
        ] do
      if System.get_env(name) in [nil, ""], do: raise("real authentication requires #{name}")
    end

    exclude
  else
    [real_auth: true] ++ exclude
  end

ExUnit.start(exclude: exclude)
