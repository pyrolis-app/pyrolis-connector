import Config

config :pyrolis_connector,
  cloud_url: System.get_env("PYROLIS_CLOUD_URL", "https://app.pyrolis.fr"),
  web_port: String.to_integer(System.get_env("PYROLIS_CONNECTOR_PORT", "4100")),
  state_db_path: System.get_env("PYROLIS_STATE_DB", "priv/state.db")

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:connector_id, :resource_type]
