defmodule PyrolisConnector.Config do
  @moduledoc """
  Runtime configuration for the connector.

  Configuration is stored in SQLite and loaded at startup.

  ## Cloud connection config (stored in SQLite config table)

    - `url`           — Tenant URL (e.g., "https://my-company.pyrolis.fr")
    - `api_key`       — API key for authentication
    - `connector_id`  — Unique connector identifier

  ## Data sources (stored in SQLite data_sources table)

  Each data source has a name, type, and connection params.
  See `PyrolisConnector.State` for the data source API.
  """

  @type t :: %__MODULE__{
          url: String.t(),
          api_key: String.t(),
          connector_id: String.t()
        }

  defstruct [
    :url,
    :api_key,
    :connector_id
  ]

  @doc "Load cloud connection config from the state store."
  def load do
    case PyrolisConnector.State.get_config() do
      {:ok, config_map} -> {:ok, struct(__MODULE__, config_map)}
      {:error, :not_configured} -> {:error, :not_configured}
    end
  end

  @doc "Save cloud connection config to the state store."
  def save(%__MODULE__{} = config) do
    config
    |> Map.from_struct()
    |> PyrolisConnector.State.save_config()
  end

  @doc "Check if the connector is configured."
  def configured? do
    match?({:ok, _}, load())
  end

  @doc "Build the WebSocket URL for connecting to the cloud."
  def ws_url(%__MODULE__{url: url, api_key: key}) do
    uri = URI.parse(url)

    scheme = if uri.scheme == "https", do: "wss", else: "ws"
    host = uri.host
    port = uri.port

    port_str =
      case {scheme, port} do
        {"wss", 443} -> ""
        {"ws", 80} -> ""
        {_, nil} -> ""
        {_, p} -> ":#{p}"
      end

    "#{scheme}://#{host}#{port_str}/connector/websocket?api_key=#{URI.encode_www_form(key)}"
  end
end
