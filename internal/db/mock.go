package db

import (
	"database/sql"
	"fmt"
	"log/slog"

	_ "modernc.org/sqlite"
)

// MockDriver uses an in-memory SQLite database with seeded fire safety data.
type MockDriver struct {
	db *sql.DB
}

// NewMockDriver creates a new mock driver.
func NewMockDriver() *MockDriver {
	return &MockDriver{}
}

func (d *MockDriver) Connect(cfg map[string]string) error {
	db, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		return fmt.Errorf("open sqlite: %w", err)
	}

	if err := seedDatabase(db); err != nil {
		db.Close()
		return fmt.Errorf("seed mock database: %w", err)
	}

	d.db = db
	slog.Info("Mock SQLite database ready", "tables", "CLIENT, ARTICLE, IMPLANTATION, DETAIL_IMPLANTATION")
	return nil
}

func (d *MockDriver) Query(sqlStr string, params []interface{}) ([]string, [][]interface{}, error) {
	if d.db == nil {
		return nil, nil, fmt.Errorf("mock database not connected")
	}

	rows, err := d.db.Query(sqlStr, params...)
	if err != nil {
		return nil, nil, fmt.Errorf("query: %w", err)
	}
	defer rows.Close()

	columns, err := rows.Columns()
	if err != nil {
		return nil, nil, fmt.Errorf("columns: %w", err)
	}

	var result [][]interface{}
	for rows.Next() {
		values := make([]interface{}, len(columns))
		ptrs := make([]interface{}, len(columns))
		for i := range values {
			ptrs[i] = &values[i]
		}
		if err := rows.Scan(ptrs...); err != nil {
			return nil, nil, fmt.Errorf("scan: %w", err)
		}
		// Convert []byte to string for JSON serialization
		row := make([]interface{}, len(columns))
		for i, v := range values {
			if b, ok := v.([]byte); ok {
				row[i] = string(b)
			} else {
				row[i] = v
			}
		}
		result = append(result, row)
	}

	return columns, result, rows.Err()
}

func (d *MockDriver) Connected() bool {
	return d.db != nil
}

func (d *MockDriver) Close() error {
	if d.db != nil {
		err := d.db.Close()
		d.db = nil
		return err
	}
	return nil
}

