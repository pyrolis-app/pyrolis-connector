defmodule PyrolisConnector.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Local state store (SQLite)
      PyrolisConnector.State,
      # Database connection manager (ODBC, MySQL, etc.)
      PyrolisConnector.DB,
      # WebSocket relay to Pyrolis cloud
      PyrolisConnector.Relay
    ]

    opts = [strategy: :one_for_one, name: PyrolisConnector.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
