defmodule PyrolisConnector.Updater do
  @moduledoc """
  Self-update manager for the Pyrolis Connector.

  Downloads new release zips from GitHub, verifies their SHA-256 checksum,
  extracts over the release directory, and restarts.

  ## Update flow

  1. Cloud pushes `"update_available"` via WebSocket (or user clicks "Check for updates")
  2. Updater downloads the release zip to a temp file
  3. Verifies the SHA-256 checksum
  4. Extracts the zip over the release directory (`RELEASE_ROOT`)
  5. Restarts via the release script (or `System.restart/0`)

  ## State

  The updater tracks its current status as one of:
  - `:idle` — No update activity
  - `:available` — Update available, not yet downloading
  - `:downloading` — Download in progress
  - `:ready` — Downloaded and verified, ready to apply
  - `:applying` — Replacing binary and restarting
  - `:error` — Something went wrong (see `error` field)
  """

  use GenServer

  require Logger

  @github_releases_url "https://github.com/pyrolis-app/pyrolis-connector/releases"
  @check_interval_ms :timer.hours(6)

  defstruct [
    :status,
    :available_version,
    :download_url,
    :checksum,
    :download_path,
    :error,
    :checked_at,
    auto_apply: false
  ]

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the current update status."
  def status do
    case Process.whereis(__MODULE__) do
      nil -> %__MODULE__{status: :idle}
      pid ->
        try do
          GenServer.call(pid, :status, 5_000)
        catch
          :exit, _ -> %__MODULE__{status: :idle}
        end
    end
  end

  @doc "Notify the updater that a new version is available (from cloud push)."
  def notify_available(version, download_url, checksum) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:update_available, version, download_url, checksum, :remote})
    end
  end

  @doc "Check GitHub releases for a newer version."
  def check_now do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :not_running}
      pid -> GenServer.cast(pid, :check_github)
    end
  end

  @doc "Download the available update."
  def download do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :not_running}
      pid -> GenServer.cast(pid, :download)
    end
  end

  @doc "Apply a downloaded update (replace binary + restart)."
  def apply_update do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :not_running}
      pid -> GenServer.cast(pid, :apply_update)
    end
  end

  @doc "Check if remote (cloud-pushed) updates are allowed."
  def remote_updates_allowed? do
    case PyrolisConnector.State.get_setting("allow_remote_updates") do
      {:ok, "false"} -> false
      _ -> true
    end
  end

  @doc "Enable or disable remote update pushes."
  def set_remote_updates(enabled) when is_boolean(enabled) do
    PyrolisConnector.State.save_setting("allow_remote_updates", to_string(enabled))
  end

  @doc """
  Get the auto-apply mode for cloud-pushed updates.

  - `"auto"` — download and apply automatically (default)
  - `"download"` — download automatically, wait for manual apply
  - `"manual"` — only notify, user must download and apply manually
  """
  def auto_apply_mode do
    case PyrolisConnector.State.get_setting("auto_apply_mode") do
      {:ok, mode} when mode in ~w(auto download manual) -> mode
      _ -> "auto"
    end
  end

  @doc "Set the auto-apply mode."
  def set_auto_apply_mode(mode) when mode in ~w(auto download manual) do
    PyrolisConnector.State.save_setting("auto_apply_mode", mode)
  end

  @doc "Dismiss the current update notification."
  def dismiss do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.cast(pid, :dismiss)
    end
  end

  # Server

  @impl true
  def init(_opts) do
    # Schedule periodic check
    Process.send_after(self(), :periodic_check, @check_interval_ms)

    {:ok, %__MODULE__{status: :idle}}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_cast({:update_available, version, download_url, checksum, source}, state) do
    current = PyrolisConnector.version()

    if newer_version?(version, current) do
      Logger.info("Update available: v#{version} (current: v#{current})")

      new_state =
        %{state | status: :available, available_version: version, download_url: download_url, checksum: checksum, error: nil}

      # Auto-act on remote pushes based on configured mode
      mode = auto_apply_mode()
      Logger.info("Update source: #{source}, auto_apply_mode: #{mode}")

      if source == :remote do
        case mode do
          "auto" ->
            Logger.info("Auto-install: starting download and apply")
            GenServer.cast(self(), :download_and_apply)

          "download" ->
            Logger.info("Auto-download: starting download")
            GenServer.cast(self(), :download)

          _ ->
            Logger.info("Manual mode: waiting for user action")
        end
      end

      {:noreply, new_state}
    else
      Logger.debug("Ignoring update v#{version}, already at v#{current}")
      {:noreply, state}
    end
  end

  # Legacy clause for local checks (no source)
  def handle_cast({:update_available, version, download_url, checksum}, state) do
    handle_cast({:update_available, version, download_url, checksum, :local}, state)
  end

  def handle_cast(:check_github, state) do
    me = self()

    Task.start(fn ->
      result = check_github_releases()
      send(me, {:github_check_result, result})
    end)

    {:noreply, %{state | checked_at: DateTime.utc_now()}}
  end

  def handle_cast(:download, %{status: :available, download_url: url} = state) when is_binary(url) do
    me = self()
    Logger.info("Starting download from #{url}")

    Task.start(fn ->
      result = download_binary(url)
      send(me, {:download_result, result})
    end)

    {:noreply, %{state | status: :downloading, error: nil, auto_apply: false}}
  end

  def handle_cast(:download, state) do
    {:noreply, state}

  end

  def handle_cast(:download_and_apply, %{status: :available, download_url: url} = state) when is_binary(url) do
    me = self()
    Logger.info("Starting download from #{url} (will auto-apply)")

    Task.start(fn ->
      result = download_binary(url)
      send(me, {:download_result, result})
    end)

    {:noreply, %{state | status: :downloading, error: nil, auto_apply: true}}
  end

  def handle_cast(:download_and_apply, state) do
    {:noreply, state}
  end

  def handle_cast(:apply_update, %{status: :ready, download_path: path} = state) when is_binary(path) do
    Logger.info("Applying update from #{path}")

    case apply_binary_update(path, state.checksum) do
      :ok ->
        Logger.info("Update applied successfully, restarting...")
        {:noreply, %{state | status: :applying}}

      {:error, reason} ->
        Logger.error("Failed to apply update: #{inspect(reason)}")
        {:noreply, %{state | status: :error, error: to_string(reason)}}
    end
  end

  def handle_cast(:apply_update, state) do
    {:noreply, state}
  end

  def handle_cast(:dismiss, state) do
    # Clean up any downloaded file
    if state.download_path, do: File.rm(state.download_path)

    {:noreply, %__MODULE__{status: :idle, checked_at: state.checked_at}}
  end

  @impl true
  def handle_info({:github_check_result, {:ok, version, download_url, checksum}}, state) do
    current = PyrolisConnector.version()

    if newer_version?(version, current) do
      Logger.info("GitHub check: update available v#{version} (current: v#{current})")

      {:noreply,
       %{state | status: :available, available_version: version, download_url: download_url, checksum: checksum, error: nil}}
    else
      Logger.debug("GitHub check: already up to date (v#{current})")
      {:noreply, %{state | status: :idle, error: nil}}
    end
  end

  def handle_info({:github_check_result, {:error, reason}}, state) do
    Logger.warning("GitHub update check failed: #{inspect(reason)}")
    {:noreply, %{state | error: "Check failed: #{reason}"}}
  end

  def handle_info({:download_result, {:ok, path}}, state) do
    Logger.info("Download complete: #{path}")
    new_state = %{state | status: :ready, download_path: path, error: nil}

    if state.auto_apply do
      Logger.info("Auto-applying update...")
      GenServer.cast(self(), :apply_update)
    end

    {:noreply, new_state}
  end

  def handle_info({:download_result, {:error, reason}}, state) do
    Logger.error("Download failed: #{inspect(reason)}")
    {:noreply, %{state | status: :error, error: "Download failed: #{reason}"}}
  end

  def handle_info(:periodic_check, state) do
    # Only auto-check if idle (not mid-update)
    if state.status == :idle do
      GenServer.cast(self(), :check_github)
    end

    Process.send_after(self(), :periodic_check, @check_interval_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Private helpers

  defp req_options(extra) do
    # Explicitly pass bundled CA certs for environments where auto-detection fails
    [connect_options: [transport_opts: [cacertfile: CAStore.file_path()]]] ++ extra
  end

  defp check_github_releases do
    # Use GitHub API to get latest release
    api_url = String.replace(@github_releases_url, "github.com", "api.github.com/repos") <> "/latest"

    case Req.get(api_url, req_options(headers: [{"accept", "application/vnd.github+json"}, {"user-agent", "pyrolis-connector"}], receive_timeout: 15_000)) do
      {:ok, %{status: 200, body: body}} ->
        parse_github_release(body)

      {:ok, %{status: status}} ->
        {:error, "GitHub API returned #{status}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp parse_github_release(body) do
    tag = body["tag_name"] || ""
    version = String.replace(tag, ~r/^pyrolis-connector-v/, "")

    target = platform_target()
    assets = body["assets"] || []

    # Find the release zip for our platform
    binary_asset =
      Enum.find(assets, fn a ->
        name = a["name"] || ""
        String.contains?(name, target) and String.ends_with?(name, ".zip")
      end)

    # Find SHA256SUMS.txt
    checksums_asset = Enum.find(assets, fn a -> a["name"] == "SHA256SUMS.txt" end)

    case binary_asset do
      nil ->
        {:error, "No binary found for platform #{target}"}

      asset ->
        checksum = fetch_checksum(checksums_asset, asset["name"])
        {:ok, version, asset["browser_download_url"], checksum}
    end
  end

  defp fetch_checksum(nil, _filename), do: nil

  defp fetch_checksum(checksums_asset, filename) do
    case Req.get(checksums_asset["browser_download_url"], req_options(receive_timeout: 10_000)) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        body
        |> String.split("\n")
        |> Enum.find_value(fn line ->
          case String.split(line, ~r/\s+/, parts: 2) do
            [hash, ^filename] -> "sha256:#{hash}"
            _ -> nil
          end
        end)

      _ ->
        nil
    end
  end

  defp download_binary(url) do
    tmp_dir = System.tmp_dir!()
    tmp_path = Path.join(tmp_dir, "pyrolis-connector-update-#{:erlang.unique_integer([:positive])}")

    case Req.get(url, req_options(into: File.stream!(tmp_path), receive_timeout: 300_000)) do
      {:ok, %{status: 200}} ->
        {:ok, tmp_path}

      {:ok, %{status: status}} ->
        File.rm(tmp_path)
        {:error, "Download returned HTTP #{status}"}

      {:error, reason} ->
        File.rm(tmp_path)
        {:error, inspect(reason)}
    end
  end

  defp apply_binary_update(download_path, expected_checksum) do
    # Verify checksum if provided
    checksum_ok =
      if expected_checksum do
        verify_checksum(download_path, expected_checksum)
      else
        :ok
      end

    case checksum_ok do
      {:error, _} = err ->
        return_and_cleanup(err, download_path)

      :ok ->
        apply_verified_binary(download_path)
    end
  end

  defp apply_verified_binary(download_path) do
    case release_root() do
      {:ok, root} ->
        # Can't overwrite running ERTS binaries (:etxtbsy on Linux).
        # Extract zip to a staging dir, then use a shell script to
        # swap directories and relaunch after this process exits.
        parent = Path.dirname(root)
        staging = Path.join(parent, "pyrolis_connector_staging")

        if File.exists?(staging), do: File.rm_rf!(staging)
        File.mkdir_p!(staging)

        Logger.info("Extracting update to staging dir: #{staging}")

        case :zip.unzip(String.to_charlist(download_path), [{:cwd, String.to_charlist(staging)}]) do
          {:ok, _files} ->
            File.rm(download_path)
            new_root = Path.join(staging, "pyrolis_connector")

            if File.exists?(new_root) do
              schedule_swap_and_restart(root, new_root, staging)
              :ok
            else
              Logger.error("Expected pyrolis_connector/ in zip but not found in #{staging}")
              File.rm_rf!(staging)
              {:error, "Invalid release zip structure"}
            end

          {:error, reason} ->
            Logger.error("Failed to extract update: #{inspect(reason)}")
            File.rm(download_path)
            File.rm_rf!(staging)
            {:error, "Extract failed: #{inspect(reason)}"}
        end

      :unknown ->
        Logger.info("Update downloaded to #{download_path}")
        Logger.info("Not running as a release — please update manually")
        {:error, "Cannot auto-update in dev mode"}
    end
  end

  # Writes a small script that swaps old release dir with new one, then launches.
  # This runs after System.halt(0) so the ERTS binaries are no longer locked.
  defp schedule_swap_and_restart(current_root, new_root, staging_dir) do
    case :os.type() do
      {:unix, _} ->
        backup = current_root <> ".bak"
        script_path = Path.join(Path.dirname(current_root), ".pyrolis_update.sh")

        script = """
        #!/bin/sh
        sleep 2
        rm -rf "#{backup}"
        mv "#{current_root}" "#{backup}"
        mv "#{new_root}" "#{current_root}"
        rm -rf "#{staging_dir}"
        chmod +x "#{current_root}/bin/pyrolis_connector"
        chmod +x "#{current_root}"/erts-*/bin/*
        "#{current_root}/bin/pyrolis_connector" daemon
        rm -f "#{script_path}"
        """

        File.write!(script_path, script)
        File.chmod!(script_path, 0o755)

        Logger.info("Launching update script, halting current process...")

        Task.start(fn ->
          Process.sleep(500)
          Port.open({:spawn_executable, String.to_charlist(script_path)}, [:binary, :exit_status])
          Process.sleep(500)
          System.halt(0)
        end)

      {:win32, _} ->
        backup = current_root <> ".bak"
        script_path = Path.join(Path.dirname(current_root), "pyrolis_update.bat")

        script = """
        @echo off
        timeout /t 3 /nobreak >nul
        if exist "#{backup}" rmdir /s /q "#{backup}"
        move "#{current_root}" "#{backup}"
        move "#{new_root}" "#{current_root}"
        rmdir /s /q "#{staging_dir}"
        start "" "#{current_root}\\bin\\pyrolis_connector.bat" start
        del /f "%~f0"
        """

        File.write!(script_path, script)

        Logger.info("Launching update script, halting current process...")

        Task.start(fn ->
          Process.sleep(500)
          System.cmd("cmd", ["/c", "start", "/b", "", script_path], stderr_to_stdout: true)
          Process.sleep(500)
          System.halt(0)
        end)
    end
  end

  defp return_and_cleanup({:error, _} = err, path) do
    File.rm(path)
    err
  end

  defp verify_checksum(path, "sha256:" <> expected_hex) do
    actual_hex =
      File.stream!(path, 65_536)
      |> Enum.reduce(:crypto.hash_init(:sha256), fn chunk, acc ->
        :crypto.hash_update(acc, chunk)
      end)
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    if actual_hex == String.downcase(expected_hex) do
      :ok
    else
      {:error, "Checksum mismatch: expected #{expected_hex}, got #{actual_hex}"}
    end
  end

  defp verify_checksum(_path, _other), do: :ok

  defp release_root do
    case System.get_env("RELEASE_ROOT") do
      root when is_binary(root) -> {:ok, root}
      nil -> :unknown
    end
  end

  @doc "Returns the platform identifier for asset matching."
  def platform_target do
    case :os.type() do
      {:win32, _} -> "windows"
      {:unix, :darwin} -> "darwin"
      {:unix, _} -> "linux"
    end
  end

  @doc false
  def newer_version?(available, current) do
    case {parse_version(available), parse_version(current)} do
      {{:ok, av}, {:ok, cv}} -> Version.compare(av, cv) == :gt
      _ -> false
    end
  end

  defp parse_version(v) do
    # Handle versions like "0.3.0-4-gabcdef" from git describe
    clean =
      v
      |> String.trim()
      |> String.replace(~r/-\d+-g[0-9a-f]+$/, "")

    Version.parse(clean)
  end
end
