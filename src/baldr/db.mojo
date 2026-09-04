"""baldr.db — a small SQLite database wrapper.

`Db` owns a SQLite connection and loads `libsqlite3.so.0` at runtime. SQL
parameters are bound as text, query values are copied into Mojo strings, and
prepared statements are finalized before every return or raise.

    from baldr.db import Db, Row

    var db = Db.open(":memory:")
    db.exec("CREATE TABLE notes (body TEXT NOT NULL)")
    var params = List[String]()
    params.append("hello")
    db.exec("INSERT INTO notes (body) VALUES (?)", params)
    var rows = db.query("SELECT body FROM notes")
"""

from std.ffi import OwnedDLHandle
from std.os import abort


comptime _SQLITE_OK: Int32 = 0
comptime _SQLITE_ROW: Int32 = 100
comptime _SQLITE_DONE: Int32 = 101
comptime _SQLITE_NULL: Int32 = 5
comptime _SQLITE_OPEN_READWRITE: Int32 = 0x00000002
comptime _SQLITE_OPEN_CREATE: Int32 = 0x00000004

comptime _StoredHandle = Pointer[UInt8, MutUntrackedOrigin]
comptime _CHandle = Pointer[UInt8, MutAnyOrigin]


struct Row(Copyable, Movable):
    """One query result row.

    `cols`, `vals`, and `is_null` have equal lengths and retain SELECT order.
    SQL NULL is represented by `vals[i] == ""` and `is_null[i] == True`.
    """

    var cols: List[String]
    var vals: List[String]
    var is_null: List[Bool]

    def __init__(
        out self,
        var cols: List[String],
        var vals: List[String],
        var is_null: List[Bool],
    ):
        self.cols = cols^
        self.vals = vals^
        self.is_null = is_null^

    def get(self, name: String) raises -> String:
        """Return a value by column name, raising when the column is absent."""
        for i in range(len(self.cols)):
            if self.cols[i] == name:
                return self.vals[i]
        raise Error("baldr.db: no such column: " + name)


