const std = @import("std");
const Allocator = std.mem.Allocator;

const odbc = @import("odbc");

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
/// FetchResult(Base) {
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

            return @Type(ResultInfo);
        },
        else => @compileError("The base type of FetchResult must be a struct, found " ++ @typeName(Target))
    }
}

pub fn Row(comptime Result: type) type {
    return struct {
        const Self = @This();

        column_names: [][]const u8,
        column_types: []odbc.Types.SqlType,
        
        column_offsets: []usize,
        column_lengths: []usize,

        data: []u8,

        statement: *odbc.Statement,
        allocator: *Allocator,

        pub fn init(allocator: *Allocator, statement: *odbc.Statement, num_columns: usize) !Self {
            var row: Self = undefined;
                
            row.statement = statement;
            row.allocator = allocator;
            row.column_names = try allocator.alloc([]const u8, num_columns);
            row.column_types = try allocator.alloc(odbc.Types.SqlType, num_columns);

            row.column_offsets = try allocator.alloc(usize, num_columns);
            row.column_offsets[0] = 0;

            row.column_lengths = try allocator.alloc(usize, num_columns);

            var column_index: usize = 0;
            while (column_index < num_columns) : (column_index += 1) {
                row.column_names[column_index] = try row.statement.getColumnAttribute(@intCast(c_ushort, column_index + 1), .BaseColumnName);

                const column_type = try row.statement.getColumnAttribute(@intCast(c_ushort, column_index + 1), .Type);
                row.column_types[column_index] = column_type;

                const column_size = try row.statement.getColumnAttribute(@intCast(c_ushort, column_index + 1), .OctetLength);
                // 4 is the alignment, might be different on different platforms so consider parameterizing this somehow
                row.column_lengths[column_index] = if (column_size % 4 == 0) column_size else column_size + (column_size % 4);
                if (column_index != 0) {
                    row.column_offsets[column_index] = row.column_offsets[column_index - 1] + row.column_lengths[column_index - 1] + @sizeOf(odbc.sys.SQLINTEGER);
                }
            }

            row.data = try allocator.alloc(u8, row.column_offsets[num_columns - 1] + row.column_lengths[num_columns - 1] + @sizeOf(odbc.sys.SQLINTEGER));

            column_index = 0;
            while (column_index < num_columns) : (column_index += 1) {
                const data_start_index = row.column_offsets[column_index];
                const data_len_start_index = data_start_index + row.column_lengths[column_index];
                row.statement.bindColumn(
                    @intCast(u16, column_index + 1),
                    row.column_types[column_index],
                    @ptrCast([*]u8, &row.data[data_start_index]),
                    row.column_lengths[column_index],
                    &row.data[data_len_start_index]
                );
            }

            return row;
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.data);
            self.allocator.free(self.column_offsets);
            self.allocator.free(self.column_lengths);
            self.allocator.free(self.column_types);

            for (self.column_names) |name| self.allocator.free(name);
            self.allocator.free(self.column_names);
        }

        pub fn get(self: *Self, comptime ColumnType: type, column_name: []const u8) !?ColumnType {
            var column_index = for (self.column_names) |name, index| {
                if (std.mem.eql(u8, name, column_name)) break index;
            } else return error.ColumnNotFound;

            const value_start_index = self.column_offsets[column_index];
            const value_len_or_ind = self.column_lengths[column_index];

            if (value_len_or_ind == odbc.sys.SQL_NULL_DATA) return null;

            if (std.meta.trait.isZigString(ColumnType)) {
                if (value_len_or_ind == odbc.sys.SQL_NTS) {
                    // Null-terminated string, so scan through and find the null byte
                    const null_byte = std.mem.indexOf(u8, self.data[value_start_index..], &.{ 0x00 });
                    if (null_byte) |end_index| {
                        return self.data[value_start_index..null_byte];
                    } else if (column_index == self.column_names.len - 1) {
                        return self.data[value_start_index..];
                    } else {
                        return error.InvalidString;
                    }

                    return self.data[value_start_index..null_byte];
                }

                if (value_start_index + value_len_or_ind > self.data.len) {
                    return error.InvalidString;
                }

                return self.data[value_start_index..value_len_or_ind];
            }

            return std.mem.bytesToValue(ColumnType, self.data[value_start_index..value_len_or_ind]);
        }
    };
}

