const std = @import("std");
const Allocator = std.mem.Allocator;

const odbc = @import("odbc");

/// Given a struct, generate a new struct that can be used for ODBC row-wise binding. The conversion goes
/// roughly like this;
/// ```
/// struct Base {
///    field1: u32,
///    field2: []u8,
/// };
/// 
/// // Becomes....
///
/// FetchResult(Base) {
///    field1: u32,
///    field1_len_or_ind: c_longlong,
///    field2: [200]u8,
///    field2_len_or_ind: c_longlong
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
                            result_fields[i * 2].field_type = [200]info.child;
                            result_fields[i * 2].default_value = null;
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

        rows_fetched: usize = 0,
        rows: []FetchResult(Base),
        row_status: []RowStatus,

        current_row: usize = 0,

        statement: *odbc.Statement,
        allocator: *Allocator,

        pub fn init(statement: *odbc.Statement, allocator: *Allocator) !Self {
            return Self{
                .statement = statement,
                .allocator = allocator,
                .rows = try allocator.alloc(FetchResult(Base), 10),
                .row_status = try allocator.alloc(RowStatus, 10)
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.rows);
            self.allocator.free(self.row_status);
        }

        pub fn getAllRows(self: *Self) ![]Base {
            var results = std.ArrayList(Base).init(self.allocator);

            while (try self.next()) |item| {
                try results.append(item);
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
                inline for (std.meta.fields(Base)) |field, index| {
                    const len_or_indicator = @field(item_row, field.name ++ "_len_or_ind");
                    if (len_or_indicator != odbc.sys.SQL_NULL_DATA) {
                        // @fixme There's gotta be a cleaner way to do this
                        switch (@typeInfo(field.field_type)) {
                            .Array => {
                                if (len_or_indicator == odbc.sys.SQL_NTS) {
                                    const index_of_null_terminator = std.mem.indexOf(u8, @field(item_row, field.name)[0..], &.{ 0x00 }) orelse @field(item_row, field.name).len;
                                    @field(item, field.name) = @field(item_row, field.name)[0..index_of_null_terminator];
                                } else {
                                    @field(item, field.name) = @field(item_row, field.name);
                                }
                            },
                            .Pointer => |info| {
                                switch (info.size) {
                                    .Slice => {
                                        if (len_or_indicator == odbc.sys.SQL_NTS) {
                                            const index_of_null_terminator = std.mem.indexOf(u8, @field(item_row, field.name)[0..], &.{ 0x00 }) orelse @field(item_row, field.name).len;
                                            var data_slice = try self.allocator.alloc(info.child, @intCast(usize, index_of_null_terminator));
                                            std.mem.copy(info.child, data_slice, @field(item_row, field.name)[0..@intCast(usize, index_of_null_terminator)]);
                                            @field(item, field.name) = data_slice;
                                        } else {
                                            var data_slice = try self.allocator.alloc(info.child, @intCast(usize, len_or_indicator));
                                            std.mem.copy(info.child, data_slice, @field(item_row, field.name)[0..@intCast(usize, len_or_indicator)]);
                                            @field(item, field.name) = data_slice;
                                        }
                                    },
                                    else => {}
                                }
                            },
                            else => @field(item, field.name) = @field(item_row, field.name)
                        }
                    }

                }

                self.current_row += 1;
                return item;
            }

            return null;
        }

    };
}