struct Db(Movable):
    """An owning SQLite connection.

    `Db` is movable but deliberately not copyable: exactly one value owns and
    closes a connection. The connection field is declared before the dynamic
    library handle so explicit connection teardown happens while SQLite remains
    loaded.
    """

    var _conn: _StoredHandle
    var _lib: OwnedDLHandle

    @doc_hidden
    def __init__(out self, conn: _StoredHandle, var lib: OwnedDLHandle):
        self._conn = conn
        self._lib = lib^

    @staticmethod
    def open(path: String) raises -> Db:
        """Open or create a SQLite database at `path`.

        `":memory:"` creates an in-memory database. File paths use
        `SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE`.
        """
        var lib = OwnedDLHandle("libsqlite3.so.0")
        var conn = _null_handle()
        var filename = _to_cstring(path)
        var rc = lib.get_function[Int32]("sqlite3_open_v2")(
            filename.unsafe_ptr().as_unsafe_any_origin(),
            Pointer(to=conn).as_unsafe_any_origin(),
            _SQLITE_OPEN_READWRITE | _SQLITE_OPEN_CREATE,
            _null_handle().as_unsafe_any_origin(),
        )
        if rc != _SQLITE_OK or Int(conn) == 0:
            var detail = String("unable to open database")
            if Int(conn) != 0:
                try:
                    detail = _errmsg(lib, conn)
                except:
                    pass
                try:
                    _ = lib.get_function[Int32]("sqlite3_close_v2")(
                        conn.as_unsafe_any_origin()
                    )
                except:
                    pass
            raise Error("baldr.db: " + detail + " (opening: " + path + ")")
        return Db(conn, lib^)

    def exec(mut self, sql: String) raises:
        """Execute one statement that does not return rows."""
        var params = List[String]()
        self.exec(sql, params)

    def exec(mut self, sql: String, params: List[String]) raises:
        """Execute one statement with `?` parameters bound as TEXT."""
        var stmt = self._prepare(sql)
        try:
            self._bind_all(stmt, params, sql)
            var rc = self._lib.get_function[Int32]("sqlite3_step")(
                stmt.as_unsafe_any_origin()
            )
            if rc != _SQLITE_DONE:
                raise Error(self._error_message(sql))
        except e:
            self._finalize_noexcept(stmt)
            raise e

        var finalize_rc = self._lib.get_function[Int32]("sqlite3_finalize")(
            stmt.as_unsafe_any_origin()
        )
        if finalize_rc != _SQLITE_OK:
            raise Error(self._error_message(sql))

    def query(mut self, sql: String) raises -> List[Row]:
        """Run one query and return all result rows."""
        var params = List[String]()
        return self.query(sql, params)

    def query(mut self, sql: String, params: List[String]) raises -> List[Row]:
        """Run one parameterized query and return all result rows."""
        var stmt = self._prepare(sql)
        var rows = List[Row]()
        try:
            self._bind_all(stmt, params, sql)
            var column_count = Int(
                self._lib.get_function[Int32]("sqlite3_column_count")(
                    stmt.as_unsafe_any_origin()
                )
            )
            var column_names = List[String](capacity=column_count)
            for i in range(column_count):
                var name_ptr = self._lib.get_function[_CHandle](
                    "sqlite3_column_name"
                )(stmt.as_unsafe_any_origin(), Int32(i))
                if Int(name_ptr) == 0:
                    raise Error(
                        "baldr.db: sqlite returned a null column name (in: "
                        + sql
                        + ")"
                    )
                column_names.append(_copy_cstring(name_ptr))

            while True:
                var step_rc = self._lib.get_function[Int32]("sqlite3_step")(
                    stmt.as_unsafe_any_origin()
                )
                if step_rc == _SQLITE_DONE:
                    break
                if step_rc != _SQLITE_ROW:
                    raise Error(self._error_message(sql))

                var values = List[String](capacity=column_count)
                var nulls = List[Bool](capacity=column_count)
                for i in range(column_count):
                    var column_type = self._lib.get_function[Int32](
                        "sqlite3_column_type"
                    )(stmt.as_unsafe_any_origin(), Int32(i))
                    if column_type == _SQLITE_NULL:
                        values.append(String())
                        nulls.append(True)
                    else:
                        var value_ptr = self._lib.get_function[_CHandle](
                            "sqlite3_column_text"
                        )(stmt.as_unsafe_any_origin(), Int32(i))
                        if Int(value_ptr) == 0:
                            raise Error(self._error_message(sql))
                        values.append(_copy_cstring(value_ptr))
                        nulls.append(False)
                rows.append(Row(column_names.copy(), values^, nulls^))
        except e:
            self._finalize_noexcept(stmt)
            raise e

        var finalize_rc = self._lib.get_function[Int32]("sqlite3_finalize")(
            stmt.as_unsafe_any_origin()
        )
        if finalize_rc != _SQLITE_OK:
            raise Error(self._error_message(sql))
        return rows^

    def last_insert_rowid(self) -> Int:
        """Return the rowid from the most recent successful INSERT."""
        try:
            return Int(
                self._lib.get_function[Int64]("sqlite3_last_insert_rowid")(
                    self._conn.as_unsafe_any_origin()
                )
            )
        except:
            abort(
                "baldr.db: required symbol sqlite3_last_insert_rowid is missing"
            )

    def changes(self) -> Int:
        """Return rows changed by the most recent INSERT/UPDATE/DELETE."""
        try:
            return Int(
                self._lib.get_function[Int32]("sqlite3_changes")(
                    self._conn.as_unsafe_any_origin()
                )
            )
        except:
            abort("baldr.db: required symbol sqlite3_changes is missing")

    def __deinit__(deinit self):
        try:
            _ = self._lib.get_function[Int32]("sqlite3_close_v2")(
                self._conn.as_unsafe_any_origin()
            )
        except:
            pass

    def _prepare(mut self, sql: String) raises -> _StoredHandle:
        var stmt = _null_handle()
        var sql_buffer = _to_cstring(sql)
        var rc = self._lib.get_function[Int32]("sqlite3_prepare_v2")(
            self._conn.as_unsafe_any_origin(),
            sql_buffer.unsafe_ptr().as_unsafe_any_origin(),
            Int32(-1),
            Pointer(to=stmt).as_unsafe_any_origin(),
            _null_handle().as_unsafe_any_origin(),
        )
        if rc != _SQLITE_OK:
            raise Error(self._error_message(sql))
        if Int(stmt) == 0:
            raise Error("baldr.db: SQL contains no statement (in: " + sql + ")")
        return stmt

    def _bind_all(
        mut self, stmt: _StoredHandle, params: List[String], sql: String
    ) raises:
        var expected = Int(
            self._lib.get_function[Int32]("sqlite3_bind_parameter_count")(
                stmt.as_unsafe_any_origin()
            )
        )
        if expected != len(params):
            raise Error(
                "baldr.db: expected "
                + String(expected)
                + " parameters, got "
                + String(len(params))
                + " (in: "
                + sql
                + ")"
            )

        for i in range(len(params)):
            var text = _to_cstring(params[i])
            var rc = self._lib.get_function[Int32]("sqlite3_bind_text")(
                stmt.as_unsafe_any_origin(),
                Int32(i + 1),
                text.unsafe_ptr().as_unsafe_any_origin(),
                Int32(-1),
                _transient_destructor(),
            )
            if rc != _SQLITE_OK:
                raise Error(self._error_message(sql))

    def _error_message(self, sql: String) raises -> String:
        return (
            "baldr.db: " + _errmsg(self._lib, self._conn) + " (in: " + sql + ")"
        )

    def _finalize_noexcept(mut self, stmt: _StoredHandle):
        try:
            _ = self._lib.get_function[Int32]("sqlite3_finalize")(
                stmt.as_unsafe_any_origin()
            )
        except:
            pass


def _to_cstring(text: String) -> List[UInt8]:
    var bytes = (text + "\0").as_bytes()
    var out = List[UInt8](capacity=len(bytes))
    for i in range(len(bytes)):
        out.append(bytes[i])
    return out^


def _copy_cstring(ptr: _CHandle) -> String:
    return String(unsafe_from_utf8_ptr=ptr.as_imm())


def _errmsg(lib: OwnedDLHandle, conn: _StoredHandle) raises -> String:
    var ptr = lib.get_function[_CHandle]("sqlite3_errmsg")(
        conn.as_unsafe_any_origin()
    )
    if Int(ptr) == 0:
        return String("unknown sqlite error")
    return _copy_cstring(ptr)


def _null_handle() -> _StoredHandle:
    # C APIs use null pointers for optional/out parameters. The address is
    # deliberately constructed from a runtime Int because Pointer's literal
    # constructor rejects zero; it crosses the C ABI and is never dereferenced.
    return _StoredHandle(unsafe_from_address=Int(0))


def _transient_destructor() -> _CHandle:
    # SQLite's SQLITE_TRANSIENT sentinel is (sqlite3_destructor_type)-1.
    return _StoredHandle(unsafe_from_address=Int(-1)).as_unsafe_any_origin()
