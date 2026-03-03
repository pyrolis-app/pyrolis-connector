defmodule PyrolisConnector do
  @moduledoc """
  Pyrolis on-premise connector relay agent.

  A lightweight agent installed at customer sites that maintains a WebSocket
  connection to the Pyrolis cloud, receives SQL queries, executes them on
  local databases (HFSQL/ODBC, MySQL, etc.), and streams results back.

  ## Architecture

      ┌──────────────────┐         ┌──────────────────────────┐
      │  Pyrolis Cloud   │  WSS    │  Customer On-Premise     │
      │                  │◄───────►│                          │
      │  Orchestrator    │         │  Relay (WebSocket)       │
      │  sends SQL query │         │    ↓                     │
      │  receives rows   │         │  DB module               │
      │  imports data    │         │    ├─ ODBC → HFSQL/SI2A  │
      │                  │         │    ├─ MyXQL → MySQL      │
      │                  │         │    └─ (extensible)       │
      └──────────────────┘         └──────────────────────────┘

  ## Quick start

      # 1. Configure cloud connection
      ./pyrolis-connector setup

      # 2. Add a data source
      ./pyrolis-connector add-source si2a odbc --dsn SI2A_HFSQL

      # 3. Start the connector
      ./pyrolis-connector start
  """

  @version Mix.Project.config()[:version]

  def version, do: @version

  @doc "Returns the port the web UI is listening on."
  def port do
    :persistent_term.get(:pyrolis_connector_port, 4100)
  end
end
