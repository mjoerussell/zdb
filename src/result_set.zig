const std = @import("std");
const Allocator = std.mem.Allocator;

const odbc = @import("odbc");

const sliceToValue = @import("util.zig").sliceToValue;

/// Given a struct, generate a new struct that can be used for ODBC row-wise binding. The conversion goes
/// roughly like this;
/// ```
/// struct Base {
///    field1: u32,
///    field2: []const u8,
///    field3: ?[]const u8
/// };
/// 
/// // Becomes....
///
/// FetchResult(Base).RowType {
///    field1: u32,
///    field1_len_or_ind: c_longlong,
///    field2: [200]u8,
///    field2_len_or_ind: c_longlong,
///    field3: [200]u8,
///    field3_len_or_ind: c_longlong
/// };
/// ```
pub fn FetchResult(comptime Target: type) type {
    const TypeInfo = std.builtin.TypeInfo;
    const TargetInfo = @typeInfo(Target);

    switch (TargetInfo) {
        .Struct => {
            const R = extern struct{};
            var ResultInfo = @typeInfo(R);

            var result_fields: [TargetInfo.Struct.fields.len * 2]TypeInfo.StructField = undefined;
            inline for (TargetInfo.Struct.fields) |field, i| {
                // Initialize all the fields of the StructField
                result_fields[i * 2] = field;

                // Get the target type of the generated struct
                const field_type_info = @typeInfo(field.field_type);
                const column_type = if (field_type_info == .Optional) field_type_info.Optional.child else field.field_type;
                const column_field_type = switch (@typeInfo(column_type)) {
                    .Pointer => |info| switch (info.size) {
                        .Slice => [200]info.child,
                        else => column_type
                    },
                    .Enum => |info| info.tag_type,
                    else => column_type
                };

                // Reset the field_type and default_value to be whatever was calculated
                // (default value is reset to null because it has to be a null of the correct type)
                result_fields[i * 2].field_type = column_field_type;
                result_fields[i * 2].default_value = null;
                // Generate the len_or_ind field to coincide with the main column field
                result_fields[(i * 2) + 1] = TypeInfo.StructField{
                    .name = field.name ++ "_len_or_ind",
                    .field_type = c_longlong,
                    .default_value = null,
                    .is_comptime = false,
                    .alignment = @alignOf(c_longlong)
                };
            }

            ResultInfo.Struct.fields = result_fields[0..];

            return struct {
                pub const RowType = @Type(ResultInfo);

                pub fn toTarget(allocator: *Allocator, row: RowType) !Target {
                    var item: Target = undefined;
                    inline for (std.meta.fields(Target)) |field| {
                        const row_data = @field(row, field.name);
                        const len_or_indicator = @field(row, field.name ++ "_len_or_ind");

                        const field_type_info = @typeInfo(field.field_type);
                        if (len_or_indicator == odbc.sys.SQL_NULL_DATA) {
                            // Handle null data. For Optional types, set the field to null. For non-optional types with
                            // a default value given, set the field to the default value. For all others, return
                            // an error
                            // @todo Not sure if an error is the most appropriate here, but it works for now
                            if (field_type_info == .Optional) {
                                @field(item, field.name) = null;
                            } else if (field.default_value) |default| {
                                @field(item, field.name) = default;
                            } else {
                                return error.InvalidNullValue;
                            }
                        } else {
                            // If the field in Base is optional, we just want to deal with its child type. The possibility of
                            // the value being null was handled above, so we can assume it's not here
                            const child_info = if (field_type_info == .Optional) @typeInfo(field_type_info.Optional.child) else field_type_info;
                            @field(item, field.name) = switch (child_info) {
                                .Pointer => |info| switch (info.size) {
                                    .Slice => blk: {
                                        // For slices, we want to allocate enough memory to hold the (presumably string) data
                                        // The string length might be indicated by a null byte, or it might be in len_or_indicator.
                                        const slice_length: usize = if (len_or_indicator == odbc.sys.SQL_NTS)
                                            std.mem.indexOf(u8, row_data[0..], &.{ 0x00 }) orelse row_data.len
                                        else
                                            @intCast(usize, len_or_indicator);

                                        var data_slice = try allocator.alloc(info.child, slice_length);
                                        std.mem.copy(info.child, data_slice, row_data[0..slice_length]);
                                        break :blk data_slice;
                                    },
                                    // @warn I've never seen this come up so it might not be strictly necessary, also might be broken
                                    else => row_data
                                },
                                // Convert enums back from their backing type to the enum value
                                .Enum => @intToEnum(field.field_type, row_data),
                                // All other data types can go right back
                                else => row_data
                            };
                        }
                    }

                    return item;
                }
            };
        },
        else => @compileError("The base type of FetchResult must be a struct, found " ++ @typeName(Target))
    }
}

