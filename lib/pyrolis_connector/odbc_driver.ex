defmodule PyrolisConnector.OdbcDriver do
  @moduledoc """
  Detects installed ODBC drivers and available DSNs.

  Platform-specific detection:
  - **Windows**: queries the Windows Registry (HKLM\\SOFTWARE\\ODBC)
  - **Linux**: uses `odbcinst` from unixODBC
  """

  @doc """
  Returns a list of installed ODBC driver names.

      iex> PyrolisConnector.OdbcDriver.installed_drivers()
      ["HFSQL (64 bits)", "SQL Server", "MySQL ODBC 8.0 Driver"]
  """
  @spec installed_drivers() :: [String.t()]
  def installed_drivers do
    case :os.type() do
      {:win32, _} -> windows_drivers()
      {:unix, _} -> unix_drivers()
    end
  end

  @doc "Returns true if an HFSQL ODBC driver is detected."
  @spec hfsql_driver_installed?() :: boolean()
  def hfsql_driver_installed? do
    installed_drivers()
    |> Enum.any?(fn name -> String.contains?(String.downcase(name), "hfsql") end)
  end

  @doc """
  Returns a list of configured ODBC Data Source Names.

      iex> PyrolisConnector.OdbcDriver.available_dsns()
      ["SI2A_HFSQL", "CMMS_Production"]
  """
  @spec available_dsns() :: [String.t()]
  def available_dsns do
    case :os.type() do
      {:win32, _} -> windows_dsns()
      {:unix, _} -> unix_dsns()
    end
  end

  # ── Windows ──

  defp windows_drivers do
    case System.cmd("reg", ["query", "HKLM\\SOFTWARE\\ODBC\\ODBCINST.INI\\ODBC Drivers"],
           stderr_to_stdout: true
         ) do
      {output, 0} -> parse_reg_value_names(output)
      _ -> []
    end
  rescue
    _ -> []
  end

  defp windows_dsns do
    system = query_reg_dsns("HKLM\\SOFTWARE\\ODBC\\ODBC.INI\\ODBC Data Sources")
    user = query_reg_dsns("HKCU\\SOFTWARE\\ODBC\\ODBC.INI\\ODBC Data Sources")
    Enum.uniq(system ++ user)
  end

  defp query_reg_dsns(key) do
    case System.cmd("reg", ["query", key], stderr_to_stdout: true) do
      {output, 0} -> parse_reg_value_names(output)
      _ -> []
    end
  rescue
    _ -> []
  end

  # Registry output looks like:
  #   HKLM\SOFTWARE\ODBC\ODBCINST.INI\ODBC Drivers
  #       HFSQL (64 bits)    REG_SZ    Installed
  #       SQL Server         REG_SZ    Installed
  defp parse_reg_value_names(output) do
    output
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&String.contains?(&1, "REG_SZ"))
    |> Enum.map(fn line ->
      line
      |> String.split(~r/\s{2,}REG_SZ\s{2,}/)
      |> hd()
      |> String.trim()
    end)
    |> Enum.reject(&(&1 == ""))
  end

  # ── Linux / macOS ──

  defp unix_drivers do
    case System.cmd("odbcinst", ["-q", "-d"], stderr_to_stdout: true) do
      {output, 0} -> parse_odbcinst_output(output)
      _ -> []
    end
  rescue
    _ -> []
  end

  defp unix_dsns do
    case System.cmd("odbcinst", ["-q", "-s"], stderr_to_stdout: true) do
      {output, 0} -> parse_odbcinst_output(output)
      _ -> []
    end
  rescue
    _ -> []
  end

  # odbcinst output looks like:
  #   [HFSQL]
  #   [MySQL]
  defp parse_odbcinst_output(output) do
    output
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&String.starts_with?(&1, "["))
    |> Enum.map(fn line ->
      line |> String.trim_leading("[") |> String.trim_trailing("]")
    end)
    |> Enum.reject(&(&1 == ""))
  end
end
