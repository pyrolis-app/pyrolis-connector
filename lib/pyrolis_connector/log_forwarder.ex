defmodule PyrolisConnector.LogForwarder do
  @moduledoc """
  Erlang :logger handler that forwards log messages to the cloud relay.

  When enabled, captures log events and sends them in batches to the
  cloud via the WebSocket relay. Can be toggled from the cloud dashboard
  or the local web UI.
  """

  require Logger

  @handler_id :pyrolis_log_forwarder
  @flush_interval_ms 1_000
  @max_buffer 100

  # Client API

  def enabled? do
    case :logger.get_handler_config(@handler_id) do
      {:ok, _} -> true
      _ -> false
    end
  end

  def enable do
    if not enabled?() do
      :logger.add_handler(@handler_id, __MODULE__, %{
        level: :info,
        config: %{}
      })

      # Start the flush timer
      case Process.whereis(__MODULE__.Flusher) do
        nil -> start_flusher()
        _ -> :ok
      end

      :ok
    else
      :ok
    end
  end

  def disable do
    :logger.remove_handler(@handler_id)
    :ok
  rescue
    _ -> :ok
  end

  def toggle do
    if enabled?(), do: disable(), else: enable()
  end

  # :logger handler callbacks

  def log(%{level: level, msg: msg, meta: meta}, _config) do
    formatted =
      case msg do
        {:string, str} -> IO.iodata_to_binary(str)
        {:report, report} -> inspect(report)
        {fmt, args} -> :io_lib.format(fmt, args) |> IO.iodata_to_binary()
      end

    entry = %{
      level: level,
      message: formatted,
      module: meta[:mfa] |> format_mfa(),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    buffer_log(entry)
  end

  def adding_handler(config), do: {:ok, config}
  def removing_handler(_config), do: :ok
  def changing_config(_action, _old, new), do: {:ok, new}

  # Buffer management via process dictionary on the flusher process

  defp buffer_log(entry) do
    case Process.whereis(__MODULE__.Flusher) do
      nil -> :ok
      pid -> send(pid, {:log, entry})
    end
  end

  defp start_flusher do
    pid =
      spawn(fn ->
        Process.register(self(), __MODULE__.Flusher)
        flusher_loop([])
      end)

    pid
  end

  defp flusher_loop(buffer) do
    receive do
      {:log, entry} ->
        new_buffer = [entry | buffer]

        if length(new_buffer) >= @max_buffer do
          flush(Enum.reverse(new_buffer))
          flusher_loop([])
        else
          flusher_loop(new_buffer)
        end

      :flush ->
        if buffer != [] do
          flush(Enum.reverse(buffer))
        end

        flusher_loop([])

      :stop ->
        if buffer != [] do
          flush(Enum.reverse(buffer))
        end

        :ok
    after
      @flush_interval_ms ->
        if buffer != [] do
          flush(Enum.reverse(buffer))
        end

        flusher_loop([])
    end
  end

  defp flush(entries) do
    PyrolisConnector.Relay.push_logs(entries)
  end

  defp format_mfa(nil), do: nil

  defp format_mfa({mod, fun, arity}) do
    "#{inspect(mod)}.#{fun}/#{arity}"
  end

  defp format_mfa(_), do: nil
end
