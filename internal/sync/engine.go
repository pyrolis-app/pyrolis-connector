package sync

import (
	"context"
	"database/sql"
	"fmt"
	"log/slog"
	"regexp"
	"strings"
	"time"

	_ "modernc.org/sqlite"
)

const defaultBatchSize = 999

// QueryFunc executes a SQL query against a data source and returns columns + rows.
type QueryFunc func(dataSource, sql string, params []interface{}) ([]string, [][]interface{}, error)

// ProgressFunc is called after each batch with table name and cumulative row count.
type ProgressFunc func(table string, totalRows int)

// Engine syncs a remote data source into a local SQLite database.
type Engine struct {
	queryFn    QueryFunc
	progressFn ProgressFunc
	dataSource string
	batchSize  int
	tables     []TableDef
}

// NewEngine creates a sync engine for the given data source.
func NewEngine(dataSource string, queryFn QueryFunc) *Engine {
	return &Engine{
		queryFn:    queryFn,
		dataSource: dataSource,
		batchSize:  defaultBatchSize,
		tables:     SI2ATables,
	}
}

// SetBatchSize overrides the default batch size.
func (e *Engine) SetBatchSize(n int) {
	if n > 0 {
		e.batchSize = n
	}
}

// SetProgressFunc sets a callback for progress reporting.
func (e *Engine) SetProgressFunc(fn ProgressFunc) {
	e.progressFn = fn
}

// SetTables overrides which tables to sync (default: all SI2A tables).
func (e *Engine) SetTables(tables []TableDef) {
	e.tables = tables
}

// Result holds the outcome of a sync run.
type Result struct {
	Tables  int
	Rows    int
	Failed  int
	Skipped int
	Elapsed time.Duration
}

// Run executes the full sync to the given SQLite file path.
func (e *Engine) Run(ctx context.Context, dbPath string) (*Result, error) {
	start := time.Now()

	db, err := sql.Open("sqlite", dbPath+"?_pragma=journal_mode(WAL)&_pragma=synchronous(NORMAL)")
	if err != nil {
		return nil, fmt.Errorf("open sqlite %s: %w", dbPath, err)
	}
	defer db.Close()

	// Enable WAL mode for better write performance
	if _, err := db.Exec("PRAGMA journal_mode=WAL"); err != nil {
		slog.Warn("Failed to set WAL mode", "error", err)
	}

	result := &Result{}

	for i, table := range e.tables {
		if ctx.Err() != nil {
			return result, ctx.Err()
		}

		slog.Info("Syncing table", "table", table.Name, "index", i+1, "total", len(e.tables))

		n, err := e.syncTable(ctx, db, table)
		if err != nil {
			slog.Error("Failed to sync table", "table", table.Name, "error", err)
			result.Failed++
			continue
		}

		result.Tables++
		result.Rows += n
		slog.Info("Table synced", "table", table.Name, "rows", n)
	}

	result.Elapsed = time.Since(start)
	return result, nil
}

var colSanitizer = regexp.MustCompile(`[^a-zA-Z0-9_]`)

func sanitizeCol(name string) string {
	return colSanitizer.ReplaceAllString(name, "_")
}

