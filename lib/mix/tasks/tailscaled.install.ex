defmodule Mix.Tasks.Tailscaled.Install do
  use Mix.Task

  # The bootstrap command loads the implementation from source at runtime.
  @compile {:no_warn_undefined, Tailscaled.Installer}
  @shortdoc "Install a checksum-verified tailscaled binary"
  @moduledoc """
  Installs only `tailscaled`; never executes it or starts the daemon.
  Defaults to Tailscale 1.102.3 with pinned SHA-256 checksums.

      mix tailscaled.install ./bin/tailscaled
      MIX_TARGET=rpi4 mix tailscaled.install rootfs_overlay/usr/sbin/tailscaled
      mix tailscaled.install rootfs_overlay/usr/sbin/tailscaled --arch arm64

  The required destination is the full binary filename. Replacement is atomic;
  identical contents are not rewritten. Use separate destinations per architecture.

  ## Bootstrap before target dependencies compile

  Mix normally compiles dependencies to discover their tasks. With dependencies
  already fetched, preload this task from source to bypass that discovery:

      elixir -r deps/tailscaled_ex/lib/mix/tasks/tailscaled.install.ex -S mix tailscaled.install \\
        rootfs_overlay/usr/sbin/tailscaled --arch arm64

  No target toolchain is needed with `--arch`. Without it, host builds use the VM's
  Linux architecture; Nerves builds require `REBAR_TARGET_ARCH` from the initialized
  toolchain. Unknown targets fail rather than falling back to the build host.

  ## Options

    * `--arch` — explicit Linux archive architecture (see `Tailscaled.Installer`).
    * `--version` and `--sha256` — explicit stable version and expected archive
      SHA-256; supply both. No implicit latest version or checksum lookup.
    * `--cache-dir` — override the OS user archive cache directory.
    * `--offline` — use only checksum-verified cached archives, with no network.

  Version overrides do not imply library compatibility. Configure `:tailscaled_ex,
  :daemon_path` with the installed binary's path on the running device.
  Elixir setup scripts can call `Tailscaled.Installer.install!/2` directly.
  """

  @impl true
  def run(args) do
    {opts, rest} =
      OptionParser.parse!(args,
        strict: [
          arch: :string,
          version: :string,
          sha256: :string,
          cache_dir: :string,
          offline: :boolean
        ]
      )

    destination =
      case rest do
        [path] when path != "" -> path
        _ -> Mix.raise("Usage: mix tailscaled.install DESTINATION [OPTIONS]")
      end

    # Also supports the source-preload bootstrap command, before any dependency build.
    unless Code.ensure_loaded?(Tailscaled.Installer),
      do: Code.require_file("../../tailscaled/installer.ex", __DIR__)

    arch =
      opts[:arch] ||
        Tailscaled.Installer.architecture!(
          Mix.target(),
          System.get_env("REBAR_TARGET_ARCH"),
          to_string(:erlang.system_info(:system_architecture))
        )

    :ok = Tailscaled.Installer.install!(destination, Keyword.put(opts, :arch, arch))
    Mix.shell().info("Installed tailscaled (#{arch}) at #{destination}")
  rescue
    error in [ArgumentError, RuntimeError, File.Error] -> Mix.raise(Exception.message(error))
  end
end
