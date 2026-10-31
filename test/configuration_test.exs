defmodule Tailscaled.ConfigurationTest do
  use ExUnit.Case, async: true
  alias Tailscaled.Configuration

  test "normalizes managed values and CIDR networks" do
    assert {:ok, config} =
             Configuration.normalize(%{
               hostname: "Nerves-Livebook",
               advertise_routes: ["10.1.2.3/16", {{10, 1, 1, 1}, 16}, "2001:db8::ff/64"]
             })

    assert config.hostname == "nerves-livebook"
    assert config.advertise_routes == ["10.1.0.0/16", "2001:db8::/64"]
    refute config.accept_dns
  end

  test "DNS management is opt-in and defaults disable an existing opt-in" do
    assert {:ok, defaults} = Configuration.normalize(%{})
    assert {:ok, config} = Configuration.normalize(%{accept_dns: true})
    assert config.accept_dns
    assert Configuration.observed(Configuration.preferences(config), []).accept_dns

    assert Configuration.patch(defaults, Configuration.preferences(config)) == %{
             "CorpDNS" => false,
             "CorpDNSSet" => true
           }
  end

  test "rejects unsupported fields, credentials and malformed settings without including values" do
    for input <- [
          %{auth_key: "secret"},
          %{hostname: "bad_host"},
          %{ssh: "yes"},
          %{advertise_routes: ["1.2.3.4/33"]},
          %{advertise_routes: [{{999, 0, 0, 0}, 24}]},
          %{serve: [%{https: 0, to: "http://localhost"}]},
          %{serve: [%{https: 443, to: "http://user:secret@localhost"}]},
          %{serve: [%{https: 443, to: "ftp://localhost"}]}
        ] do
      assert {:error, reason} = Configuration.normalize(input)
      refute inspect(reason) =~ "secret"
    end
  end

  test "tags match CheckTag and normalize as a sorted set without changing case" do
    assert {:ok, config} =
             Configuration.normalize(%{advertise_tags: ["tag:z", "tag:A-1", "tag:z", "tag:ci"]})

    assert config.advertise_tags == ["tag:A-1", "tag:ci", "tag:z"]
    assert {:ok, %{advertise_tags: []}} = Configuration.normalize(%{})

    for value <- [
          nil,
          "tag:ci",
          [nil],
          [1],
          [:ci],
          ["ci"],
          ["Tag:ci"],
          ["tag:"],
          ["tag:1a"],
          ["tag:-a"],
          ["tag:a_b"],
          ["tag:a.b"],
          ["tag:é"],
          ["tag:a\n"],
          [<<255>>]
        ] do
      assert {:error, :invalid_tag} = Configuration.normalize(%{advertise_tags: value})
    end

    assert {:error, :invalid_configuration} = Configuration.normalize(%{tags: ["tag:ci"]})
  end

  test "tag patch and readback compare sets, including nil and absent values" do
    {:ok, config} = Configuration.normalize(%{advertise_tags: ["tag:b", "tag:a"]})
    assert Configuration.preferences(config)["AdvertiseTags"] == ["tag:a", "tag:b"]

    assert Configuration.patch(%{advertise_tags: config.advertise_tags}, %{}) == %{
             "AdvertiseTags" => ["tag:a", "tag:b"],
             "AdvertiseTagsSet" => true
           }

    current = %{"AdvertiseTags" => ["tag:b", "tag:a", "tag:b"]}
    assert Configuration.patch(%{advertise_tags: config.advertise_tags}, current) == %{}
    assert Configuration.observed(current, []).advertise_tags == ["tag:a", "tag:b"]

    for prefs <- [%{}, %{"AdvertiseTags" => nil}] do
      assert Configuration.observed(prefs, []).advertise_tags == []
      assert Configuration.patch(%{advertise_tags: []}, prefs) == %{}
    end
  end

  test "configuration delegates Serve endpoint normalization" do
    assert {:ok, config} =
             Configuration.normalize(%{serve: [%{https: 443, to: "http://LOCALHOST:4000"}]})

    assert config.serve == [%{https: 443, to: "http://localhost:4000"}]
  end

  test "observed preferences expose only managed fields, preserving false and normalizing nil routes" do
    prefs = %{
      "Hostname" => "external.example",
      "CorpDNS" => false,
      "RouteAll" => true,
      "RunSSH" => false,
      "AdvertiseRoutes" => nil,
      "Persist" => %{"PrivateNodeKey" => "private"}
    }

    assert Configuration.observed(prefs, []) == %{
             hostname: "external.example",
             accept_dns: false,
             accept_routes: true,
             ssh: false,
             advertise_routes: [],
             advertise_tags: [],
             serve: []
           }
  end

  test "preference patch only touches managed differences" do
    {:ok, config} = Configuration.normalize(%{})

    current =
      Map.merge(Configuration.preferences(config), %{
        "Unmanaged" => true,
        "AdvertiseRoutes" => nil
      })

    assert Configuration.patch(config, current) == %{}
    assert Configuration.patch(%{}, current) == %{}
    assert Configuration.patch(%{serve: []}, current) == %{}

    assert Configuration.patch(%{hostname: "partial"}, current) == %{
             "Hostname" => "partial",
             "HostnameSet" => true
           }

    assert Configuration.patch(%{config | ssh: true}, current) == %{
             "RunSSH" => true,
             "RunSSHSet" => true
           }
  end
end
