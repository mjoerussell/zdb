const std = @import("std");
const Allocator = std.mem.Allocator;

const odbc = @import("zig-odbc");
const RowStatus = odbc.Types.StatementAttributeValue.RowStatus;
const Statement = odbc.Statement;
const CType = odbc.Types.CType;

const util = @import("util.zig");
const sliceToValue = util.sliceToValue;

const log = std.log.scoped(.result_set);

const ResultSet = @This();

/// Given a struct, generate a new struct that can be used for ODBC row-wise binding. The conversion goes
/// roughly like this;
/// ```
/// const Base = struct {
///    field1: u32,
///    field2: []const u8,
///    field3: ?[]const u8
/// };
///
/// // Becomes....
///
/// const FetchResult(Base).RowType = extern struct {
///    field1: u32,
///    field1_len_or_ind: c_longlong,
///    field2: [200]u8,
///    field2_len_or_ind: c_longlong,
///    field3: [200]u8,
///    field3_len_or_ind: c_longlong
/// };
/// ```
pub fn FetchResult(comptime Target: type) type {
    const Type = std.builtin.Type;
    const TargetInfo = @typeInfo(Target);

    if (TargetInfo != .Struct) {
        @compileError("The base type of FetchResult must be a struct, found " ++ @typeName(Target));
    }

    const R = extern struct {};
    var ResultInfo = @typeInfo(R);

    var result_fields: [TargetInfo.Struct.fields.len * 2]Type.StructField = undefined;
    inline for (TargetInfo.Struct.fields, 0..) |field, i| {
        // Initialize all the fields of the StructField
        result_fields[i * 2] = field;

        // Get the target type of the generated struct
        const field_type_info = @typeInfo(field.type);
        const column_type = if (field_type_info == .Optional) field_type_info.Optional.child else field.type;
        const column_field_type = switch (@typeInfo(column_type)) {
            .Pointer => |info| switch (info.size) {
                .Slice => [200]info.child,
                else => column_type,
            },
            .Enum => |info| info.tag_type,
            else => column_type,
        };

        // Reset the field_type and default_value to be whatever was calculated
        // (default value is reset to null because it has to be a null of the correct type)
        result_fields[i * 2].type = column_field_type;
        result_fields[i * 2].default_value = null;
        // Generate the len_or_ind field to coincide with the main column field
        result_fields[(i * 2) + 1] = Type.StructField{ .name = field.name ++ "_len_or_ind", .type = i64, .default_value = null, .is_comptime = false, .alignment = @alignOf(c_longlong) };
    }

    ResultInfo.Struct.fields = result_fields[0..];

    return @Type(ResultInfo);
}

fn toTarget(comptime Target: type, allocator: Allocator, row: FetchResult(Target)) error{ InvalidNullValue, OutOfMemory }!Target {
    var item: Target = undefined;
    inline for (std.meta.fields(Target)) |field| {
        @setEvalBranchQuota(1_000_000);
        const row_data = @field(row, field.name);
        const len_or_indicator = @field(row, field.name ++ "_len_or_ind");

        const field_type_info = @typeInfo(field.type);
        if (len_or_indicator == odbc.sys.SQL_NULL_DATA) {
            // Handle null data. For Optional types, set the field to null. For non-optional types with
            // a default value given, set the field to the default value. For all others, return
            // an error
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
                            std.mem.indexOf(u8, row_data[0..], &.{0x00}) orelse row_data.len
                        else
                            @as(usize, @intCast(len_or_indicator));

                        const data_slice = try allocator.alloc(info.child, slice_length);
                        std.mem.copy(info.child, data_slice, row_data[0..slice_length]);
                        break :blk data_slice;
                    },
                    // @warn I've never seen this come up so it might not be strictly necessary, also might be broken
                    else => row_data,
                },
                // Convert enums back from their backing type to the enum value
                .Enum => @as(field.type, @enumFromInt(row_data)),
                // All other data types can go right back
                else => row_data,
            };
        }
    }

    return item;
}

