defmodule Tailscaled.Snapshot do
  @moduledoc false

  defstruct backend: :unknown,
            self: %{},
            peers: %{},
            health: [],
            url: nil,
            error: nil,
            version: nil,
            auth_attempt: false

  @states %{
    0 => :no_state,
    1 => :in_use_other_user,
    2 => :needs_login,
    3 => :needs_machine_auth,
    4 => :stopped,
    5 => :starting,
    6 => :running,
    "NoState" => :no_state,
    "InUseOtherUser" => :in_use_other_user,
    "NeedsLogin" => :needs_login,
    "NeedsMachineAuth" => :needs_machine_auth,
    "Stopped" => :stopped,
    "Starting" => :starting,
    "Running" => :running
  }

  def update(snapshot, notification) do
    snapshot
    |> initial(notification["InitialStatus"])
    |> self_change(notification["SelfChange"])
    |> peer_changes(notification)
    |> state_change(notification)
    |> authentication(notification)
  end

  def properties(snapshot) do
    root = %{
      ["state"] => connectivity(snapshot.backend),
      ["backend_state"] => snapshot.backend,
      ["auth", "state"] => auth_state(snapshot),
      ["auth", "url"] => snapshot.url,
      ["auth", "error"] => snapshot.error,
      ["health"] => snapshot.health,
      ["version"] => snapshot.version
    }

    Enum.reduce(snapshot.peers, Map.merge(root, node_properties([], snapshot.self)), fn {_id,
                                                                                         peer},
                                                                                        acc ->
      Map.merge(acc, node_properties(["peers", peer.id], peer))
    end)
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp initial(_snapshot, status) when is_map(status) do
    peers =
      Map.new(status["Peer"] || %{}, fn {_key, peer} -> {peer["NodeID"], status_node(peer)} end)

    %__MODULE__{
      backend: backend(status["BackendState"]),
      self: status_node(status["Self"] || %{}),
      peers: peers,
      health: status["Health"] || [],
      url: url(status["AuthURL"]),
      version: status["Version"]
    }
  end

  defp initial(snapshot, _status), do: snapshot

  defp self_change(snapshot, node) when is_map(node) do
    node = normalize_node(node)
    peers = if snapshot.self[:id] != node[:id], do: %{}, else: snapshot.peers
    %{snapshot | self: node, peers: peers}
  end

  defp self_change(snapshot, _node), do: snapshot

  defp peer_changes(snapshot, notification) do
    peers =
      Enum.reduce(notification["PeersChanged"] || [], snapshot.peers, fn peer, acc ->
        Map.put(acc, peer["ID"], normalize_node(peer))
      end)

    %{snapshot | peers: Map.drop(peers, notification["PeersRemoved"] || [])}
  end

  defp state_change(snapshot, notification) do
    # Profile resets emit NoState without an empty SelfChange or peer removals.
    snapshot =
      if notification["State"] in [0, "NoState"] do
        %{snapshot | self: %{}, peers: %{}, url: nil, error: nil, auth_attempt: false}
      else
        snapshot
      end

    backend =
      if is_nil(notification["State"]), do: snapshot.backend, else: backend(notification["State"])

    health =
      if is_map(notification["Health"]), do: health(notification["Health"]), else: snapshot.health

    %{
      snapshot
      | backend: backend,
        health: health,
        version: notification["Version"] || snapshot.version
    }
  end

  defp authentication(snapshot, notification) do
    snapshot =
      case notification["BrowseToURL"] do
        nil -> snapshot
        value -> %{snapshot | url: url(value), error: nil}
      end

    snapshot =
      if notification["ErrMessage"],
        do: %{snapshot | error: :authentication_failed, url: nil, auth_attempt: false},
        else: snapshot

    # Start can leave the backend stopped until a later notification. Only a new
    # stopped observation cancels login, not an unrelated preferences/peer update.
    stopped =
      snapshot.backend == :stopped and
        (not is_nil(notification["State"]) or is_map(notification["InitialStatus"]))

    if snapshot.backend in [:running, :needs_machine_auth] or stopped do
      %{snapshot | url: nil, error: nil, auth_attempt: false}
    else
      snapshot
    end
  end

  defp status_node(peer) do
    %{
      id: to_string(peer["ID"] || peer["NodeID"] || ""),
      hostname: peer["HostName"],
      dns_name: dns_name(peer["DNSName"]),
      ips: addresses(peer["TailscaleIPs"]),
      tags: peer["Tags"] || [],
      online: peer["Online"]
    }
  end

  defp normalize_node(peer) do
    %{
      id: to_string(peer["StableID"] || peer["ID"] || ""),
      hostname: get_in(peer, ["Hostinfo", "Hostname"]),
      dns_name: dns_name(peer["Name"]),
      ips: addresses(peer["Addresses"]),
      tags: peer["Tags"] || [],
      online: peer["Online"]
    }
  end

  defp node_properties(prefix, node) do
    ips = node[:ips] || []

    fields = %{
      "hostname" => node[:hostname],
      "dns_name" => node[:dns_name],
      "ipv4" => Enum.find(ips, &(tuple_size(&1) == 4)),
      "ipv6" => Enum.find(ips, &(tuple_size(&1) == 8))
    }

    fields = if prefix == [], do: fields, else: Map.put(fields, "online", node[:online])
    tags_path = if prefix == [], do: ["self", "tags"], else: prefix ++ ["tags"]

    Map.new(fields, fn {key, value} -> {prefix ++ [key], value} end)
    |> Map.put(tags_path, node[:tags] || [])
  end

  defp addresses(values) do
    Enum.flat_map(values || [], fn value ->
      case value |> String.split("/") |> hd() |> String.to_charlist() |> :inet.parse_address() do
        {:ok, ip} -> [ip]
        _ -> []
      end
    end)
  end

  defp dns_name(value) when is_binary(value) and value != "", do: String.trim_trailing(value, ".")
  defp dns_name(_), do: nil
  defp backend(value), do: Map.get(@states, value, :unknown)

  defp url(value) when is_binary(value) do
    case URI.new(value) do
      {:ok, %URI{scheme: "https", host: host, userinfo: nil}} when is_binary(host) -> value
      _ -> nil
    end
  end

  defp url(_), do: nil

  defp health(%{"Warnings" => warnings}) when is_map(warnings),
    do:
      warnings
      |> Map.values()
      |> Enum.map(& &1["Text"])
      |> Enum.filter(&is_binary/1)
      |> Enum.sort()

  defp health(_), do: []

  defp connectivity(:running), do: :online
  defp connectivity(:unknown), do: :unavailable
  defp connectivity(_), do: :offline

  defp auth_state(%{backend: :running}), do: :authenticated
  defp auth_state(%{backend: :needs_machine_auth}), do: :needs_approval
  defp auth_state(%{error: error}) when not is_nil(error), do: :error
  defp auth_state(%{auth_attempt: true}), do: :authenticating
  defp auth_state(%{url: url}) when is_binary(url), do: :authenticating
  defp auth_state(%{backend: :needs_login}), do: :needs_login
  defp auth_state(%{backend: :stopped}), do: :stopped
  defp auth_state(_), do: :unknown
end
