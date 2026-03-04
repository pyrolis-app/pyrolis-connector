defmodule PyrolisConnector.MockData do
  @moduledoc """
  Generates realistic sample data for testing the relay import pipeline end-to-end.

  When a data source of type `"mock"` is configured, `PyrolisConnector.DB` delegates
  query execution here instead of connecting to a real database.

  Parses the SQL `FROM <table>` clause and returns matching sample data with the
  exact column names expected by the SI2A Import connectors.

  ## Setup

      # Via the web UI: add a data source with type "mock"
      # Or via State:
      PyrolisConnector.State.save_data_source("mock_si2a", "mock", %{"row_count" => "50"})

  The connector will then respond to cloud queries with sample data, letting you
  test the full import flow without needing a real HFSQL/ODBC connection.
  """

  @default_row_count 25

  @doc """
  Execute a mock query. Parses the table name from SQL and returns sample data.

  Returns `{:ok, columns, rows}` matching the `PyrolisConnector.DB` format.
  """
  def query(sql, config) do
    row_count = parse_row_count(config)
    table = parse_table(sql)
    {columns, rows} = generate(table, row_count)
    {:ok, columns, rows}
  end

  defp parse_row_count(config) do
    case Map.get(config, "row_count") do
      nil -> @default_row_count
      n when is_integer(n) -> n
      s when is_binary(s) -> String.to_integer(s)
    end
  rescue
    _ -> @default_row_count
  end

  defp parse_table(sql) do
    case Regex.run(~r/FROM\s+(\w+)/i, sql) do
      [_, table] -> String.upcase(table)
      _ -> "UNKNOWN"
    end
  end

  # ── Generators ──

  defp generate("CLIENT", n) do
    columns = ["CodeClient", "RaisonSociale", "Representant", "SIRET", "FamilleClient"]
    rows = Enum.map(1..n, &client_row/1)
    {columns, rows}
  end

  defp generate("ARTICLE", n) do
    columns = ["Article", "Désignation", "Complément", "Famille", "Prix unitaire", "Marque", "Un.", "Inactif"]
    rows = Enum.map(1..n, &article_row/1)
    {columns, rows}
  end

  defp generate("IMPLANTATION", n) do
    columns = [
      "CodeImplantation", "EtatContrat", "ContratClient", "Contrat", "PresenceRegistre",
      "TypeImplantation", "RaisonSociale", "ComplRaisonSociale", "Adresse", "ComplementAdresse",
      "CodePostal", "Ville", "Nom", "Telephone", "CodeClient", "CodeSecteur",
      "Verificateur", "Verificateur2", "DateDerniereVerification",
      "Janvier", "Fevrier", "Mars", "Avril", "Mai", "Juin",
      "Juillet", "Aout", "Septembre", "Octobre", "Novembre", "Decembre",
      "TempsMaintenance", "MotDirecteur", "DatePassagePrevu", "ExtraitMobilite", "ImplantationInactive"
    ]
    rows = Enum.map(1..n, &implantation_row/1)
    {columns, rows}
  end

  defp generate("DETAIL_IMPLANTATION", n) do
    columns = ["CodeClient", "CodeImplantation", "Numero", "CodeArticle", "Désignation", "AnnéeMiseEnService", "LibelleEmplacement"]
    rows = detail_implantation_rows(n)
    {columns, rows}
  end

  defp generate(_table, n) do
    columns = ["id", "value"]
    rows = Enum.map(1..n, fn i -> [i, "row_#{i}"] end)
    {columns, rows}
  end

  # ── CLIENT ──

  @companies [
    "Dupont Sécurité", "Martin Incendie", "Bernard Protection", "Petit Extincteurs",
    "Durand Services", "Leroy Sécurité", "Moreau Prévention", "Simon Détection",
    "Laurent Protection Incendie", "Lefebvre Maintenance", "Michel Sécurité Plus",
    "Garcia Extincteurs", "David Protection", "Bertrand Alarmes", "Roux Incendie",
    "Vincent Sécurité", "Fournier Protection", "Girard Prévention", "André Détection",
    "Lefevre Sécurité", "Mercier Maintenance", "Blanc Protection", "Guérin Services",
    "Boyer Incendie", "Garnier Sécurité", "Chevalier Protection", "Robin Prévention",
    "Clément Détection", "Morin Sécurité", "Nicolas Protection Incendie"
  ]

  @familles ["INDUSTRIE", "COMMERCE", "ERP", "HABITATION", "TERTIAIRE", "COLLECTIVITE"]
  @representants ["Jean DUPONT", "Marie MARTIN", "Pierre DURAND", "Sophie LEROY", "Paul MOREAU"]

  defp client_row(i) do
    code = String.pad_leading("#{i}", 5, "0")
    company = Enum.at(@companies, rem(i - 1, length(@companies)))
    siret = "#{300_000_000 + i * 1_111}#{String.pad_leading("#{rem(i * 7, 99999)}", 5, "0")}"

    [code, company, Enum.at(@representants, rem(i, length(@representants))), siret, Enum.at(@familles, rem(i, length(@familles)))]
  end

  # ── ARTICLE ──

  @articles [
    {"EXT-ABC-6", "Extincteur ABC 6kg", "Poudre polyvalente", "EXTINCTEURS", "45.00", "Desautel"},
    {"EXT-CO2-2", "Extincteur CO2 2kg", "Dioxyde de carbone", "EXTINCTEURS", "65.00", "Sicli"},
    {"EXT-EAU-9", "Extincteur eau 9L", "Eau pulvérisée + additif", "EXTINCTEURS", "38.00", "Desautel"},
    {"DET-OPT", "Détecteur optique fumée", "Conventionnel", "DETECTION", "28.50", "Nugelec"},
    {"DET-THER", "Détecteur thermovélocimétrique", "Seuil 58°C", "DETECTION", "32.00", "Nugelec"},
    {"DET-MUL", "Détecteur multi-capteurs", "Optique + thermique", "DETECTION", "85.00", "System Sensor"},
    {"BAE-T4", "Alarme incendie Type 4", "Avec flash", "ALARMES", "120.00", "Nugelec"},
    {"BAE-EA", "Équipement d'alarme EA", "Catégorie C/D/E", "ALARMES", "250.00", "DEF"},
    {"BDM-30", "Bloc de secours BAES 30lm", "LEDs autonomie 1h", "ECLAIRAGE", "22.00", "Legrand"},
    {"BDM-45", "Bloc de secours BAES 45lm", "LEDs autonomie 1h", "ECLAIRAGE", "28.00", "Legrand"},
    {"PIS-125", "Poteau incendie DN125", "Incongelable", "RIA-PI", "850.00", "Bayard"},
    {"RIA-19", "RIA DN19/30", "Pivotant 30m", "RIA-PI", "320.00", "Desautel"},
    {"SIG-PLN", "Plan d'évacuation", "Format A3", "SIGNALISATION", "35.00", "Handinorme"},
    {"SIG-EXT", "Panneau extincteur", "Photoluminescent", "SIGNALISATION", "8.50", "Handinorme"},
    {"DES-SPK", "Sprinkler pendant 68°C", "DN15 K80", "SPRINKLAGE", "12.00", "Viking"}
  ]

  defp article_row(i) do
    {ref, name, complement, famille, prix, marque} = Enum.at(@articles, rem(i - 1, length(@articles)))
    suffix = if i > length(@articles), do: "-#{div(i - 1, length(@articles)) + 1}", else: ""
    ["#{ref}#{suffix}", name, complement, famille, prix, marque, "U", 0]
  end

  # ── IMPLANTATION ──

  @streets [
    "Rue de la République", "Avenue des Champs", "Boulevard Saint-Michel",
    "Rue du Commerce", "Avenue Pasteur", "Rue Victor Hugo", "Place de la Mairie",
    "Rue de la Gare", "Avenue Jean Jaurès", "Rue Gambetta", "Boulevard de la Liberté",
    "Rue de l'Industrie", "Impasse des Lilas", "Rue des Écoles", "Avenue du Général de Gaulle"
  ]

  @cities [
    {"25000", "Besançon"}, {"39000", "Lons-le-Saunier"}, {"70000", "Vesoul"},
    {"90000", "Belfort"}, {"21000", "Dijon"}, {"68000", "Colmar"},
    {"67000", "Strasbourg"}, {"54000", "Nancy"}, {"57000", "Metz"},
    {"88000", "Épinal"}, {"71100", "Chalon-sur-Saône"}, {"03000", "Moulins"}
  ]

  @types ["V", "M", "L", "I"]
  @etats ["EN COURS", "ACTIF", "SUSPENDU"]
  @contrats ["CONTRAT", "HORS CONTRAT", "PONCTUEL"]
  @verificateurs ["JDUPONT", "MMARTIN", "PDURAND", "SLEROY", "BMOREAU"]

  @month_patterns [
    [1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0],
    [0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0],
    [0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0],
    [0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0],
    [0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0],
    [0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1]
  ]

  defp implantation_row(i) do
    code = "IMP#{String.pad_leading("#{i}", 5, "0")}"
    client_code = String.pad_leading("#{rem(i - 1, 20) + 1}", 5, "0")
    {cp, ville} = Enum.at(@cities, rem(i, length(@cities)))
    street = Enum.at(@streets, rem(i, length(@streets)))
    months = Enum.at(@month_patterns, rem(i, length(@month_patterns)))

    last_visit =
      Date.utc_today()
      |> Date.add(-(rem(i * 17, 180) + 1))
      |> Date.to_iso8601()

    [
      code,
      Enum.at(@etats, rem(i, length(@etats))),
      Enum.at(@contrats, rem(i, length(@contrats))),
      "C-#{code}",
      rem(i, 2),
      Enum.at(@types, rem(i, length(@types))),
      Enum.at(@companies, rem(i - 1, length(@companies))),
      nil,
      "#{rem(i * 3, 150) + 1} #{street}",
      nil,
      cp,
      ville,
      "Resp. Site #{i}",
      "03#{String.pad_leading("#{rem(i * 12345, 100_000_000)}", 8, "0")}",
      client_code,
      "S#{rem(i - 1, 5) + 1}",
      Enum.at(@verificateurs, rem(i, length(@verificateurs))),
      Enum.at([nil | @verificateurs], rem(i + 1, length(@verificateurs) + 1)),
      last_visit
    ] ++ months ++ [
      Enum.at([30, 45, 60, 90, 120], rem(i, 5)),
      nil,
      nil,
      0,
      0
    ]
  end

  # ── DETAIL_IMPLANTATION ──

  @emplacements ["RDC", "Étage 1", "Étage 2", "Sous-sol", "Parking", "Hall", "Cuisine", "Local technique"]

  defp detail_implantation_rows(count) do
    article_refs = Enum.map(@articles, fn {ref, _, _, _, _, _} -> ref end)
    impl_count = max(div(count, 3), 5)

    {rows, _} =
      Enum.reduce(1..impl_count, {[], 0}, fn impl_idx, {acc, n} ->
        if n >= count do
          {acc, n}
        else
          eq_count = rem(impl_idx, 4) + 2
          impl_code = "IMP#{String.pad_leading("#{impl_idx}", 5, "0")}"
          client_code = String.pad_leading("#{rem(impl_idx - 1, 20) + 1}", 5, "0")

          {new_rows, new_n} =
            Enum.reduce(1..eq_count, {[], n}, fn eq_idx, {eq_acc, en} ->
              if en >= count do
                {eq_acc, en}
              else
                article = Enum.at(article_refs, rem(en, length(article_refs)))
                year = 2015 + rem(en, 10)
                emplacement = Enum.at(@emplacements, rem(en, length(@emplacements)))

                row = [client_code, impl_code, "#{en + 1}", article, "Équipement #{article} ##{eq_idx}", "#{year}", emplacement]
                {[row | eq_acc], en + 1}
              end
            end)

          {Enum.reverse(new_rows) ++ acc, new_n}
        end
      end)

    Enum.reverse(rows)
  end
end