/// `Row` represents a single record for `ColumnBindingResultSet`.
pub const Row = struct {
    pub const FormatOptions = struct {
        char: []const u8 = "{c}",
        varchar: []const u8 = "{s}",
        long_varchar: []const u8 = "{s}",
        w_char: []const u8 = "{u}",
        w_varchar: []const u8 = "{u}",
        w_long_varchar: []const u8 = "{u}",
        decimal: []const u8 = "{d:.5}",
        numeric: []const u8 = "{d:.5}",
        small_int: []const u8 = "{}",
        integer: []const u8 = "{}",
        real: []const u8 = "{d:.5}",
        float: []const u8 = "{d:.5}",
        double: []const u8 = "{d:.5}",
        bit: []const u8 = "{}",
        tiny_int: []const u8 = "{}",
        big_int: []const u8 = "{}",
        binary: []const u8 = "{b}",
        var_binary: []const u8 = "{b}",
        long_var_binary: []const u8 = "{b}",
        date: []const u8 = "{}",
        time: []const u8 = "{}",
        timestamp: []const u8 = "{}",
        timestamp_ltz: []const u8 = "{}",
        interval_month: []const u8 = "{}",
        interval_year: []const u8 = "{}",
        interval_year_to_month: []const u8 = "{}",
        interval_day: []const u8 = "{}",
        interval_hour: []const u8 = "{}",
        interval_minute: []const u8 = "{}",
        interval_second: []const u8 = "{}",
        interval_day_to_hour: []const u8 = "{}",
        interval_day_to_minute: []const u8 = "{}",
        interval_day_to_second: []const u8 = "{}",
        interval_hour_to_minute: []const u8 = "{}",
        interval_hour_to_second: []const u8 = "{}",
        interval_minute_to_second: []const u8 = "{}",
        guid: []const u8 = "{}",
    };

    const Column = struct {
        name: []const u8,
        data: []u8,
        indicator: c_longlong,
        sql_type: odbc.Types.SqlType,

        fn isNull(column: Column) bool {
            return column.indicator == odbc.sys.SQL_NULL_DATA;
        }

        fn getData(column: *const Column) []u8 {
            if (column.indicator == odbc.sys.SQL_NTS) {
                const null_index = std.mem.indexOf(u8, &.{0}, column.data) orelse column.data.len;
                if (null_index > column.data.len) {
                    return column.data;
                }
                return column.data[0..null_index];
            }

            return column.data[0..@as(usize, @intCast(column.indicator))];
        }
    };

    columns: []Column,

    fn init(allocator: Allocator, num_columns: usize) !Row {
        return Row{
            .columns = try allocator.alloc(Column, num_columns),
        };
    }

    fn deinit(self: *Row, allocator: Allocator) void {
        allocator.free(self.columns);
    }

    /// Get a value from a column using the column name. Will attempt to convert whatever bytes
    /// are stored for the column into `ColumnType`.
    pub fn get(self: *Row, comptime ColumnType: type, column_name: []const u8) !ColumnType {
        const column_index = for (self.columns, 0..) |column, index| {
            if (std.mem.eql(u8, column.name, column_name)) break index;
        } else return error.ColumnNotFound;

        return try self.getWithIndex(ColumnType, column_index + 1);
    }

    /// Get a value from a column using the column index. Column indices start from 1. Will attempt to
    /// convert whatever bytes are stored for the column into `ColumnType`.
    pub fn getWithIndex(self: *Row, comptime ColumnType: type, column_index: usize) error{InvalidNullValue}!ColumnType {
        const target_column = self.columns[column_index - 1];

        if (target_column.isNull()) {
            return switch (@typeInfo(ColumnType)) {
                .Optional => null,
                else => error.InvalidNullValue,
            };
        }

        const column_data = target_column.getData();

        if (@typeInfo(ColumnType) == .Pointer and @typeInfo(ColumnType).Pointer.size == .Slice) {
            return column_data;
        }

        return sliceToValue(ColumnType, column_data);
    }

    pub fn printColumn(row: *Row, column_name: []const u8, comptime format_options: FormatOptions, writer: anytype) !void {
        const column_index = for (row.columns, 0..) |column, index| {
            if (std.mem.eql(u8, column.name, column_name)) break index;
        } else return error.ColumnNotFound;

        try row.printColumnAtIndex(column_index + 1, format_options, writer);
    }

    pub fn printColumnAtIndex(row: *Row, column_index: usize, comptime format_options: FormatOptions, writer: anytype) !void {
        const target_column = row.columns[column_index - 1];

        if (target_column.isNull()) return;

        const column_data = target_column.getData();

        switch (target_column.sql_type) {
            .Char => try writer.print(format_options.char, .{column_data[0]}),
            .Varchar => try writer.print(format_options.varchar, .{column_data}),
            .LongVarchar => try writer.print(format_options.long_varchar, .{column_data}),
            .WChar => try writer.print(format_options.w_char, .{sliceToValue(u16, column_data)}),
            .WVarchar => {
                const utf8_column_data = sliceToValue([]u16, column_data);
                for (utf8_column_data) |wchar| {
                    try writer.print(format_options.w_varchar, .{wchar});
                }
            },
            .WLongVarchar => {
                const utf8_column_data = sliceToValue([]u16, column_data);
                for (utf8_column_data) |wchar| {
                    try writer.print(format_options.w_varchar, .{wchar});
                }
            },
            .Decimal => try writer.print(format_options.decimal, .{sliceToValue(f32, column_data)}),
            .Float => try writer.print(format_options.float, .{sliceToValue(f32, column_data)}),
            .Numeric => try writer.print(format_options.numeric, .{sliceToValue(CType.SqlNumeric, column_data).toFloat(f64)}),
            .Real => try writer.print(format_options.real, .{sliceToValue(f64, column_data)}),
            .Double => try writer.print(format_options.double, .{sliceToValue(f64, column_data)}),
            .Bit => try writer.print(format_options.bit, .{column_data[0]}),
            .TinyInt => try writer.print(format_options.tiny_int, .{sliceToValue(i8, column_data)}),
            .SmallInt => try writer.print(format_options.small_int, .{sliceToValue(i16, column_data)}),
            .Integer => try writer.print(format_options.integer, .{sliceToValue(i32, column_data)}),
            .BigInt => try writer.print(format_options.big_int, .{sliceToValue(i64, column_data)}),
            .Binary => try writer.print(format_options.binary, .{column_data[0]}),
            .VarBinary => {
                for (column_data) |c| {
                    try writer.print(format_options.var_binary, .{c});
                }
            },
            .LongVarBinary => {
                for (column_data) |c| {
                    try writer.print(format_options.long_var_binary, .{c});
                }
            },
            .Date => try writer.print(format_options.date, .{sliceToValue(CType.SqlDate, column_data)}),
            .Time => try writer.print(format_options.time, .{sliceToValue(CType.SqlTime, column_data)}),
            .Timestamp => try writer.print(format_options.timestamp, .{sliceToValue(CType.SqlTimestamp, column_data)}),
            .TimestampLtz => try writer.print(format_options.timestamp_ltz, .{sliceToValue(CType.SqlTimestamp, column_data)}),
            .IntervalMonth => try writer.print(format_options.interval_month, .{sliceToValue(CType.Interval, column_data)}),
            .IntervalYear => try writer.print(format_options.interval_year, .{sliceToValue(CType.Interval, column_data)}),
            .IntervalYearToMonth => try writer.print(format_options.interval_year_to_month, .{sliceToValue(CType.Interval, column_data)}),
            .IntervalDay => try writer.print(format_options.interval_day, .{sliceToValue(CType.Interval, column_data)}),
            .IntervalHour => try writer.print(format_options.interval_hour, .{sliceToValue(CType.Interval, column_data)}),
            .IntervalMinute => try writer.print(format_options.interval_minute, .{sliceToValue(CType.Interval, column_data)}),
            .IntervalSecond => try writer.print(format_options.interval_second, .{sliceToValue(CType.Interval, column_data)}),
            .IntervalDayToHour => try writer.print(format_options.interval_day_to_hour, .{sliceToValue(CType.Interval, column_data)}),
            .IntervalDayToMinute => try writer.print(format_options.interval_day_to_minute, .{sliceToValue(CType.Interval, column_data)}),
            .IntervalDayToSecond => try writer.print(format_options.interval_day_to_second, .{sliceToValue(CType.Interval, column_data)}),
            .IntervalHourToMinute => try writer.print(format_options.interval_hour_to_minute, .{sliceToValue(CType.Interval, column_data)}),
            .IntervalHourToSecond => try writer.print(format_options.interval_hour_to_second, .{sliceToValue(CType.Interval, column_data)}),
            .IntervalMinuteToSecond => try writer.print(format_options.interval_minute_to_second, .{sliceToValue(CType.Interval, column_data)}),
            .Guid => try writer.print(format_options.guid, .{sliceToValue(CType.SqlGuid, column_data)}),
        }
    }
};

