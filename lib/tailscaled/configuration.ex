defmodule Tailscaled.Configuration do
  @moduledoc false

  import Bitwise

  alias Tailscaled.Serve

  @defaults %{
    hostname: "",
    accept_dns: false,
    accept_routes: false,
    ssh: false,
    advertise_routes: [],
    advertise_tags: [],
    serve: []
  }
  @fields %{
    hostname: "Hostname",
    accept_dns: "CorpDNS",
    accept_routes: "RouteAll",
    ssh: "RunSSH",
    advertise_routes: "AdvertiseRoutes",
    advertise_tags: "AdvertiseTags"
  }

  def normalize(config) when is_map(config) do
    with true <- Enum.all?(Map.keys(config), &Map.has_key?(@defaults, &1)),
         {:ok, hostname} <- hostname(Map.get(config, :hostname, "")),
         {:ok, routes} <- routes(Map.get(config, :advertise_routes, [])),
         {:ok, tags} <- tags(Map.get(config, :advertise_tags, [])),
         {:ok, serve} <- Serve.normalize(Map.get(config, :serve, [])),
         true <-
           Enum.all?(
             [:accept_dns, :accept_routes, :ssh],
             &is_boolean(Map.get(config, &1, @defaults[&1]))
           ) do
      {:ok,
       Map.merge(@defaults, config)
       |> Map.merge(%{
         hostname: hostname,
         advertise_routes: routes,
         advertise_tags: tags,
         serve: serve
       })}
    else
      false -> {:error, :invalid_configuration}
      error -> error
    end
  end

  def normalize(_), do: {:error, :invalid_configuration}

  def observed(prefs, serve) do
    Map.new(@fields, fn {key, field} -> {key, Map.get(prefs, field, @defaults[key])} end)
    |> Map.update!(:advertise_routes, &Enum.sort(&1 || []))
    |> Map.update!(:advertise_tags, &Enum.sort(Enum.uniq(&1 || [])))
    |> Map.merge(if is_nil(serve), do: %{}, else: %{serve: serve})
  end

  def preferences(config) do
    config |> Map.take(Map.keys(@fields)) |> Map.new(fn {key, value} -> {@fields[key], value} end)
  end

  def patch(config, current) do
    config
    |> preferences()
    |> Enum.reject(fn {key, value} -> equivalent?(key, current[key], value) end)
    |> Enum.flat_map(fn {key, value} -> [{key, value}, {key <> "Set", true}] end)
    |> Map.new()
  end

  defp equivalent?("AdvertiseTags", old, new),
    do: Enum.sort(Enum.uniq(old || [])) == Enum.sort(Enum.uniq(new || []))

  defp equivalent?("AdvertiseRoutes", old, new), do: Enum.sort(old || []) == new
  defp equivalent?(_key, old, new), do: old == new

  defp hostname(""), do: {:ok, ""}

  defp hostname(value) when is_binary(value) do
    value = String.downcase(value)

    if byte_size(value) <= 63 and Regex.match?(~r/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/, value),
      do: {:ok, value},
      else: {:error, :invalid_hostname}
  end

  defp hostname(_), do: {:error, :invalid_hostname}

  defp tags(values) when is_list(values) do
    # tailcfg.CheckTag (Tailscale 1.104.1) accepts ASCII letters of either case.
    if Enum.all?(
         values,
         &(is_binary(&1) and Regex.match?(~r/\Atag:[a-zA-Z][a-zA-Z0-9-]*\z/, &1))
       ),
       do: {:ok, Enum.sort(Enum.uniq(values))},
       else: {:error, :invalid_tag}
  end

  defp tags(_), do: {:error, :invalid_tag}

  defp routes(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case route(value) do
        {:ok, route} -> {:cont, {:ok, [route | acc]}}
        _ -> {:halt, {:error, :invalid_route}}
      end
    end)
    |> case do
      {:ok, routes} -> {:ok, Enum.sort(Enum.uniq(routes))}
      error -> error
    end
  end

  defp routes(_), do: {:error, :invalid_route}

  defp route(value) when is_binary(value) do
    with [ip, prefix] <- String.split(value, "/"),
         {:ok, ip} <- :inet.parse_address(String.to_charlist(ip)),
         {prefix, ""} <- Integer.parse(prefix) do
      route({ip, prefix})
    else
      _ -> {:error, :invalid_route}
    end
  end

  defp route({ip, prefix})
       when is_tuple(ip) and tuple_size(ip) in [4, 8] and is_integer(prefix) do
    width = if tuple_size(ip) == 4, do: 8, else: 16
    bits = tuple_size(ip) * width

    if prefix in 0..bits and
         Enum.all?(Tuple.to_list(ip), &(is_integer(&1) and &1 >= 0 and &1 < 1 <<< width)) do
      number = Enum.reduce(Tuple.to_list(ip), 0, &((&2 <<< width) + &1))
      network = (number >>> (bits - prefix)) <<< (bits - prefix)

      address =
        for offset <- (bits - width)..0//-width, do: band(network >>> offset, (1 <<< width) - 1)

      {:ok, to_string(:inet.ntoa(List.to_tuple(address))) <> "/#{prefix}"}
    else
      {:error, :invalid_route}
    end
  end

  defp route(_), do: {:error, :invalid_route}
end
