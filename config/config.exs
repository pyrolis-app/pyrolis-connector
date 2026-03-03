import Config

config :pyrolis_connector,
  web_port: 4100,
  state_db_path: "priv/state.db"

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:connector_id, :resource_type]