func seedDatabase(db *sql.DB) error {
	ddl := `
	CREATE TABLE CLIENT (
		CodeClient TEXT PRIMARY KEY,
		RaisonSociale TEXT,
		Representant TEXT,
		SIRET TEXT,
		FamilleClient TEXT
	);

	CREATE TABLE ARTICLE (
		Article TEXT PRIMARY KEY,
		Designation TEXT,
		Complement TEXT,
		Famille TEXT,
		PrixUnitaire REAL,
		Marque TEXT,
		Unite TEXT,
		Inactif INTEGER DEFAULT 0
	);

	CREATE TABLE IMPLANTATION (
		CodeImplantation TEXT PRIMARY KEY,
		EtatContrat TEXT,
		ContratClient TEXT,
		Adresse TEXT,
		CodePostal TEXT,
		Ville TEXT,
		Nom TEXT,
		Telephone TEXT,
		CodeClient TEXT,
		Verificateur TEXT,
		DateDerniereVerification TEXT,
		TempsMaintenance INTEGER,
		FOREIGN KEY (CodeClient) REFERENCES CLIENT(CodeClient)
	);

	CREATE TABLE DETAIL_IMPLANTATION (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		CodeClient TEXT,
		CodeImplantation TEXT,
		Numero INTEGER,
		CodeArticle TEXT,
		Designation TEXT,
		AnneeMiseEnService INTEGER,
		LibelleEmplacement TEXT,
		FOREIGN KEY (CodeClient) REFERENCES CLIENT(CodeClient),
		FOREIGN KEY (CodeImplantation) REFERENCES IMPLANTATION(CodeImplantation)
	);
	`

	if _, err := db.Exec(ddl); err != nil {
		return fmt.Errorf("create tables: %w", err)
	}

	// Seed clients
	clients := []struct {
		code, name, rep, siret, family string
	}{
		{"CLI0001", "Dupont Securite", "Commercial 1", "12345678901234", "INDUSTRIE"},
		{"CLI0002", "Martin Incendie", "Commercial 2", "23456789012345", "COMMERCE"},
		{"CLI0003", "Bernard Protection", "Commercial 1", "34567890123456", "ERP"},
		{"CLI0004", "Petit Feu", "Commercial 3", "45678901234567", "HABITATION"},
		{"CLI0005", "Durand Alarmes", "Commercial 2", "56789012345678", "TERTIAIRE"},
		{"CLI0006", "Leroy Extincteurs", "Commercial 4", "67890123456789", "LOGISTIQUE"},
		{"CLI0007", "Moreau & Fils", "Commercial 1", "78901234567890", "SANTE"},
		{"CLI0008", "Laurent Prevention", "Commercial 3", "89012345678901", "EDUCATION"},
		{"CLI0009", "Simon Detection", "Commercial 5", "90123456789012", "INDUSTRIE"},
		{"CLI0010", "Michel Services", "Commercial 2", "01234567890123", "COMMERCE"},
		{"CLI0011", "Garcia Securite", "Commercial 4", "11234567890123", "ERP"},
		{"CLI0012", "David Protection", "Commercial 1", "21234567890123", "TERTIAIRE"},
		{"CLI0013", "Bertrand Incendie", "Commercial 3", "31234567890123", "INDUSTRIE"},
		{"CLI0014", "Roux Alarmes", "Commercial 5", "41234567890123", "HABITATION"},
		{"CLI0015", "Vincent Securite", "Commercial 2", "51234567890123", "LOGISTIQUE"},
	}

	stmt, err := db.Prepare("INSERT INTO CLIENT VALUES (?, ?, ?, ?, ?)")
	if err != nil {
		return err
	}
	for _, c := range clients {
		if _, err := stmt.Exec(c.code, c.name, c.rep, c.siret, c.family); err != nil {
			return err
		}
	}
	stmt.Close()

	// Seed articles
	articles := []struct {
		code, desig, comp, family string
		price                     float64
		brand, unit               string
	}{
		{"EXT-001", "Extincteur ABC 6kg", "Poudre polyvalente", "EXTINCTEUR", 45.90, "Sicli", "U"},
		{"EXT-002", "Extincteur CO2 2kg", "Dioxyde de carbone", "EXTINCTEUR", 62.50, "Sicli", "U"},
		{"EXT-003", "Extincteur eau 6L", "Eau pulverisee + additif", "EXTINCTEUR", 38.20, "Desautel", "U"},
		{"DET-001", "Detecteur fumee NF", "Optique - autonomie 10 ans", "DETECTION", 18.90, "Kidde", "U"},
		{"DET-002", "Detecteur chaleur", "Thermovelocimetrique", "DETECTION", 24.50, "Nugelec", "U"},
		{"DET-003", "Detecteur CO", "Monoxyde de carbone", "DETECTION", 32.00, "Kidde", "U"},
		{"ALA-001", "Alarme type 4", "Autonome a pile", "ALARME", 89.00, "Nugelec", "U"},
		{"ALA-002", "Declencheur manuel", "Bris de glace", "ALARME", 28.50, "Legrand", "U"},
		{"SIG-001", "Bloc BAES", "Evacuation 45 lumens", "SIGNALISATION", 35.00, "Kaufel", "U"},
		{"SIG-002", "Plan d evacuation", "Format A3 photoluminescent", "SIGNALISATION", 42.00, "Seton", "U"},
		{"RIA-001", "RIA DN25/30", "Robinet d incendie arme", "RIA", 285.00, "Desautel", "U"},
		{"COL-001", "Colonne seche", "DN65 avec raccord", "COLONNE", 450.00, "Desautel", "U"},
		{"DES-001", "Desenfumage naturel", "Exutoire 1m2", "DESENFUMAGE", 680.00, "Hexadome", "U"},
		{"SPK-001", "Sprinkler pendant", "K80 - 68C", "SPRINKLER", 8.50, "Viking", "U"},
		{"MNT-001", "Maintenance annuelle", "Verification reglementaire", "SERVICE", 95.00, "", "U"},
	}

	stmt, err = db.Prepare("INSERT INTO ARTICLE VALUES (?, ?, ?, ?, ?, ?, ?, 0)")
	if err != nil {
		return err
	}
	for _, a := range articles {
		if _, err := stmt.Exec(a.code, a.desig, a.comp, a.family, a.price, a.brand, a.unit); err != nil {
			return err
		}
	}
	stmt.Close()

	// Seed implantations
	type implRow struct {
		code, status, contract, addr, zip, city, name, phone, client, tech, date string
		maint                                                                     int
	}
	impls := []implRow{
		{"IMP0001", "ACTIF", "CTR0001", "12 rue de la Republique", "75001", "Paris", "Dupont Securite", "01 23 45 67 89", "CLI0001", "TECH01", "2025-11-15", 60},
		{"IMP0002", "ACTIF", "CTR0002", "45 avenue Victor Hugo", "69001", "Lyon", "Martin Incendie", "01 34 56 78 90", "CLI0002", "TECH02", "2025-09-20", 90},
		{"IMP0003", "ACTIF", "CTR0003", "8 boulevard Gambetta", "13001", "Marseille", "Bernard Protection", "01 45 67 89 01", "CLI0003", "TECH01", "2026-01-10", 45},
		{"IMP0004", "SUSPENDU", "CTR0004", "23 rue Pasteur", "31000", "Toulouse", "Petit Feu", "01 56 78 90 12", "CLI0004", "TECH03", "2025-06-05", 120},
		{"IMP0005", "ACTIF", "CTR0005", "67 rue de la Paix", "06000", "Nice", "Durand Alarmes", "01 67 89 01 23", "CLI0005", "TECH02", "2025-12-01", 75},
		{"IMP0006", "ACTIF", "CTR0006", "3 place de la Mairie", "44000", "Nantes", "Leroy Extincteurs", "01 78 90 12 34", "CLI0006", "TECH04", "2026-02-18", 50},
		{"IMP0007", "RESILIE", "CTR0007", "91 rue Jean Jaures", "67000", "Strasbourg", "Moreau & Fils", "01 89 01 23 45", "CLI0007", "TECH01", "2025-04-22", 100},
		{"IMP0008", "ACTIF", "CTR0008", "15 avenue de la Gare", "34000", "Montpellier", "Laurent Prevention", "01 90 12 34 56", "CLI0008", "TECH05", "2025-10-30", 65},
		{"IMP0009", "ACTIF", "CTR0009", "28 rue Nationale", "33000", "Bordeaux", "Simon Detection", "01 01 23 45 67", "CLI0009", "TECH03", "2026-01-25", 80},
		{"IMP0010", "ACTIF", "CTR0010", "54 rue du Commerce", "59000", "Lille", "Michel Services", "01 12 34 56 78", "CLI0010", "TECH02", "2025-08-14", 55},
		{"IMP0011", "ACTIF", "CTR0011", "7 rue des Halles", "35000", "Rennes", "Garcia Securite", "01 23 45 67 01", "CLI0011", "TECH04", "2025-07-09", 70},
		{"IMP0012", "SUSPENDU", "CTR0012", "33 avenue Foch", "51100", "Reims", "David Protection", "01 34 56 78 02", "CLI0012", "TECH01", "2025-05-17", 95},
		{"IMP0013", "ACTIF", "CTR0013", "19 boulevard Voltaire", "83000", "Toulon", "Bertrand Incendie", "01 45 67 89 03", "CLI0013", "TECH05", "2026-03-01", 40},
		{"IMP0014", "ACTIF", "CTR0014", "42 rue Lafayette", "38000", "Grenoble", "Roux Alarmes", "01 56 78 90 04", "CLI0014", "TECH03", "2025-11-28", 85},
		{"IMP0015", "ACTIF", "CTR0015", "6 place de la Liberte", "21000", "Dijon", "Vincent Securite", "01 67 89 01 05", "CLI0015", "TECH02", "2025-10-03", 60},
	}

	stmt, err = db.Prepare("INSERT INTO IMPLANTATION VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)")
	if err != nil {
		return err
	}
	for _, im := range impls {
		if _, err := stmt.Exec(im.code, im.status, im.contract, im.addr, im.zip, im.city, im.name, im.phone, im.client, im.tech, im.date, im.maint); err != nil {
			return err
		}
	}
	stmt.Close()

	// Seed detail implantations
	type detailRow struct {
		client, impl string
		num          int
		article, des string
		year         int
		location     string
	}
	details := []detailRow{
		{"CLI0001", "IMP0001", 1, "EXT-001", "Extincteur ABC 6kg", 2020, "RDC"},
		{"CLI0001", "IMP0001", 2, "DET-001", "Detecteur fumee NF", 2021, "Etage 1"},
		{"CLI0001", "IMP0001", 3, "SIG-001", "Bloc BAES", 2020, "Couloir"},
		{"CLI0002", "IMP0002", 1, "EXT-002", "Extincteur CO2 2kg", 2019, "Accueil"},
		{"CLI0002", "IMP0002", 2, "ALA-001", "Alarme type 4", 2022, "RDC"},
		{"CLI0002", "IMP0002", 3, "DET-002", "Detecteur chaleur", 2021, "Salle serveur"},
		{"CLI0003", "IMP0003", 1, "RIA-001", "RIA DN25/30", 2018, "Sous-sol"},
		{"CLI0003", "IMP0003", 2, "EXT-003", "Extincteur eau 6L", 2023, "Etage 2"},
		{"CLI0004", "IMP0004", 1, "DES-001", "Desenfumage naturel", 2017, "Parking"},
		{"CLI0004", "IMP0004", 2, "SPK-001", "Sprinkler pendant", 2017, "Entrepot"},
		{"CLI0004", "IMP0004", 3, "DET-003", "Detecteur CO", 2020, "Chaufferie"},
		{"CLI0005", "IMP0005", 1, "EXT-001", "Extincteur ABC 6kg", 2022, "Bureau"},
		{"CLI0005", "IMP0005", 2, "ALA-002", "Declencheur manuel", 2022, "Etage 1"},
		{"CLI0006", "IMP0006", 1, "COL-001", "Colonne seche", 2016, "Sous-sol"},
		{"CLI0006", "IMP0006", 2, "SIG-002", "Plan d evacuation", 2023, "Accueil"},
		{"CLI0007", "IMP0007", 1, "EXT-001", "Extincteur ABC 6kg", 2019, "Atelier"},
		{"CLI0007", "IMP0007", 2, "EXT-002", "Extincteur CO2 2kg", 2019, "Local technique"},
		{"CLI0008", "IMP0008", 1, "DET-001", "Detecteur fumee NF", 2021, "Cuisine"},
		{"CLI0008", "IMP0008", 2, "MNT-001", "Maintenance annuelle", 2024, "RDC"},
		{"CLI0009", "IMP0009", 1, "EXT-003", "Extincteur eau 6L", 2020, "Vestiaire"},
		{"CLI0009", "IMP0009", 2, "DET-002", "Detecteur chaleur", 2020, "Etage 3"},
		{"CLI0010", "IMP0010", 1, "ALA-001", "Alarme type 4", 2023, "RDC"},
		{"CLI0010", "IMP0010", 2, "SIG-001", "Bloc BAES", 2023, "Couloir"},
		{"CLI0010", "IMP0010", 3, "EXT-001", "Extincteur ABC 6kg", 2021, "Etage 1"},
		{"CLI0011", "IMP0011", 1, "RIA-001", "RIA DN25/30", 2018, "Sous-sol"},
		{"CLI0012", "IMP0012", 1, "DET-001", "Detecteur fumee NF", 2022, "Bureau"},
		{"CLI0012", "IMP0012", 2, "EXT-002", "Extincteur CO2 2kg", 2020, "Atelier"},
		{"CLI0013", "IMP0013", 1, "SPK-001", "Sprinkler pendant", 2019, "Entrepot"},
		{"CLI0014", "IMP0014", 1, "EXT-001", "Extincteur ABC 6kg", 2021, "RDC"},
		{"CLI0014", "IMP0014", 2, "DET-003", "Detecteur CO", 2021, "Chaufferie"},
		{"CLI0015", "IMP0015", 1, "SIG-002", "Plan d evacuation", 2024, "Accueil"},
		{"CLI0015", "IMP0015", 2, "ALA-002", "Declencheur manuel", 2024, "Etage 1"},
	}

	stmt, err = db.Prepare("INSERT INTO DETAIL_IMPLANTATION (CodeClient, CodeImplantation, Numero, CodeArticle, Designation, AnneeMiseEnService, LibelleEmplacement) VALUES (?, ?, ?, ?, ?, ?, ?)")
	if err != nil {
		return err
	}
	for _, d := range details {
		if _, err := stmt.Exec(d.client, d.impl, d.num, d.article, d.des, d.year, d.location); err != nil {
			return err
		}
	}
	stmt.Close()

	return nil
}
