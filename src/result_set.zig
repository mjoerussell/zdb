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
                result_fields[i * 2] = field;
                switch (@typeInfo(field.field_type)) {
                    .Pointer => |info| {
                        if (info.size == .Slice) {
                            // If the base type is a slice, the corresponding FetchResult type should be an array
                            result_fields[i * 2].field_type = [200:0]info.child;
                            result_fields[i * 2].default_value = null;
                        }
                    },
                    .Optional => |op_info| {
                        switch (@typeInfo(op_info.child)) {
                            .Pointer => |info| {
                                if (info.size == .Slice) {
                                    // If the base type is a slice, the corresponding FetchResult type should be an array
                                    result_fields[i * 2].field_type = [200]info.child;
                                    result_fields[i * 2].default_value = null;
                                }  
                            },
                            else => {
                                result_fields[i * 2].field_type = op_info.child;
                                result_fields[i * 2].default_value = null;
                            }
                        }
                    },
                    else => {}
                }
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

pub fn ResultSet(comptime Base: type) type {
    return struct {
        const Self = @This();
        const RowStatus = odbc.Types.StatementAttributeValue.RowStatus;

        pub const RowType = FetchResult(Base);

        rows_fetched: usize = 0,
        rows: []FetchResult(Base),
        row_status: []RowStatus,

        current_row: usize = 0,

        statement: *odbc.Statement,
        allocator: *Allocator,

        pub fn init(statement: *odbc.Statement, allocator: *Allocator) !Self {
            var self = Self{
                .statement = statement,
                .allocator = allocator,
                .rows = try allocator.alloc(RowType, 10),
                .row_status = try allocator.alloc(RowStatus, 10)
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
                results.appendAssumeCapacity(item);
            }

            return results.toOwnedSlice();
        }

        pub fn next(self: *Self) !?Base {
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
                
                var item: Base = undefined;
                inline for (std.meta.fields(Base)) |field| {
                    const row_data = @field(item_row, field.name);
                    const len_or_indicator = @field(item_row, field.name ++ "_len_or_ind");

                    const field_type_info = @typeInfo(field.field_type);
                    if (len_or_indicator == odbc.sys.SQL_NULL_DATA) {
                        if (field_type_info == .Optional) {
                            @field(item, field.name) = null;
                        } else if (field.default_value) |default| {
                            @field(item, field.name) = default;
                        } else {
                            return error.InvalidNullValue;
                        }
                    } else {
                        if (field_type_info == .Optional) {
                            const child_info = @typeInfo(field_type_info.Optional.child);
                            if (child_info == .Pointer) {
                                if (child_info.Pointer.size == .Slice) {
                                    // If the value is a null-terminated string, get the index of the null byte. If none is found, use the total
                                    // length of the string. Then, allocate that much space in the result slice and copy the data into it.
                                    const slice_length: usize = if (len_or_indicator == odbc.sys.SQL_NTS)
                                        std.mem.indexOf(u8, row_data[0..], &.{ 0x00 }) orelse row_data.len
                                    else
                                        @intCast(usize, len_or_indicator);
                                    
                                    var data_slice = try self.allocator.alloc(child_info.Pointer.child, slice_length);
                                    std.mem.copy(child_info.Pointer.child, data_slice, row_data[0..slice_length]);
                                    
                                    @field(item, field.name) = data_slice;
                                }
                            } else {
                                @field(item, field.name) = row_data;
                            }
                        } else {
                            switch (@typeInfo(field.field_type)) {
                                .Pointer => |info| switch (info.size) {
                                    .Slice => {
                                        // If the value is a null-terminated string, get the index of the null byte. If none is found, use the total
                                        // length of the string. Then, allocate that much space in the result slice and copy the data into it.
                                        // const item_data = @field(item_row, field.name);
                                        const slice_length: usize = if (len_or_indicator == odbc.sys.SQL_NTS)
                                            std.mem.indexOf(u8, row_data[0..], &.{ 0x00 }) orelse row_data.len
                                        else
                                            @intCast(usize, len_or_indicator);

                                        var data_slice = try self.allocator.alloc(info.child, slice_length);
                                        std.mem.copy(info.child, data_slice, row_data[0..slice_length]);
                                        @field(item, field.name) = data_slice;
                                    },
                                    else => @field(item, field.name) = row_data
                                },
                                else => @field(item, field.name) = row_data
                            }
                        }
                    }
                }

                self.current_row += 1;
                return item;
            }

            return null;
        }

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