fn ItemIterator(comptime ItemType: type) type {
    return struct {
        pub const Self = @This();
        pub const RowType = FetchResult(ItemType);

        rows: []RowType,
        row_status: []RowStatus,

        rows_fetched: usize = 0,
        current_row: usize = 0,

        is_first: bool = true,

        allocator: Allocator,
        statement: odbc.Statement,

        /// Initialze the ResultSet with the given `row_count`. `row_count` will control how many results
        /// are fetched every time `statement.fetch()` is called.
        pub fn init(allocator: Allocator, statement: odbc.Statement, row_count: usize) !Self {
            var result: Self = .{
                .allocator = allocator,
                .statement = statement,
                .rows = try allocator.alloc(RowType, row_count),
                .row_status = try allocator.alloc(RowStatus, row_count),
            };
            errdefer result.deinit();

            try result.statement.setAttribute(.{ .RowBindType = @sizeOf(RowType) });
            try result.statement.setAttribute(.{ .RowArraySize = row_count });
            try result.statement.setAttribute(.{ .RowStatusPointer = result.row_status });

            try result.bindColumns();

            return result;
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.rows);
            self.allocator.free(self.row_status);
        }

        /// Keep fetching until all results have been retrieved.
        pub fn getAllRows(self: *Self) ![]ItemType {
            var results = try std.ArrayList(ItemType).initCapacity(self.allocator, 20);
            errdefer results.deinit();

            while (try self.next()) |item| {
                try results.append(item);
            }

            return results.toOwnedSlice();
        }

        /// Get the next available row. If all current rows have been read, this will attempt to
        /// fetch more results with `statement.fetch()`. If `statement.fetch()` returns `error.NoData`,
        /// this will return `null`.
        pub fn next(self: *Self) !?ItemType {
            if (self.is_first) {
                try self.statement.setAttribute(.{ .RowsFetchedPointer = &self.rows_fetched });
                self.is_first = false;
            }

            while (true) {
                if (self.current_row >= self.rows_fetched) {
                    const has_data = try self.statement.fetch();
                    if (!has_data) return null;
                    self.current_row = 0;
                }

                while (self.current_row < self.rows_fetched and self.current_row < self.rows.len) : (self.current_row += 1) {
                    switch (self.row_status[self.current_row]) {
                        .Success, .SuccessWithInfo, .Error => {
                            const item_row = self.rows[self.current_row];
                            self.current_row += 1;
                            return toTarget(ItemType, self.allocator, item_row) catch |err| switch (err) {
                                error.InvalidNullValue => continue,
                                else => return err,
                            };
                        },
                        else => {},
                    }
                }
            }
        }

        /// Bind each column of the result set to their associated row buffers.
        /// After this function is called + `statement.fetch()`, you can retrieve
        /// result data from this struct.
        fn bindColumns(self: *Self) !void {
            @setEvalBranchQuota(1_000_000);
            comptime var column_number: u16 = 1;

            inline for (std.meta.fields(RowType)) |field| {
                comptime if (std.mem.endsWith(u8, field.name, "_len_or_ind")) continue;

                const c_type = comptime blk: {
                    if (odbc.Types.CType.fromType(field.type)) |c_type| {
                        break :blk c_type;
                    } else {
                        @compileError("CType could not be derived for " ++ @typeName(ItemType) ++ "." ++ field.name ++ " (" ++ @typeName(field.type) ++ ")");
                    }
                };

                const FieldType = @typeInfo(field.type);
                const FieldDataType = switch (FieldType) {
                    .Pointer => |info| info.child,
                    .Array => |info| info.child,
                    else => field.type,
                };

                const value_ptr: []FieldDataType = switch (FieldType) {
                    .Pointer => switch (FieldType.Pointer.size) {
                        .One => @as([*]FieldDataType, @ptrCast(@field(self.rows[0], field.name)))[0..1],
                        else => @field(self.rows[0], field.name)[0..],
                    },
                    .Array => @field(self.rows[0], field.name)[0..],
                    else => @as([*]FieldDataType, @ptrCast(&@field(self.rows[0], field.name)))[0..1],
                };

                try self.statement.bindColumn(column_number, c_type, value_ptr, @as([*]i64, @ptrCast(&@field(self.rows[0], field.name ++ "_len_or_ind"))), null);

                column_number += 1;
            }
        }
    };
}

