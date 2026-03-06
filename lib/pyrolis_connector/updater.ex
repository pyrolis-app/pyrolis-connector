defmodule PyrolisConnector.Updater do
  @moduledoc """
  Self-update manager for the Pyrolis Connector.

  Downloads new binary releases from GitHub, verifies their SHA-256 checksum,
  replaces the running binary, and restarts the application.

  ## Update flow

  1. Cloud pushes `"update_available"` via WebSocket (or user clicks "Check for updates")
  2. Updater downloads the new binary to a temp file
  3. Verifies the SHA-256 checksum
  4. Replaces the current binary (backup kept as `<binary>.bak`)
  5. Restarts the application via `System.restart/0`

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
    :checked_at
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
      pid -> GenServer.cast(pid, {:update_available, version, download_url, checksum})
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
    PyrolisConnector.State.get_setting("allow_remote_updates") != "false"
  end

  @doc "Enable or disable remote update pushes."
  def set_remote_updates(enabled) when is_boolean(enabled) do
    PyrolisConnector.State.save_setting("allow_remote_updates", to_string(enabled))
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
  def handle_cast({:update_available, version, download_url, checksum}, state) do
    current = PyrolisConnector.version()

    if newer_version?(version, current) do
      Logger.info("Update available: v#{version} (current: v#{current})")

      {:noreply,
       %{state | status: :available, available_version: version, download_url: download_url, checksum: checksum, error: nil}}
    else
      Logger.debug("Ignoring update v#{version}, already at v#{current}")
      {:noreply, state}
    end
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

    {:noreply, %{state | status: :downloading, error: nil}}
  end

  def handle_cast(:download, state) do
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
    {:noreply, %{state | status: :ready, download_path: path, error: nil}}
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

  defp check_github_releases do
    # Use GitHub API to get latest release
    api_url = String.replace(@github_releases_url, "github.com", "api.github.com/repos") <> "/latest"

    case Req.get(api_url, headers: [{"accept", "application/vnd.github+json"}, {"user-agent", "pyrolis-connector"}], receive_timeout: 15_000) do
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

    # Find the binary asset for our platform
    binary_asset =
      Enum.find(assets, fn a ->
        name = a["name"] || ""
        String.contains?(name, target) and not String.ends_with?(name, ".txt")
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
    case Req.get(checksums_asset["browser_download_url"], receive_timeout: 10_000) do
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

    case Req.get(url, into: File.stream!(tmp_path), receive_timeout: 300_000) do
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
    case current_binary_path() do
      {:burrito, bin_path} ->
        # In-place replacement of the single Burrito binary
        backup_path = bin_path <> ".bak"

        with :ok <- File.rename(bin_path, backup_path),
             :ok <- File.rename(download_path, bin_path),
             :ok <- make_executable(bin_path) do
          schedule_restart()
          :ok
        else
          {:error, reason} ->
            if File.exists?(backup_path) and not File.exists?(bin_path) do
              File.rename(backup_path, bin_path)
            end

            {:error, reason}
        end

      {:release, root} ->
        # Standard release: place the new binary next to the release root
        # so the user can switch to the standalone binary
        dest = Path.join(Path.dirname(root), "pyrolis-connector")
        backup = dest <> ".bak"

        if File.exists?(dest), do: File.rename(dest, backup)

        with :ok <- File.rename(download_path, dest),
             :ok <- make_executable(dest) do
          Logger.info("New binary placed at #{dest}")
          schedule_restart()
          :ok
        else
          {:error, reason} ->
            if File.exists?(backup) and not File.exists?(dest) do
              File.rename(backup, dest)
            end

            {:error, reason}
        end

      :unknown ->
        # Dev mode (mix run): just place the binary in cwd
        dest = Path.join(File.cwd!(), "pyrolis-connector")
        backup = dest <> ".bak"

        if File.exists?(dest), do: File.rename(dest, backup)

        with :ok <- File.rename(download_path, dest),
             :ok <- make_executable(dest) do
          Logger.info("New binary downloaded to #{dest}")
          Logger.info("Restart with: ./pyrolis-connector")
          :ok
        else
          {:error, reason} ->
            if File.exists?(backup) and not File.exists?(dest) do
              File.rename(backup, dest)
            end

            {:error, reason}
        end
    end
  end

  defp schedule_restart do
    Task.start(fn ->
      Process.sleep(1_000)

      case System.get_env("__BURRITO_BIN_PATH") do
        path when is_binary(path) ->
          # Re-exec the binary as a fresh OS process to avoid BEAM :low_entropy crash
          Logger.info("Re-launching #{path}...")
          Port.open({:spawn_executable, path}, [:binary, :exit_status, args: []])
          Process.sleep(500)
          System.halt(0)

        _ ->
          Logger.info("Restarting application...")
          System.restart()
      end
    end)
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

  defp current_binary_path do
    case System.get_env("__BURRITO_BIN_PATH") do
      path when is_binary(path) -> {:burrito, path}
      nil ->
        case System.get_env("RELEASE_ROOT") do
          root when is_binary(root) -> {:release, root}
          nil -> :unknown
        end
    end
  end

  defp make_executable(path) do
    case :os.type() do
      {:unix, _} -> File.chmod(path, 0o755)
      _ -> :ok
    end
  end

  defp platform_target do
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
