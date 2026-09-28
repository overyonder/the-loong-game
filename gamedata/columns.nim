## Loong columns (format.md): build a file of named columns and write it in
## one pass, or map one and use its columns in place.

import std/[memfiles, os, strutils, syncio, tables]

const
  ColumnsMagic*          = "LOONGCOL"
  ColumnsVersion*        = 1'u32
  ColumnsHeaderBytes     = 64
  ColumnsDirectoryBytes  = 80
  ColumnsNameBytes       = 48

type
  ColumnValueType* = enum
    columnU8 = 1, columnI8 = 2, columnU16 = 3, columnI16 = 4, columnU32 = 5,
    columnI32 = 6, columnU64 = 7, columnI64 = 8, columnF32 = 9, columnF64 = 10

  ColumnBeingWritten = object
    name:      string            ## `table.field`
    valueType: ColumnValueType
    count:     int               ## values appended so far
    bytes:     seq[byte]         ## the values end to end

  ColumnsFileWriter* = object
    kind:    string                        ## what the file holds, such as "game"
    columns: seq[ColumnBeingWritten]       ## in the order first appended
    index:   Table[string, int]            ## column name to its position

  ColumnInPlace* = object
    valueType*: ColumnValueType
    count*:     int
    address*:   pointer          ## the first value, inside the mapping

  ColumnsFileReader* = object
    mapping*: MemFile
    kind*:    string
    columns*: Table[string, ColumnInPlace]

proc columnValueTypeOf(T: typedesc): ColumnValueType =
  when T is uint8: columnU8
  elif T is int8: columnI8
  elif T is uint16: columnU16
  elif T is int16: columnI16
  elif T is uint32: columnU32
  elif T is int32: columnI32
  elif T is uint64: columnU64
  elif T is int64: columnI64
  elif T is float32: columnF32
  elif T is float64: columnF64
  else: {.error: "Loong columns hold fixed-size numbers only".}

proc initColumnsFileWriter*(kind: string): ColumnsFileWriter =
  ColumnsFileWriter(kind: kind)

proc columnFor(file: var ColumnsFileWriter, name: string,
    valueType: ColumnValueType): ptr ColumnBeingWritten =
  if name notin file.index:
    doAssert name.len < ColumnsNameBytes, "column name too long: " & name
    file.index[name] = file.columns.len
    file.columns.add ColumnBeingWritten(name: name, valueType: valueType)
  result = addr file.columns[file.index[name]]
  doAssert result.valueType == valueType, "column " & name & " changed type"

proc valueCount*(file: ColumnsFileWriter, name: string): int =
  ## Values appended to column `name` so far.
  if name in file.index: file.columns[file.index[name]].count else: 0

proc declareColumn*(file: var ColumnsFileWriter, name: string, T: typedesc) =
  ## Column `name` exists even if nothing is appended, so a table with no rows
  ## still has its columns.
  discard file.columnFor(name, columnValueTypeOf(T))