/// `RowIterator` is used to fetch query results when you don't have a matching `struct` type to hold each row.
/// This will create a binding for each column in the result set, and then return each row in a `Row` struct
/// one at a time.
const RowIterator = struct {
    /// Represents a single column of the result set. Each `Column` instance can hold *multiple rows* of data for
    /// that column. The number of rows is limited by the `row_count` parameter passed when initializng `RowIterator`.
    const Column = struct {
        name: []const u8,
        sql_type: odbc.Types.SqlType,
        data: []u8,
        octet_length: usize,
        indicator: []i64,

        fn deinit(column: *Column, allocator: Allocator) void {
            allocator.free(column.name);
            allocator.free(column.data);
            allocator.free(column.indicator);
        }
    };

    columns: []Column,
    row: Row,
    row_status: []RowStatus,
    is_first: bool = true,
    current_row: usize = 0,
    rows_fetched: usize = 0,

    statement: odbc.Statement,

    pub fn init(allocator: Allocator, statement: odbc.Statement, row_count: usize) !RowIterator {
        const num_columns = try statement.numResultColumns();

        const columns = try allocator.alloc(Column, num_columns);
        errdefer {
            for (columns) |*c| c.deinit(allocator);
            allocator.free(columns);
        }

        const row_status = try allocator.alloc(RowStatus, row_count);
        errdefer allocator.free(row_status);

        try statement.setAttribute(.{ .RowBindType = odbc.sys.SQL_BIND_BY_COLUMN });
        try statement.setAttribute(.{ .RowArraySize = row_count });
        try statement.setAttribute(.{ .RowStatusPointer = row_status });

        for (columns, 0..) |*column, column_index| {
            column.sql_type = (try statement.getColumnAttribute(allocator, column_index + 1, .Type)).Type;
            column.name = (try statement.getColumnAttribute(allocator, column_index + 1, .BaseColumnName)).BaseColumnName;

            column.octet_length = if (statement.getColumnAttribute(allocator, column_index + 1, .OctetLength)) |attr|
                @as(usize, @intCast(attr.OctetLength))
            else |_|
                0;

            if (column.octet_length == 0) {
                const length = (try statement.getColumnAttribute(allocator, column_index + 1, .Length)).Length;
                column.octet_length = @as(usize, @intCast(length));
            }

            column.data = try allocator.alloc(u8, row_count * column.octet_length);
            column.indicator = try allocator.alloc(i64, row_count);

            try statement.bindColumn(@as(u16, @intCast(column_index + 1)), column.sql_type.defaultCType(), column.data, column.indicator.ptr, column.octet_length);
        }

        return RowIterator{
            .statement = statement,
            .row_status = row_status,
            .columns = columns,
            .row = try Row.init(allocator, num_columns),
        };
    }

    pub fn deinit(self: *RowIterator, allocator: Allocator) void {
        for (self.columns) |*column| column.deinit(allocator);

        allocator.free(self.columns);
        allocator.free(self.row_status);
        self.row.deinit(allocator);
    }

    pub fn next(self: *RowIterator) !?*Row {
        if (self.is_first) {
            try self.statement.setAttribute(.{ .RowsFetchedPointer = &self.rows_fetched });
            self.is_first = false;
        }

        while (true) {
            if (self.current_row >= self.rows_fetched) {
                const has_data = try self.statement.fetch();
                if (!has_data) return null;
                self.current_row = 0;
            }

            for (self.row_status[self.current_row..]) |row_status| {
                defer self.current_row += 1;
                if (self.current_row >= self.rows_fetched) break;

                switch (row_status) {
                    .Success, .SuccessWithInfo, .Error => {
                        for (self.row.columns, 0..) |*row_column, column_index| {
                            const current_column = self.columns[column_index];
                            row_column.name = current_column.name;

                            const data_start_index = self.current_row * current_column.octet_length;
                            const data_end_index = data_start_index + current_column.octet_length;
                            row_column.data = current_column.data[data_start_index..data_end_index];
                            row_column.indicator = current_column.indicator[self.current_row];
                            row_column.sql_type = current_column.sql_type;
                        }

                        return &self.row;
                    },
                    else => {},
                }
            }
        }
    }
};

statement: Statement,

pub fn init(statement: Statement) ResultSet {
    return ResultSet{
        .statement = statement,
    };
}

pub fn itemIterator(result_set: ResultSet, comptime ItemType: type, allocator: Allocator) !ItemIterator(ItemType) {
    return try ItemIterator(ItemType).init(allocator, result_set.statement, 10);
}

pub fn rowIterator(result_set: ResultSet, allocator: Allocator) !RowIterator {
    return try RowIterator.init(allocator, result_set.statement, 10);
}
