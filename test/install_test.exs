defmodule Tailscaled.InstallTest do
  use ExUnit.Case, async: true
  alias Mix.Tasks.Tailscaled.Install
  alias Tailscaled.Installer

  @moduletag :tmp_dir
  @version "1.100.0"

  test "detects Linux hosts without using cross-compilation metadata" do
    assert Installer.architecture!(:host, "armv7-nerves-linux-gnueabihf", "x86_64-pc-linux-gnu") ==
             "amd64"

    assert Installer.architecture!(:host, nil, "aarch64-unknown-linux-musl") == "arm64"
  end

  test "uses toolchain architecture, not the board name or build host" do
    for {triple, expected} <- [
          {"aarch64-nerves-linux-gnu", "arm64"},
          {"armv6-nerves-linux-gnueabihf", "arm"},
          {"armv7-nerves-linux-gnueabihf", "arm"},
          {"x86_64-nerves-linux-musl", "amd64"},
          {"i686-buildroot-linux-gnu", "386"},
          {"riscv64-nerves-linux-gnu", "riscv64"}
        ] do
      assert Installer.architecture!(:custom_board, triple, "x86_64-apple-darwin") == expected
    end
  end

  test "unknown targets and non-Linux hosts fail rather than guessing" do
    for {target, triple, host} <- [
          {:rpi4, nil, "x86_64-pc-linux-gnu"},
          {:custom, "", "x86_64-pc-linux-gnu"},
          {:custom, "powerpc-linux-gnu", "x86_64-pc-linux-gnu"},
          {:custom, "armeb-linux-gnueabi", "x86_64-pc-linux-gnu"},
          {:host, nil, "aarch64-apple-darwin"}
        ] do
      assert_raise ArgumentError, ~r/pass --arch explicitly/, fn ->
        Installer.architecture!(target, triple, host)
      end
    end
  end

  test "validates task arguments before downloading" do
    assert_raise OptionParser.ParseError, fn -> Install.run(["--unknown"]) end

    for args <- [[], [""], ["first", "second"], ["--arch", "arm64"]] do
      assert_raise Mix.Error, ~r/Usage: mix tailscaled\.install DESTINATION/, fn ->
        Install.run(args)
      end
    end

    assert_raise Mix.Error, ~r/Unsupported archive/, fn ->
      Install.run(["rootfs_overlay/usr/sbin/tailscaled", "--arch", "bad"])
    end
  end

  test "requires explicit version and checksum together, and validates both", %{tmp_dir: dir} do
    for opts <- [
          [version: "1.2.3"],
          [sha256: String.duplicate("0", 64)],
          [version: "latest", sha256: String.duplicate("0", 64)],
          [version: "../../1.2.3", sha256: String.duplicate("0", 64)],
          [version: "1.2.3", sha256: "bad"]
        ] do
      assert_raise ArgumentError, fn ->
        Installer.install!(Path.join(dir, "tailscaled"), [arch: "arm64"] ++ opts)
      end
    end

    assert File.ls!(dir) == []
  end

  test "installs only the verified daemon and leaves an identical destination untouched", %{
    tmp_dir: dir
  } do
    archive = archive!(dir, "arm64")
    opts = options(dir, archive, "arm64")
    destination = Path.join(dir, "overlay/usr/sbin/tailscaled")
    other_target = Path.join(dir, "host-tailscaled")
    File.write!(other_target, "host binary")

    assert :ok = Installer.install!(destination, opts)
    assert File.read!(destination) == "target binary"
    assert Bitwise.band(File.stat!(destination).mode, 0o777) == 0o755
    assert File.ls!(Path.dirname(destination)) == ["tailscaled"]
    assert File.read!(other_target) == "host binary"

    File.touch!(destination, {{2000, 1, 1}, {0, 0, 0}})
    before = File.stat!(destination)
    assert :ok = Installer.install!(destination, offline(opts))
    assert File.stat!(destination).mtime == before.mtime
    assert File.stat!(destination).inode == before.inode

    File.chmod!(destination, 0o644)
    assert :ok = Installer.install!(destination, offline(opts))
    assert File.stat!(destination).inode == before.inode
    assert Bitwise.band(File.stat!(destination).mode, 0o777) == 0o755
  end

  test "cached archive installs a new destination offline without any download", %{tmp_dir: dir} do
    opts = options(dir, archive!(dir, "arm64"), "arm64")
    assert :ok = Installer.install!(Path.join(dir, "first"), opts)
    assert :ok = Installer.install!(Path.join(dir, "second"), offline(opts))
    assert File.read!(Path.join(dir, "second")) == "target binary"
    assert [_] = File.ls!(opts[:cache_dir])
  end

  test "missing or corrupt cache fails offline, and is repaired online", %{tmp_dir: dir} do
    destination = Path.join(dir, "tailscaled")
    File.write!(destination, "existing binary")
    opts = options(dir, archive!(dir, "arm64"), "arm64")

    assert_raise RuntimeError, ~r/checksum-verified cached archive.*offline/, fn ->
      Installer.install!(destination, offline(opts))
    end

    assert File.read!(destination) == "existing binary"
    assert :ok = Installer.install!(destination, opts)
    [cache] = Path.wildcard(Path.join(opts[:cache_dir], "*.tgz"))
    File.write!(cache, "corrupt archive")
    File.write!(destination, "existing binary")

    assert_raise RuntimeError, ~r/checksum-verified cached archive.*offline/, fn ->
      Installer.install!(destination, offline(opts))
    end

    assert File.read!(destination) == "existing binary"
    assert :ok = Installer.install!(destination, opts)
    assert :ok = Installer.install!(destination, offline(opts))
  end

  test "checksum failure preserves the destination and never caches the download", %{tmp_dir: dir} do
    destination = Path.join(dir, "tailscaled")
    File.write!(destination, "existing binary")
    opts = options(dir, archive!(dir, "amd64"), "amd64")
    opts = Keyword.put(opts, :sha256, String.duplicate("0", 64))

    assert_raise RuntimeError, ~r/SHA-256 mismatch/, fn ->
      Installer.install!(destination, opts)
    end

    assert File.read!(destination) == "existing binary"
    refute File.exists?(opts[:cache_dir])
    refute Enum.any?(File.ls!(dir), &String.ends_with?(&1, ".tmp"))
  end

  test "tested default uses its pinned checksum, not a downloaded checksum", %{tmp_dir: dir} do
    download = fn url ->
      assert url == "https://pkgs.tailscale.com/stable/tailscale_1.102.3_amd64.tgz"
      "untrusted archive"
    end

    assert_raise RuntimeError, ~r/SHA-256 mismatch/, fn ->
      Installer.install!(Path.join(dir, "tailscaled"),
        arch: "amd64",
        cache_dir: Path.join(dir, "cache"),
        download: download
      )
    end
  end

  test "wrong architecture or invalid archive cannot replace a binary", %{tmp_dir: dir} do
    destination = Path.join(dir, "tailscaled")
    File.write!(destination, "existing binary")

    for archive <- [archive!(dir, "arm"), "not a tar archive"] do
      assert_raise RuntimeError, ~r/Archive does not contain/, fn ->
        Installer.install!(destination, options(dir, archive, "amd64"))
      end

      assert File.read!(destination) == "existing binary"
    end
  end

  test "cache entries are isolated by architecture, version and checksum", %{tmp_dir: dir} do
    destination = Path.join(dir, "tailscaled")

    for {arch, version, binary} <- [
          {"arm64", @version, "one"},
          {"amd64", @version, "two"},
          {"arm64", "1.98.0", "three"},
          {"arm64", @version, "four"}
        ] do
      archive = archive!(dir, arch, version, binary)
      opts = options(dir, archive, arch, version)
      assert :ok = Installer.install!(destination, opts)
      assert File.read!(destination) == binary
    end

    assert [_, _, _, _] = File.ls!(Path.join(dir, "cache"))
  end

  test "source-preloaded task bootstraps a fresh target consumer without compiling deps", %{
    tmp_dir: dir
  } do
    opts = options(dir, archive!(dir, "arm64"), "arm64")
    Installer.install!(Path.join(dir, "warm-cache"), opts)
    consumer = Path.join(dir, "consumer")
    source = Path.join(consumer, "deps/tailscaled_ex/lib")
    File.mkdir_p!(Path.join(source, "mix/tasks"))
    File.mkdir_p!(Path.join(source, "tailscaled"))

    for file <- ["mix/tasks/tailscaled.install.ex", "tailscaled/installer.ex"] do
      File.cp!(Path.join("lib", file), Path.join(source, file))
    end

    File.write!(Path.join(consumer, "mix.exs"), """
    defmodule BootstrapConsumer.MixProject do
      use Mix.Project
      def project, do: [app: :bootstrap_consumer, version: "0.1.0",
        deps: [{:tailscaled_ex, path: "deps/tailscaled_ex"}]]
    end
    """)

    File.write!(
      Path.join(consumer, "deps/tailscaled_ex/mix.exs"),
      "raise \"Target dependencies must not be loaded or compiled\"\n"
    )

    args = [
      "-r",
      "deps/tailscaled_ex/lib/mix/tasks/tailscaled.install.ex",
      "-S",
      "mix",
      "tailscaled.install",
      "overlay/tailscaled",
      "--arch",
      "arm64",
      "--version",
      @version,
      "--sha256",
      opts[:sha256],
      "--cache-dir",
      opts[:cache_dir],
      "--offline"
    ]

    env = [
      {"MIX_TARGET", "custom"},
      {"REBAR_TARGET_ARCH", nil},
      {"MIX_BUILD_PATH", nil},
      {"MIX_ENV", "dev"},
      {"ERL_FLAGS", "+S 2:2"}
    ]

    {output, status} = System.cmd("elixir", args, cd: consumer, env: env, stderr_to_stdout: true)
    assert status == 0, output
    refute output =~ "warning:"
    assert File.read!(Path.join(consumer, "overlay/tailscaled")) == "target binary"
    refute File.exists?(Path.join(consumer, "_build"))

    args = List.delete(args, "--arch") |> List.delete("arm64")
    {output, status} = System.cmd("elixir", args, cd: consumer, env: env, stderr_to_stdout: true)
    assert status != 0
    assert output =~ "initialize the target toolchain or pass --arch explicitly"
    refute output =~ "Target dependencies must not be loaded"
  end

  defp archive!(directory, arch, version \\ @version, binary \\ "target binary") do
    path = Path.join(directory, "archive.tgz")
    prefix = "tailscale_#{version}_#{arch}"

    :ok =
      :erl_tar.create(
        String.to_charlist(path),
        [
          {String.to_charlist("#{prefix}/tailscaled"), binary},
          {String.to_charlist("#{prefix}/tailscale"), "unneeded CLI"},
          {~c"unrelated", "not extracted"}
        ],
        [:compressed]
      )

    File.read!(path)
  end

  defp options(dir, archive, arch, version \\ @version) do
    url = "https://pkgs.tailscale.com/stable/tailscale_#{version}_#{arch}.tgz"

    [
      arch: arch,
      version: version,
      sha256: Base.encode16(:crypto.hash(:sha256, archive), case: :upper),
      cache_dir: Path.join(dir, "cache"),
      download: fn ^url -> archive end
    ]
  end

  defp offline(opts) do
    opts
    |> Keyword.put(:offline, true)
    |> Keyword.put(:download, fn _ -> flunk("Offline installation must not download") end)
  end
end