/// RowBindingResultSet handles fetching and binding data from query executions
/// when the bind_type has been set to .row. In order to bind data this way,
/// `Base` must have fields that correspond with the columns in the result set.
/// The columns will be mapped to the fields in-order, regardless of what the fields
/// are named.
fn RowBindingResultSet(comptime Base: type) type {
    return struct {
        const Self = @This();

        pub const RowType = FetchResult(Base).RowType;
        const RowStatus = odbc.Types.StatementAttributeValue.RowStatus;

        rows: []RowType,
        row_status: []RowStatus,

        rows_fetched: usize = 0,
        current_row: usize = 0,

        is_first: bool = true,

        allocator: *Allocator,
        statement: odbc.Statement,

        /// Initialze the ResultSet with the given batch_size. batch_size will control how many results
        /// are fetched every time `statement.fetch()` is called.
        pub fn init(allocator: *Allocator, statement: odbc.Statement) !Self {
            var result: Self = undefined;
            result.statement = statement;
            result.allocator = allocator;
            result.rows_fetched = 0;
            result.current_row = 0;
            result.is_first = true;

            result.rows = try allocator.alloc(RowType, 20);
            result.row_status = try allocator.alloc(RowStatus, 20);
            
            try result.statement.setAttribute(.{ .RowBindType = @sizeOf(RowType) });
            try result.statement.setAttribute(.{ .RowArraySize = 20 });
            try result.statement.setAttribute(.{ .RowStatusPointer = result.row_status });

            try result.bindColumns();

            return result;
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.rows);
            self.allocator.free(self.row_status);
        }

        pub fn close(self: *Self) !void {
            self.statement.closeCursor() catch |err| {
                const errors = try self.statement.getErrors(self.allocator);
                for (errors) |e| {
                    if (e == .InvalidCursorState) break;
                } else return err;
            };

            try self.statement.deinit();
        }

        /// Keep fetching until all results have been retrieved.
        pub fn getAllRows(self: *Self) ![]Base {
            var results = try std.ArrayList(Base).initCapacity(self.allocator, 20);
            errdefer results.deinit();

            while (try self.next()) |item| {
                try results.append(item);
            }

            return results.toOwnedSlice();
        }

        /// Get the next available row. If all current rows have been read, this will attempt to
        /// fetch more results with `statement.fetch()`. If `statement.fetch()` returns `error.NoData`,
        /// this will return `null`.
        pub fn next(self: *Self) !?Base {
            if (self.is_first) {
                try self.statement.setAttribute(.{ .RowsFetchedPointer = &self.rows_fetched });
            }
            if (self.current_row >= self.rows_fetched) {
                self.statement.fetch() catch |err| switch (err) {
                    error.NoData => return null,
                    else => return err
                };
                self.current_row = 0;
                self.is_first = false;
            }

            while (self.current_row < self.rows_fetched and self.current_row < self.rows.len) : (self.current_row += 1) {
                switch (self.row_status[self.current_row]) {
                    .Success, .SuccessWithInfo => {
                        const item_row = self.rows[self.current_row];
                        self.current_row += 1;
                        return try FetchResult(Base).toTarget(self.allocator, item_row);
                    },
                    else => {}
                }
            }

            return null;
        }

        /// Bind each column of the result set to their associated row buffers.
        /// After this function is called + `statement.fetch()`, you can retrieve
        /// result data from this struct.
        pub fn bindColumns(self: *Self) !void {
            comptime var column_number: u16 = 1;
            inline for (std.meta.fields(RowType)) |field| {
                comptime if (std.mem.endsWith(u8, field.name, "_len_or_ind")) continue;

                const c_type = comptime blk: {
                    if (odbc.Types.CType.fromType(field.field_type)) |c_type| {
                        break :blk c_type;
                    } else {
                        @compileError("CType could not be derived for " ++ @typeName(Base) ++ "." ++ field.name ++ " (" ++ @typeName(field.field_type) ++ ")");
                    }
                };

                const FieldTypeInfo = @typeInfo(field.field_type);
                const FieldDataType = switch (FieldTypeInfo) {
                    .Pointer => |info| info.child,
                    .Array => |info| info.child,
                    else => field.field_type
                };

                const value_ptr: []FieldDataType = switch (FieldTypeInfo) {
                    .Pointer => switch (FieldTypeInfo.Pointer.size) {
                        .One => @ptrCast([*]FieldDataType, @field(self.rows[0], field.name))[0..1],
                        else => @field(self.rows[0], field.name)[0..]
                    },
                    .Array => @field(self.rows[0], field.name)[0..],
                    else => @ptrCast([*]FieldDataType, &@field(self.rows[0], field.name))[0..1]
                };
                
                try self.statement.bindColumn(
                    column_number, 
                    c_type, 
                    value_ptr,
                    &@field(self.rows[0], field.name ++ "_len_or_ind")
                );
                
                column_number += 1;
            }
        }
    };
}

