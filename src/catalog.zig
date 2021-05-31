const std = @import("std");
const Allocator = std.mem.Allocator;

const odbc = @import("odbc");

pub const Column = struct {
    table_category: ?[]const u8,
    table_schema: ?[]const u8,
    table_name: []const u8,
    column_name: []const u8,
    data_type: u16,
    type_name: []const u8,
    column_size: ?u32,
    buffer_length: ?u32,
    decimal_digits: ?u16,
    num_prec_radix: ?u16,
    nullable: odbc.Types.Nullable,
    remarks: ?[]const u8,
    column_def: ?[]const u8,
    sql_data_type: odbc.Types.SqlType,
    sql_datetime_sub: ?u16,
    char_octet_length: ?u32,
    ordinal_position: u32,
    is_nullable: ?[]const u8,

    pub fn deinit(self: *Column, allocator: *Allocator) void {
        if (self.table_category) |tc| allocator.free(tc);
        if (self.table_schema) |ts| allocator.free(ts);
        allocator.free(self.table_name);
        allocator.free(self.column_name);
        allocator.free(self.type_name);
        if (self.remarks) |r| allocator.free(r);
        if (self.column_def) |cd| allocator.free(cd);
        if (self.is_nullable) |in| allocator.free(in);
    }
};

pub const Table = struct {
    catalog: ?[]const u8,
    schema: ?[]const u8,
    name: ?[]const u8,
    table_type: ?[]const u8,
    remarks: ?[]const u8,

    pub fn deinit(self: *Table, allocator: *Allocator) void {
        if (self.catalog) |cat| allocator.free(cat);
        if (self.schema) |schema| allocator.free(schema);
        if (self.name) |name| allocator.free(name);
        if (self.table_type) |table_type| allocator.free(table_type);
        if (self.remarks) |remarks| allocator.free(remarks);
    }
};