pub const BindType = enum(u1) {
    row,
    column
};


fn RowBindingResultSet(comptime Base: type) type {
    return struct {
        const Self = @This();

        pub const RowType = FetchResult(Base);
        const RowStatus = odbc.Types.StatementAttributeValue.RowStatus;

        rows: []RowType,
        row_status: []RowStatus,

        rows_fetched: usize = 0,
        current_row: usize = 0,

        allocator: *Allocator,
        statement: *odbc.Statement,

        pub fn init(allocator: *Allocator, statement: *odbc.Statement, batch_size: usize) !Self {
            var self = Self{
                .statement = statement,
                .allocator = allocator,
                .rows = try allocator.alloc(RowType, batch_size),
                .row_status = try allocator.alloc(RowStatus, batch_size)
            };

            try self.bindColumns();

            return self;
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.rows);
            self.allocator.free(self.row_status);
        }

        pub fn getAllRows(self: *Self) ![]Base {
            var results = try std.ArrayList(Base).initCapacity(self.allocator, self.rows_fetched);

            while (try self.next()) |item| {
                try results.append(item);
            }

            return results.toOwnedSlice();
        }

        pub fn next(self: *Self) !?Base {
            // @todo Does this ever happen? I'm not sure if rows_fetched will be just the maximum number of rows that it can make available
            // in buffers at the moment, or if it's the total number of rows that the query resulted in
            if (self.current_row >= self.rows_fetched) {
                // Because of the param binding in PreparedStatement.fetch, this will update self.rows_fetched
                // @todo async - Handle error.StillExecuting here
                self.statement.fetch() catch |_| return null;
                self.current_row = 0;
            }

            if (self.current_row < self.rows_fetched) {
                // Iterate until you find the next row that returned Success or SuccessWithInfo. Should generally be the original current row
                while (self.current_row < self.rows_fetched and self.row_status[self.current_row] != .Success and self.row_status[self.current_row] != .SuccessWithInfo) {
                    self.current_row += 1;
                }

                if (self.current_row >= self.rows_fetched) return null;

                const item_row = self.rows[self.current_row];
                
                // Get each field of Base from the current RowType value and convert it back
                // to its original form
                var item: Base = undefined;
                inline for (std.meta.fields(Base)) |field| {
                    const row_data = @field(item_row, field.name);
                    const len_or_indicator = @field(item_row, field.name ++ "_len_or_ind");

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

                                    var data_slice = try self.allocator.alloc(info.child, slice_length);
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

                self.current_row += 1;
                return item;
            }

            return null;
        }

        /// Bind each column of the result set to their associated row buffers.
        /// After this function is called + `statement.fetch()`, you can retrieve
        /// result data from this struct.
        pub fn bindColumns(self: *Self) !void {
            var column_number: u16 = 1;
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

pub fn ColumnBindingResultSet(comptime Base: type) type {
    return struct {
        row: Row(Base),

        statement: *odbc.Statement,
        allocator: *Allocator,

        pub fn init(allocator: *Allocator, statement: *odbc.Statement, num_columns: usize) !Self {
            return Self{
                .statement = statement,
                .allocator = allocator,
                .row = try Row(Base).init(allocator, statement, length_info)
            };
        }

        pub fn deinit(self: *Self) void {
            self.row.deinit();
        }

        pub fn getAllRows(self: *Self) ![]Base {
            var results = try std.ArrayList(Base).initCapacity(self.allocator, self.rows_fetched);

            while (try self.next()) |item| {
                try results.append(item);
            }

            return results.toOwnedSlice();
        }

        pub fn next(self: *Self) !?Base {
            return try Base.fromRow(&self.row);    
        }
    };
}


pub fn ResultSet(comptime Base: type, comptime bind_type: BindType) type {
    return switch (bind_type) {
        .row => RowBindingResultSet(Base),
        .column => ColumnBindingResultSet(Base),
    };
}