package viewer

import "core:mem/virtual"

// A mapped Loong columns file (gamedata/format.md). Columns are slices
// into the mapping, used in place; nothing is parsed or copied.
Columns_File :: struct {
	data:    []byte,                  // the whole file, mapped read-only
	kind:    string,                  // what it holds, such as "game"
	entries: map[string]Column_Entry, // column name to where its values are
}

Column_Entry :: struct {
	value_type: u8,  // format.md value type code
	count:      int, // number of values
	offset:     int, // byte offset of the first value
}

COLUMNS_HEADER_BYTES :: 64
COLUMNS_DIRECTORY_BYTES :: 80
COLUMNS_NAME_BYTES :: 48

open_columns_file :: proc(path: string, allocator := context.allocator) -> (file: Columns_File, ok: bool) {
	data, error := virtual.map_file_from_path(path, {.Read})
	if error != nil || len(data) < COLUMNS_HEADER_BYTES || string(data[:8]) != "LOONGCOL" {return}
	version := (^u32le)(&data[8])^
	count := int((^u32le)(&data[12])^)
	directory := int((^u64le)(&data[16])^)
	length := int((^u64le)(&data[24])^)
	if version != 1 || length != len(data) || directory + count * COLUMNS_DIRECTORY_BYTES > len(data) {
		virtual.unmap_file(data)
		return
	}
	file.data = data
	file.kind = trim_name(data[32:64])
	file.entries = make(map[string]Column_Entry, count, allocator)
	for index in 0 ..< count {
		at := directory + index * COLUMNS_DIRECTORY_BYTES
		file.entries[trim_name(data[at:at + COLUMNS_NAME_BYTES])] = {
			value_type = data[at + 48],
			count      = int((^u64le)(&data[at + 56])^),
			offset     = int((^u64le)(&data[at + 64])^),
		}
	}
	return file, true
}

close_columns_file :: proc(file: ^Columns_File) {
	if file.data != nil {virtual.unmap_file(file.data)}
	file^ = {}
}

// A NUL-padded ASCII field, as a string into the mapping.
trim_name :: proc(bytes: []byte) -> string {
	for byte_value, index in bytes {if byte_value == 0 {return string(bytes[:index])}}
	return string(bytes)
}

column_type_code :: proc($T: typeid) -> u8 {
	when T == u8 {return 1} else when T == i8 {return 2} else when T == u16 {return 3} else when T == i16 {return 4} else when T == u32 {return 5} else when T == i32 {return 6} else when T == u64 {return 7} else when T == i64 {return 8} else when T == f32 {return 9} else when T == f64 {return 10} else {
		#panic("Loong columns hold fixed-size numbers only")
	}
}

// Column `name` in place; empty when the file lacks it or it has another type.
column_values :: proc(file: ^Columns_File, name: string, $T: typeid) -> []T {
	entry, found := file.entries[name]
	if !found || entry.value_type != column_type_code(T) {return nil}
	return ([^]T)(&file.data[entry.offset])[:entry.count]
}

// Row `row` of list column `name` (its values and `name#` starts).
list_row :: proc(file: ^Columns_File, name: string, starts_name: string, row: int, $T: typeid) -> []T {
	starts := column_values(file, starts_name, u64)
	values := column_values(file, name, T)
	if row + 1 >= len(starts) {return nil}
	return values[starts[row]:starts[row + 1]]
}

// Row `row` of string column `name`, into the mapping.
string_row :: proc(file: ^Columns_File, name: string, starts_name: string, row: int) -> string {
	return string(list_row(file, name, starts_name, row, u8))
}
