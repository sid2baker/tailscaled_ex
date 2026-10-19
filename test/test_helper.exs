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

# Joining a real tailnet only on request: mix test --only real_auth
ExUnit.start(exclude: [real_auth: true] ++ exclude)