proc declareList*(file: var ColumnsFileWriter, name: string, T: typedesc) =
  ## List column `name` with no rows yet: its first start and its values, in
  ## the order `appendList` creates them.
  if name & "#" notin file.index: file.appendValue(name & "#", 0'u64)
  file.declareColumn(name, T)

proc appendValue*[T](file: var ColumnsFileWriter, name: string, value: T) =
  ## One value onto column `name`, created on first use.
  let column = file.columnFor(name, columnValueTypeOf(T))
  let at = column.bytes.len
  column.bytes.setLen(at + sizeof(T))
  var copy = value
  copyMem(addr column.bytes[at], addr copy, sizeof(T))
  inc column.count

proc appendList*[T](file: var ColumnsFileWriter, name: string, values: openArray[T]) =
  ## One row's list: its values onto `name` and where they end onto `name#`.
  let starts = name & "#"
  if starts notin file.index: file.appendValue(starts, 0'u64)
  let column = file.columnFor(name, columnValueTypeOf(T))
  if values.len > 0:
    let at = column.bytes.len
    column.bytes.setLen(at + values.len * sizeof(T))
    copyMem(addr column.bytes[at], unsafeAddr values[0], values.len * sizeof(T))
    column.count += values.len
  file.appendValue(starts, uint64(column.count))

proc appendString*(file: var ColumnsFileWriter, name: string, text: string) =
  ## One row's string, as a list of UTF-8 bytes.
  file.appendList(name, text.toOpenArrayByte(0, text.high))

proc writeColumnsFile*(file: ColumnsFileWriter, path: string) =
  ## The header, every column at an 8-byte boundary, then the directory. The
  ## file is written beside `path` and renamed over it, so readers never see
  ## a partial file.
  var offsets: seq[int]
  var position = ColumnsHeaderBytes
  for column in file.columns:
    offsets.add position
    position += (column.bytes.len + 7) and not 7
  let directoryOffset = position
  let fileLength = directoryOffset + file.columns.len * ColumnsDirectoryBytes
  var header = newSeq[byte](ColumnsHeaderBytes)
  let magic = ColumnsMagic
  copyMem(addr header[0], unsafeAddr magic[0], 8)
  var version = ColumnsVersion
  copyMem(addr header[8], addr version, 4)
  var columnCount = uint32(file.columns.len)
  copyMem(addr header[12], addr columnCount, 4)
  var directory = uint64(directoryOffset)
  copyMem(addr header[16], addr directory, 8)
  var length = uint64(fileLength)
  copyMem(addr header[24], addr length, 8)
  doAssert file.kind.len < 32
  if file.kind.len > 0: copyMem(addr header[32], unsafeAddr file.kind[0], file.kind.len)
  let temporary = path & ".partial"
  var output = syncio.open(temporary, fmWrite)
  discard output.writeBuffer(addr header[0], header.len)
  let padding = [0'u8, 0, 0, 0, 0, 0, 0, 0]
  for column in file.columns:
    if column.bytes.len > 0:
      discard output.writeBuffer(unsafeAddr column.bytes[0], column.bytes.len)
    let pad = ((column.bytes.len + 7) and not 7) - column.bytes.len
    if pad > 0: discard output.writeBuffer(unsafeAddr padding[0], pad)
  for index, column in file.columns:
    var entry = newSeq[byte](ColumnsDirectoryBytes)
    copyMem(addr entry[0], unsafeAddr column.name[0], column.name.len)
    entry[48] = byte(ord(column.valueType))
    var count = uint64(column.count)
    copyMem(addr entry[56], addr count, 8)
    var offset = uint64(offsets[index])
    copyMem(addr entry[64], addr offset, 8)
    discard output.writeBuffer(addr entry[0], entry.len)
  output.close()
  moveFile(temporary, path)

proc openColumnsFile*(path: string): ColumnsFileReader =
  ## Map a columns file and index its directory; columns stay in the mapping.
  result.mapping = memfiles.open(path)
  let base = cast[ptr UncheckedArray[byte]](result.mapping.mem)
  let magic = ColumnsMagic
  doAssert result.mapping.size >= ColumnsHeaderBytes and
    equalMem(base, unsafeAddr magic[0], 8), path & " is not a Loong columns file"
  var version, columnCount: uint32
  var directoryOffset, fileLength: uint64
  copyMem(addr version, addr base[8], 4)
  copyMem(addr columnCount, addr base[12], 4)
  copyMem(addr directoryOffset, addr base[16], 8)
  copyMem(addr fileLength, addr base[24], 8)
  doAssert version == ColumnsVersion and fileLength == uint64(result.mapping.size),
    path & " has an unknown version or is truncated"
  for byteIndex in 32 ..< 64:
    if base[byteIndex] == 0: break
    result.kind.add char(base[byteIndex])
  for entry in 0 ..< int(columnCount):
    let at = int(directoryOffset) + entry * ColumnsDirectoryBytes
    var name = ""
    for byteIndex in at ..< at + ColumnsNameBytes:
      if base[byteIndex] == 0: break
      name.add char(base[byteIndex])
    var count, offset: uint64
    copyMem(addr count, addr base[at + 56], 8)
    copyMem(addr offset, addr base[at + 64], 8)
    result.columns[name] = ColumnInPlace(
      valueType: ColumnValueType(base[at + 48]), count: int(count),
      address: addr base[int(offset)])

proc columnValues*[T](file: ColumnsFileReader, name: string): tuple[values: ptr UncheckedArray[T], count: int] =
  ## Column `name` in place, checked against the type the caller expects.
  let column = file.columns[name]
  doAssert column.valueType == columnValueTypeOf(T), "column " & name & " has another type"
  (cast[ptr UncheckedArray[T]](column.address), column.count)

proc listRow*[T](file: ColumnsFileReader, name: string, row: int): seq[T] =
  ## Row `row` of list column `name`.
  let starts = file.columnValues[:uint64](name & "#").values
  let values = file.columnValues[:T](name).values
  for index in int(starts[row]) ..< int(starts[row + 1]): result.add values[index]

proc stringRow*(file: ColumnsFileReader, name: string, row: int): string =
  ## Row `row` of string column `name`.
  for value in file.listRow[:uint8](name, row): result.add char(value)

proc rowCount*(file: ColumnsFileReader, name: string): int =
  ## Values in column `name`, or rows of list column `name`; 0 when absent.
  if name & "#" in file.columns: max(file.columns[name & "#"].count - 1, 0)
  elif name in file.columns: file.columns[name].count
  else: 0

proc numberAt*(file: ColumnsFileReader, name: string, row: int): float =
  ## Value `row` of numeric column `name`, whatever its type.
  let column = file.columns[name]
  doAssert row < column.count, "row past the end of column " & name
  case column.valueType
  of columnU8: float(cast[ptr UncheckedArray[uint8]](column.address)[row])
  of columnI8: float(cast[ptr UncheckedArray[int8]](column.address)[row])
  of columnU16: float(cast[ptr UncheckedArray[uint16]](column.address)[row])
  of columnI16: float(cast[ptr UncheckedArray[int16]](column.address)[row])
  of columnU32: float(cast[ptr UncheckedArray[uint32]](column.address)[row])
  of columnI32: float(cast[ptr UncheckedArray[int32]](column.address)[row])
  of columnU64: float(cast[ptr UncheckedArray[uint64]](column.address)[row])
  of columnI64: float(cast[ptr UncheckedArray[int64]](column.address)[row])
  of columnF32: float(cast[ptr UncheckedArray[float32]](column.address)[row])
  of columnF64: cast[ptr UncheckedArray[float64]](column.address)[row]

proc closeColumnsFile*(file: var ColumnsFileReader) =
  file.mapping.close()

proc appendValuesInPlace(file: var ColumnsFileWriter, name: string, column: ColumnInPlace) =
  let being = file.columnFor(name, column.valueType)
  let bytes = column.count * (case column.valueType
    of columnU8, columnI8: 1
    of columnU16, columnI16: 2
    of columnU32, columnI32, columnF32: 4
    of columnU64, columnI64, columnF64: 8)
  if bytes > 0:
    let at = being.bytes.len
    being.bytes.setLen(at + bytes)
    copyMem(addr being.bytes[at], column.address, bytes)
  being.count += column.count

proc mergeColumnsFiles*(inputs: openArray[string], output: string) =
  ## One file holding every input's rows, table by table, in input order. The
  ## inputs are one kind. `meta` and `enum.*` come from the first input, list
  ## starts are shifted past the rows before, and a u32 column named after a
  ## table (`side.game`) is shifted past that table's rows before.
  doAssert inputs.len > 0, "nothing to merge"
  var merged: ColumnsFileWriter
  var rowsBefore: Table[string, int]    ## table to rows already merged
  var valuesBefore: Table[string, int]  ## list column to values already merged
  for position, path in inputs:
    var file = openColumnsFile(path)
    if position == 0: merged = initColumnsFileWriter(file.kind)
    doAssert file.kind == merged.kind, path & " is another kind"
    var rows: Table[string, int]          ## this file's tables and row counts
    for name, column in file.columns:
      let table = name.split('.')[0]
      if name.endsWith('#'): rows[table] = column.count - 1
      elif not name.endsWith('?') and name & "#" notin file.columns: rows[table] = column.count
    for name, column in file.columns:
      let table = name.split('.')[0]
      let field = name.split('.')[^1]
      if table in ["meta", "enum"]:
        if position == 0: merged.appendValuesInPlace(name, column)
      elif name.endsWith('#'):
        let shift = uint64(valuesBefore.getOrDefault(name[0 ..^ 2]))
        let starts = cast[ptr UncheckedArray[uint64]](column.address)
        for index in (if merged.valueCount(name) == 0: 0 else: 1) ..< column.count:
          merged.appendValue(name, starts[index] + shift)
      elif column.valueType == columnU32 and field != table and field in rows:
        let shift = uint32(rowsBefore.getOrDefault(field))
        let rowsOf = cast[ptr UncheckedArray[uint32]](column.address)
        for index in 0 ..< column.count: merged.appendValue(name, rowsOf[index] + shift)
      else:
        merged.appendValuesInPlace(name, column)
    for name, column in file.columns:
      if name & "#" in file.columns:
        valuesBefore[name] = valuesBefore.getOrDefault(name) + column.count
    for table, count in rows: rowsBefore[table] = rowsBefore.getOrDefault(table) + count
    file.closeColumnsFile()
  merged.writeColumnsFile(output)
