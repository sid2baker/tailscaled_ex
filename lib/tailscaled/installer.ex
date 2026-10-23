defmodule Tailscaled.Installer do
  @moduledoc """
  Downloads and installs `tailscaled`, without compiling dependencies, executing the
  downloaded binary, or starting the Tailscaled application. Uses only Elixir and OTP.

      Tailscaled.Installer.install!("rootfs_overlay/usr/sbin/tailscaled", arch: "arm64")

  The default is Tailscale 1.102.3 with pinned archive checksums. To install another
  stable version, supply both `:version` and its expected archive `:sha256`.
  An override is a firmware pin, not a claim of library compatibility.

  Archives are cached under the OS user cache directory for `tailscaled_ex`.
  Every use verifies the checksum, including offline use. An identical destination
  is not rewritten; its permissions are corrected to 0755 if necessary.
  """

  @version "1.102.3"
  @checksums %{
    "386" => "e613246f7496e6a87a9015666417e1e474a2f9263b47e09e4ca31d34f02ddd18",
    "amd64" => "36ddd9b51be57ffc2990cf76323cfa13643bfbb1b8a969f6183fa164741cdef5",
    "arm" => "568dffd398fa70698de3671a05f078dc29fef62b1daf248ef1f45f82fc3dc75d",
    "arm64" => "a0fa1b154af8c61f862a2259f559f7396d96c0225f4a863eae2333e1546bbe25",
    "geode" => "ca28631745376910f701ae4eb41f7d85552e28ae982cefced25d4720b6075a20",
    "mips" => "2f8c82392c7439f06e723999e398ba8a35908bdd84efcb5aee3648c24f8792d2",
    "mipsle" => "1293f8e87480b25ee4d9e57f16a488cad6d8be863cf8185325d17f795eaaec44",
    "mips64" => "53cba57b1d2af025e9bb4412868168c603871acbbb3584c0793e259de0433e9f",
    "mips64le" => "769852c83e91ab27ea91e68b76b0473d41ecd12218b5ae3d7f2d11c6ee07b8d9",
    "riscv64" => "06989538da8f4cb773a43a039e3477caf5c028ba66ff7eaa9809eef37e06654d"
  }

  @doc """
  Install only the daemon at the explicit destination. Returns `:ok` or raises.

  Options:

    * `:arch` — required archive architecture: `386`, `amd64`, `arm`, `arm64`,
      `geode`, `mips`, `mipsle`, `mips64`, `mips64le`, or `riscv64`.
    * `:version` and `:sha256` — override the tested default; both are required.
      The checksum is the 64-digit SHA-256 of the compressed archive.
    * `:cache_dir` — archive cache directory; defaults to the OS user cache.
    * `:offline` — use only a verified cached archive; defaults to `false`.
  """
  @spec install!(Path.t(), keyword()) :: :ok
  def install!(destination, opts) do
    if destination == "", do: raise(ArgumentError, "Destination must not be empty")
    arch = Keyword.fetch!(opts, :arch)

    unless Map.has_key?(@checksums, arch),
      do: raise(ArgumentError, "Unsupported archive architecture: #{arch}")

    {version, checksum} = pin!(opts, arch)
    name = "tailscale_#{version}_#{arch}"
    cache_dir = Keyword.get_lazy(opts, :cache_dir, &default_cache_dir/0)
    cache = Path.join(cache_dir, "#{name}-#{checksum}.tgz")
    archive = archive!(cache, name, checksum, opts)
    member = String.to_charlist("#{name}/tailscaled")

    case :erl_tar.extract({:binary, archive}, [:compressed, :memory, files: [member]]) do
      {:ok, [{^member, binary}]} -> install_binary!(destination, binary)
      _ -> raise "Archive does not contain #{name}/tailscaled"
    end
  end

  @doc false
  def architecture!(target, target_arch, host_arch) do
    triple = if target == :host, do: host_arch, else: target_arch

    unless is_binary(triple) and String.contains?(triple, "-linux") do
      raise ArgumentError,
            "Cannot determine a Linux architecture for #{target}; " <>
              "initialize the target toolchain or pass --arch explicitly"
    end

    archive_architecture!(triple |> String.split("-") |> hd())
  end

  defp archive_architecture!(cpu) do
    case cpu do
      "x86_64" ->
        "amd64"

      "aarch64" ->
        "arm64"

      arm when arm in ~w(arm armv5te armv5tel armv6 armv6l armv7 armv7l armv7a armv8l) ->
        "arm"

      "i686" ->
        "386"

      "riscv64" ->
        "riscv64"

      other ->
        raise ArgumentError, "Unsupported target architecture #{other}; pass --arch explicitly"
    end
  end

  defp pin!(opts, arch) do
    case {Keyword.fetch(opts, :version), Keyword.fetch(opts, :sha256)} do
      {:error, :error} ->
        {@version, Map.fetch!(@checksums, arch)}

      {{:ok, version}, {:ok, checksum}} ->
        unless is_binary(version) and Regex.match?(~r/\A\d+\.\d+\.\d+\z/, version),
          do: raise(ArgumentError, "Version must be an explicit stable version, not latest")

        unless is_binary(checksum) and Regex.match?(~r/\A[0-9a-fA-F]{64}\z/, checksum),
          do: raise(ArgumentError, "SHA-256 must be 64 hexadecimal digits")

        {version, String.downcase(checksum)}

      _ ->
        raise ArgumentError, "Supply both version and sha256 to override the tested default"
    end
  end

  defp default_cache_dir do
    :filename.basedir(:user_cache, "tailscaled_ex") |> Path.join("archives")
  end

  defp archive!(cache, name, checksum, opts) do
    cached = File.read(cache)

    if match?({:ok, _}, cached) and verified?(elem(cached, 1), checksum) do
      elem(cached, 1)
    else
      if Keyword.get(opts, :offline, false),
        do: raise("No checksum-verified cached archive for #{name}.tgz (offline)")

      download = Keyword.get(opts, :download, &download!/1)
      archive = download.("https://pkgs.tailscale.com/stable/#{name}.tgz")
      unless verified?(archive, checksum), do: raise("SHA-256 mismatch for #{name}.tgz")
      write_atomic!(cache, archive, 0o644)
      archive
    end
  end

  defp verified?(archive, checksum) do
    Base.encode16(:crypto.hash(:sha256, archive), case: :lower) == checksum
  end

  defp download!(url) do
    {:ok, _} = Application.ensure_all_started([:inets, :ssl])

    ssl = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]

    options = [ssl: ssl, timeout: 120_000, connect_timeout: 20_000, autoredirect: false]

    case :httpc.request(:get, {String.to_charlist(url), []}, options, body_format: :binary) do
      {:ok, {{_, 200, _}, _, body}} -> body
      _ -> raise "Could not download #{url}"
    end
  end

  defp install_binary!(destination, binary) do
    if File.read(destination) == {:ok, binary} do
      unless Bitwise.band(File.stat!(destination).mode, 0o777) == 0o755,
        do: File.chmod!(destination, 0o755)

      :ok
    else
      write_atomic!(destination, binary, 0o755)
    end
  end

  defp write_atomic!(destination, binary, mode) do
    File.mkdir_p!(Path.dirname(destination))
    temporary = destination <> ".#{System.pid()}.#{System.unique_integer([:positive])}.tmp"

    try do
      File.write!(temporary, binary, [:exclusive])
      File.chmod!(temporary, mode)
      File.rename!(temporary, destination)
    after
      File.rm(temporary)
    end
  end
end
