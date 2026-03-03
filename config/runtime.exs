import Config

if port = System.get_env("PYROLIS_CONNECTOR_PORT") do
  config :pyrolis_connector, web_port: String.to_integer(port)
end

if db_path = System.get_env("PYROLIS_STATE_DB") do
  config :pyrolis_connector, state_db_path: db_path
end
