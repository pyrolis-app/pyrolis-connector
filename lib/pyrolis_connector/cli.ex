defmodule PyrolisConnector.CLI do
  @moduledoc """
  CLI fallback for headless environments.

  The primary UI is the web interface at http://localhost:4100.
  These CLI commands are available for scripted/headless setups.

  ## Commands

      ./pyrolis-connector                   # Start (opens web UI if not configured)
      ./pyrolis-connector setup             # Opens setup page in browser
      ./pyrolis-connector help              # Show help
  """

  def run(["help"]) do
    IO.puts("""

    Pyrolis Connector v#{PyrolisConnector.version()}

    Usage:
      ./pyrolis-connector              Start the connector (default)
      ./pyrolis-connector setup        Open setup in browser
      ./pyrolis-connector help         Show this help

    The web management UI runs at http://localhost:4100
    """)

    :halt
  end

  def run(["setup"]), do: :continue
  def run(["start"]), do: :continue
  def run([]), do: :continue

  def run(unknown) do
    IO.puts("Unknown command: #{Enum.join(unknown, " ")}")
    IO.puts("Run: ./pyrolis-connector help")
    :halt
  end
end
