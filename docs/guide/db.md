# SQLite Database

`baldr.db` is a small SQLite wrapper for applications that need a durable local
store without adding a database service. It loads `libsqlite3.so.0` at runtime,
so the application binary is not linked to SQLite at build time.

## Open a database

`Db.open()` opens an existing file or creates it with SQLite's read/write and
create flags. Use `:memory:` for a process-local temporary database:

```mojo
from baldr.db import Db

var db = Db.open("app.sqlite")
# or: var db = Db.open(":memory:")
```

The `Db` binding must be `var`: operations mutate the connection, and Mojo
requires a mutable binding when calling a method whose receiver is `mut self`.

## Execute statements

Use `exec()` for a single statement that does not return rows:

```mojo
db.exec(
    "CREATE TABLE IF NOT EXISTS notes ("
    "id INTEGER PRIMARY KEY, body TEXT NOT NULL)"
)
db.exec("DELETE FROM notes")
```

`last_insert_rowid()` reports the last generated row ID on this connection, and
`changes()` reports how many rows the most recent insert, update, or delete
changed:

```mojo
var params = List[String]()
params.append("first")
db.exec("INSERT INTO notes (body) VALUES (?)", params)
print(db.last_insert_rowid())
print(db.changes())
```

## Query rows

`query()` returns `List[Row]`. Column names and values preserve SELECT order;
values are copied into Mojo `String`s before SQLite advances the statement:

```mojo
var rows = db.query("SELECT id, body FROM notes ORDER BY id")
for i in range(len(rows)):
    print(rows[i].get("id"), rows[i].get("body"))
```

`Row.get(name)` returns the first column with that name and raises if the name is
absent. Every row also exposes parallel `cols`, `vals`, and `is_null` lists.
SQLite `NULL` becomes an empty string in `vals`; distinguish it from an actual
empty TEXT value with `is_null[i]`.

## Parameters

The overloads that accept `List[String]` bind each value as SQLite TEXT to a
1-based `?` placeholder. SQLite copies the UTF-8 bytes during the call, so local
Mojo strings do not escape their lifetime:

```mojo
var title = String("O'Reilly — 火")
var params = List[String]()
params.append(title)
db.exec(
    "INSERT INTO notes (body) VALUES (?)",
    params,
)
var query_params = List[String]()
query_params.append(title)
var matches = db.query(
    "SELECT body FROM notes WHERE body = ?",
    query_params,
)
```

The parameter count must exactly match the statement's placeholder count.
Unbound placeholders do **not** silently become NULL; too few or too many values
raise an error before execution.

## Errors

Opening, preparing, binding, stepping, or finalizing can raise `Error`. SQLite
failures include both `sqlite3_errmsg` text and the SQL that failed:

```text
baldr.db: near "SELEC": syntax error (in: SELEC 1)
```

Let these errors reach baldr's normal error handler, or catch them around the
smallest database operation that can recover. Parameter-count and missing-column
errors use the same `baldr.db:` prefix and include the relevant SQL or name.

## Lifetime and ownership

`Db` is `Movable` but not `Copyable`: one Mojo value owns each SQLite connection.
Its explicit destructor calls `sqlite3_close_v2`, while every `exec()` and
`query()` finalizes its prepared statement on both success and error paths. Keep
the `Db` as a field on a `DispatchHandler` when the connection should live for the
server's lifetime:

```mojo
@fieldwise_init
struct NotesApp(DispatchHandler, Movable):
    var db: Db
```

See `examples/db/main.mojo` for a complete file-backed notes application.
