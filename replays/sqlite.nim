## The few SQLite calls the replay collector's manifest needs, linked against
## the system library (`just tools-build`).

type
  Database* = ptr object
  Statement = ptr object
  SqliteError* = object of CatchableError

const
  SqliteOk = 0
  SqliteRow = 100
  SqliteDone = 101
  OpenReadWriteCreate = 0x2 or 0x4
  Transient = cast[pointer](-1)   ## SQLITE_TRANSIENT: SQLite copies bound text

{.passL: "-lsqlite3".}
{.push importc, cdecl.}
proc sqlite3_open_v2(path: cstring, database: var Database, flags: cint, vfs: cstring): cint
proc sqlite3_busy_timeout(database: Database, milliseconds: cint): cint
proc sqlite3_exec(database: Database, sql: cstring, callback, argument: pointer, error: pointer): cint
proc sqlite3_prepare_v2(database: Database, sql: cstring, bytes: cint, statement: var Statement, tail: pointer): cint
proc sqlite3_bind_int64(statement: Statement, index: cint, value: int64): cint
proc sqlite3_bind_text(statement: Statement, index: cint, text: cstring, bytes: cint, destructor: pointer): cint
proc sqlite3_step(statement: Statement): cint
proc sqlite3_column_count(statement: Statement): cint
proc sqlite3_column_text(statement: Statement, column: cint): cstring
proc sqlite3_finalize(statement: Statement): cint
proc sqlite3_errmsg(database: Database): cstring
proc sqlite3_close(database: Database): cint
{.pop.}

type Value* = object
  ## A bound parameter: an integer or text.
  case isText*: bool
  of true: text*: string
  of false: number*: int64

proc toValue*(value: int64): Value = Value(isText: false, number: value)
proc toValue*(value: int): Value = Value(isText: false, number: int64(value))
proc toValue*(value: string): Value = Value(isText: true, text: value)

proc check(database: Database, status: cint) =
  if status != SqliteOk: raise newException(SqliteError, $sqlite3_errmsg(database))

proc openDatabase*(path: string, busyMilliseconds: int): Database =
  if sqlite3_open_v2(path, result, OpenReadWriteCreate, nil) != SqliteOk:
    raise newException(SqliteError, "cannot open " & path)
  result.check sqlite3_busy_timeout(result, cint(busyMilliseconds))

proc execute*(database: Database, sql: string) =
  ## Statements without parameters or rows.
  database.check sqlite3_exec(database, sql, nil, nil, nil)

proc rows*(database: Database, sql: string, values: varargs[Value, toValue]): seq[seq[string]] =
  ## Every row of a query, each column as text; runs a statement with none.
  var statement: Statement
  database.check sqlite3_prepare_v2(database, sql, -1, statement, nil)
  defer: discard sqlite3_finalize(statement)
  for index, value in values:
    let position = cint(index + 1)
    if value.isText:
      database.check sqlite3_bind_text(statement, position, value.text.cstring, cint(value.text.len), Transient)
    else:
      database.check sqlite3_bind_int64(statement, position, value.number)
  while true:
    let status = sqlite3_step(statement)
    if status == SqliteDone: break
    if status != SqliteRow: raise newException(SqliteError, $sqlite3_errmsg(database))
    var row: seq[string]
    for column in 0 ..< sqlite3_column_count(statement):
      let text = sqlite3_column_text(statement, column)
      row.add(if text == nil: "" else: $text)
    result.add row

proc close*(database: Database) = discard sqlite3_close(database)
