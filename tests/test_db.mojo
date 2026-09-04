"""Behavior tests for baldr.db's SQLite FFI wrapper."""

from std.os import makedirs

from baldr.db import Db


struct Runner(Copyable, Movable):
    var total: Int
    var failures: Int

    def __init__(out self):
        self.total = 0
        self.failures = 0

    def check(mut self, label: String, condition: Bool):
        self.total += 1
        if condition:
            print("[ok]", label)
        else:
            self.failures += 1
            print("[FAIL]", label)

    def summary(self):
        print("---")
        if self.failures == 0:
            print(self.total, "/", self.total, "passed")
        else:
            print(self.failures, "of", self.total, "FAILED")


def _params(*values: String) -> List[String]:
    var out = List[String](capacity=len(values))
    for value in values:
        out.append(value)
    return out^


def test_memory_database(mut runner: Runner) raises:
    var db = Db.open(":memory:")
    db.exec(
        "CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT, extra TEXT)"
    )
    db.exec(
        "INSERT INTO notes (body, extra) VALUES (?, ?)",
        _params("first", "one"),
    )
    runner.check("first insert rowid", db.last_insert_rowid() == 1)
    runner.check("first insert changes", db.changes() == 1)
    db.exec(
        "INSERT INTO notes (body, extra) VALUES (?, ?)",
        _params("second", "two"),
    )
    runner.check("second insert rowid", db.last_insert_rowid() == 2)
    runner.check("second insert changes", db.changes() == 1)

    var rows = db.query("SELECT id, body FROM notes ORDER BY id")
    runner.check("query returns two rows", len(rows) == 2)
    runner.check(
        "column names retain SELECT order",
        len(rows) == 2
        and rows[0].cols[0] == "id"
        and rows[0].cols[1] == "body",
    )
    runner.check(
        "first row values are text",
        len(rows) == 2
        and rows[0].vals[0] == "1"
        and rows[0].vals[1] == "first",
    )
    runner.check(
        "second row get by name",
        len(rows) == 2 and rows[1].get("body") == "second",
    )


def _seed_file_database(path: String) raises:
    var db = Db.open(path)
    db.exec("DROP TABLE IF EXISTS persisted")
    db.exec("CREATE TABLE persisted (value TEXT NOT NULL)")
    db.exec("INSERT INTO persisted (value) VALUES (?)", _params("kept"))


def _read_file_database(path: String) raises -> String:
    var db = Db.open(path)
    var rows = db.query("SELECT value FROM persisted")
    if len(rows) != 1:
        return String()
    return rows[0].get("value")


def test_file_database(mut runner: Runner) raises:
    try:
        makedirs("build", exist_ok=True)
    except:
        pass
    var path = String("build/baldr_db_test.sqlite")
    _seed_file_database(path)
    runner.check(
        "file database survives close and reopen",
        _read_file_database(path) == "kept",
    )


def test_null_column(mut runner: Runner) raises:
    var db = Db.open(":memory:")
    var rows = db.query("SELECT NULL AS missing, '' AS empty_text")
    runner.check("NULL query returns one row", len(rows) == 1)
    runner.check(
        "NULL has empty text value",
        len(rows) == 1 and rows[0].vals[0] == "",
    )
    runner.check(
        "NULL sets is_null",
        len(rows) == 1 and rows[0].is_null[0],
    )
    runner.check(
        "empty TEXT is not NULL",
        len(rows) == 1 and rows[0].vals[1] == "" and not rows[0].is_null[1],
    )


def test_syntax_error(mut runner: Runner) raises:
    var db = Db.open(":memory:")
    var raised = False
    var contains_sql = False
    try:
        db.exec("SELEC 1")
    except error:
        var message = String(error)
        raised = message.find("syntax error") >= 0
        contains_sql = message.find("SELEC 1") >= 0
    runner.check("syntax error raises sqlite message", raised)
    runner.check("syntax error includes SQL", contains_sql)


def test_quoted_unicode_parameter(mut runner: Runner) raises:
    var db = Db.open(":memory:")
    db.exec("CREATE TABLE values_table (value TEXT NOT NULL)")
    var expected = String("O'Reilly — 火")
    db.exec("INSERT INTO values_table (value) VALUES (?)", _params(expected))
    var rows = db.query(
        "SELECT value FROM values_table WHERE value = ?", _params(expected)
    )
    runner.check(
        "quoted Unicode parameter round-trips byte-exact",
        len(rows) == 1 and rows[0].vals[0] == expected,
    )


def test_binding_count(mut runner: Runner) raises:
    var db = Db.open(":memory:")
    db.exec("CREATE TABLE pairs (left_value TEXT, right_value TEXT)")
    var raised = False
    try:
        db.exec(
            "INSERT INTO pairs (left_value, right_value) VALUES (?, ?)",
            _params("only-one"),
        )
    except error:
        var message = String(error)
        raised = message.find("expected 2 parameters, got 1") >= 0
    runner.check("fewer params than placeholders raises", raised)
    var rows = db.query("SELECT left_value FROM pairs")
    runner.check("failed bind inserts no row", len(rows) == 0)

    var too_many_raised = False
    try:
        _ = db.query("SELECT ? AS value", _params("one", "extra"))
    except error:
        var message = String(error)
        too_many_raised = message.find("expected 1 parameters, got 2") >= 0
    runner.check("more params than placeholders raises", too_many_raised)


def test_step_error_cleanup(mut runner: Runner) raises:
    var db = Db.open(":memory:")
    db.exec("CREATE TABLE unique_values (value TEXT UNIQUE)")
    db.exec("INSERT INTO unique_values (value) VALUES (?)", _params("once"))
    var raised = False
    var contains_sql = False
    try:
        db.exec("INSERT INTO unique_values (value) VALUES (?)", _params("once"))
    except error:
        var message = String(error)
        raised = message.find("UNIQUE constraint failed") >= 0
        contains_sql = message.find("INSERT INTO unique_values") >= 0
    runner.check("step error raises sqlite message", raised)
    runner.check("step error includes SQL", contains_sql)
    var rows = db.query("SELECT value FROM unique_values")
    runner.check(
        "connection remains usable after step error",
        len(rows) == 1 and rows[0].get("value") == "once",
    )


def test_empty_sql(mut runner: Runner) raises:
    var db = Db.open(":memory:")
    var raised = False
    try:
        db.exec("   ")
    except error:
        raised = String(error).find("SQL contains no statement") >= 0
    runner.check("empty SQL raises instead of using a null statement", raised)


def test_missing_column(mut runner: Runner) raises:
    var db = Db.open(":memory:")
    var rows = db.query("SELECT 1 AS present")
    var raised = False
    try:
        _ = rows[0].get("absent")
    except:
        raised = True
    runner.check("Row.get raises for absent column", raised)


def main() raises:
    var runner = Runner()
    test_memory_database(runner)
    test_file_database(runner)
    test_null_column(runner)
    test_syntax_error(runner)
    test_quoted_unicode_parameter(runner)
    test_binding_count(runner)
    test_step_error_cleanup(runner)
    test_empty_sql(runner)
    test_missing_column(runner)
    runner.summary()
    if runner.failures != 0:
        raise Error("baldr.db test failure")