func (e *Engine) syncTable(ctx context.Context, db *sql.DB, table TableDef) (int, error) {
	// Drop and recreate table
	safeCols := make([]string, len(table.Columns))
	for i, c := range table.Columns {
		safeCols[i] = sanitizeCol(c)
	}

	dropSQL := fmt.Sprintf(`DROP TABLE IF EXISTS "%s"`, table.Name)
	if _, err := db.Exec(dropSQL); err != nil {
		return 0, fmt.Errorf("drop table: %w", err)
	}

	colDefs := make([]string, len(safeCols))
	for i, c := range safeCols {
		colDefs[i] = fmt.Sprintf(`"%s" TEXT`, c)
	}
	createSQL := fmt.Sprintf(`CREATE TABLE "%s" (%s)`, table.Name, strings.Join(colDefs, ", "))
	if _, err := db.Exec(createSQL); err != nil {
		return 0, fmt.Errorf("create table: %w", err)
	}

	// Build column list for the SELECT (TABLE.Column format)
	selectCols := make([]string, len(table.Columns))
	for i, c := range table.Columns {
		selectCols[i] = fmt.Sprintf("%s.%s", table.Name, c)
	}
	selectList := strings.Join(selectCols, ", ")

	// Paginate using TOP + keyset cursor
	var lastID interface{}
	totalRows := 0

	for {
		if ctx.Err() != nil {
			return totalRows, ctx.Err()
		}

		query := e.buildQuery(table, selectList, lastID)

		columns, rows, err := e.queryFn(e.dataSource, query, nil)
		if err != nil {
			return totalRows, fmt.Errorf("query at offset %d: %w", totalRows, err)
		}

		if len(rows) == 0 {
			break
		}

		// Build column index map (returned columns may differ in case)
		colIndex := buildColumnIndex(columns, safeCols, table.Columns)

		// Insert batch in a transaction
		if err := e.insertBatch(db, table.Name, safeCols, colIndex, rows); err != nil {
			return totalRows, fmt.Errorf("insert batch: %w", err)
		}

		totalRows += len(rows)

		// Update cursor from last row
		lastID = extractID(columns, table.IDCol, rows[len(rows)-1])

		if e.progressFn != nil {
			e.progressFn(table.Name, totalRows)
		}

		if len(rows) < e.batchSize {
			break
		}
	}

	return totalRows, nil
}

func (e *Engine) buildQuery(table TableDef, selectList string, lastID interface{}) string {
	var sb strings.Builder
	fmt.Fprintf(&sb, "SELECT TOP %d %s FROM %s", e.batchSize, selectList, table.Name)

	if lastID != nil {
		// Keyset pagination
		idStr := fmt.Sprintf("%v", lastID)
		escaped := strings.ReplaceAll(idStr, "'", "''")
		fmt.Fprintf(&sb, " WHERE %s.%s > '%s'", table.Name, table.IDCol, escaped)
	}

	fmt.Fprintf(&sb, " ORDER BY %s.%s", table.Name, table.IDCol)
	return sb.String()
}

// buildColumnIndex maps each safe column to the index in the returned columns.
func buildColumnIndex(returnedCols []string, safeCols []string, originalCols []string) []int {
	index := make([]int, len(safeCols))
	for i, sc := range safeCols {
		index[i] = -1
		for j, rc := range returnedCols {
			if sanitizeCol(rc) == sc {
				index[i] = j
				break
			}
		}
	}
	return index
}

func (e *Engine) insertBatch(db *sql.DB, tableName string, safeCols []string, colIndex []int, rows [][]interface{}) error {
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	placeholders := make([]string, len(safeCols))
	for i := range placeholders {
		placeholders[i] = "?"
	}
	colNames := make([]string, len(safeCols))
	for i, c := range safeCols {
		colNames[i] = fmt.Sprintf(`"%s"`, c)
	}

	insertSQL := fmt.Sprintf(`INSERT INTO "%s" (%s) VALUES (%s)`,
		tableName,
		strings.Join(colNames, ", "),
		strings.Join(placeholders, ", "))

	stmt, err := tx.Prepare(insertSQL)
	if err != nil {
		return err
	}
	defer stmt.Close()

	for _, row := range rows {
		values := make([]interface{}, len(safeCols))
		for i, idx := range colIndex {
			if idx >= 0 && idx < len(row) {
				values[i] = asString(row[idx])
			}
		}
		if _, err := stmt.Exec(values...); err != nil {
			return err
		}
	}

	return tx.Commit()
}

func extractID(columns []string, idCol string, row []interface{}) interface{} {
	idUpper := strings.ToUpper(idCol)
	for i, c := range columns {
		if strings.ToUpper(c) == idUpper && i < len(row) {
			return row[i]
		}
	}
	if len(row) > 0 {
		return row[0]
	}
	return nil
}

func asString(v interface{}) interface{} {
	if v == nil {
		return nil
	}
	switch val := v.(type) {
	case string:
		return val
	case []byte:
		return string(val)
	default:
		return fmt.Sprintf("%v", val)
	}
}