/// `Row` represents a single record when `bind_type` is set to `.column`.
pub const Row = struct {
    const Self = @This();

    const Column = struct {
        name: []const u8,
        sql_type: odbc.Types.SqlType,
        data: []u8,
        indicator: c_longlong,
    };

    columns: []Column,

    statement: *odbc.Statement,
    allocator: *Allocator,


    fn init(allocator: *Allocator, statement: *odbc.Statement, num_columns: usize) !Self {
        var row: Self = undefined;
            
        row.statement = statement;
        row.allocator = allocator;

        row.columns = try allocator.alloc(Column, num_columns);

        for (row.columns) |*column, column_index| {
            column.sql_type = (try row.statement.getColumnAttribute(column_index + 1, .Type)).Type;
            column.name = (try row.statement.getColumnAttribute(column_index + 1, .BaseColumnName)).BaseColumnName;

            const column_size = (try row.statement.getColumnAttribute(column_index + 1, .OctetLength)).OctetLength;

            column.data = try allocator.alloc(u8, @intCast(usize, column_size));

            try row.statement.bindColumn(
                @intCast(u16, column_index + 1),
                column.sql_type.defaultCType(),
                column.data,
                &column.indicator
            );
        }

        return row;
    }

    fn deinit(self: *Self) void {
        for (self.columns) |*column| {
            self.allocator.free(column.name);
            self.allocator.free(column.data);
        }
        self.allocator.free(self.columns);
    }

    /// Get a value from a column using the column name. Will attempt to convert whatever bytes
    /// are stored for the column into `ColumnType`.
    pub fn get(self: *Self, comptime ColumnType: type, column_name: []const u8) !ColumnType {
        const column_index = for (self.columns) |column, index| {
            if (std.mem.eql(u8, column.name, column_name)) break index;
        } else return error.ColumnNotFound;

        return try self.getWithIndex(ColumnType, column_index + 1);
    }

    /// Get a value from a column using the column index. Column indices start from 1. Will attempt to
    /// convert whatever bytes are stored for the column into `ColumnType`.
    pub fn getWithIndex(self: *Self, comptime ColumnType: type, column_index: usize) !ColumnType {
        const target_column = self.columns[column_index - 1];

        if (target_column.indicator == odbc.sys.SQL_NULL_DATA) {
            return switch (@typeInfo(ColumnType)) {
                .Optional => null,
                else => error.InvalidNullValue,
            };
        }

        return switch (@typeInfo(ColumnType)) {
            .Pointer => |info| switch (info.size) {
                .Slice => blk: {
                    const slice_length = if (target_column.indicator == odbc.sys.SQL_NTS)
                        std.mem.indexOf(u8, target_column.data, &.{ 0x00 }) orelse target_column.data.len
                    else
                        @intCast(usize, target_column.indicator);

                    if (slice_length > target_column.data.len) {
                        break :blk error.InvalidString;
                    }

                    var return_buffer = try self.allocator.alloc(u8, slice_length);
                    std.mem.copy(u8, return_buffer, target_column.data[0..slice_length]);

                    break :blk return_buffer;
                },
                else => sliceToValue(ColumnType, target_column.data[0..@intCast(usize, target_column.indicator)]),
            },
            else => sliceToValue(ColumnType, target_column.data[0..@intCast(usize, target_column.indicator)])
        };
    }
};

/// ColumnBindingResultSet is used when `bind_type` is set to `.column`. This will happen when a given struct
/// has a function called `fromRow` declared on it. This result set will use that function to convert data
/// from generic `Row` types to `Base`.
fn ColumnBindingResultSet(comptime Base: type) type {
    return struct {
        const Self = @This();

        row: Row,

        statement: odbc.Statement,
        allocator: *Allocator,

        pub fn init(allocator: *Allocator, statement: odbc.Statement) !Self {
            var result: Self = undefined;
            result.statement = statement;
            result.allocator = allocator;

            const num_columns = try result.statement.numResultColumns();
            result.row = try Row.init(allocator, &result.statement, num_columns);

            return result;
        }

        pub fn deinit(self: *Self) void {
            self.row.deinit();
        }
        
        /// Keep fetching until all of the rows have been retrieved.
        pub fn getAllRows(self: *Self) ![]Base {
            var results = try std.ArrayList(Base).initCapacity(self.allocator, 50);
            errdefer results.deinit();

            while (try self.next()) |item| {
                try results.append(item);
            }

            return results.toOwnedSlice();
        }
        
        /// Get the next available result. This calls `statement.fetch()` every time, because column-wise
        /// binding only allows for binding 1 row at a time. When `statement.fetch()` returns `error.NoData`,
        /// this will return `null`.
        pub fn next(self: *Self) !?Base {
            self.statement.fetch() catch |err| switch (err) {
                error.NoData => return null,
                else => return err
            };

            return try Base.fromRow(&self.row, self.allocator);    
        }
    };
}

pub const BindType = enum(u1) {
    row,
    column
};

pub fn ResultSet(comptime Base: type) type {
    comptime const bind_type: BindType = if (@hasDecl(Base, "fromRow")) .column else .row; 
    return switch (bind_type) {
        .row => RowBindingResultSet(Base),
        .column => ColumnBindingResultSet(Base),
    };
}