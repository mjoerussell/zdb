const std = @import("std");
const Allocator = std.mem.Allocator;

const odbc = @import("odbc");

const ResultSet = @import("result_set.zig").ResultSet;
const FetchResult = @import("result_set.zig").FetchResult;

const sql_parameter = @import("parameter.zig");
const ParameterBucket = sql_parameter.ParameterBucket;

const Cursor = @import("cursor.zig").Cursor;

pub const ConnectionInfo = struct {
    pub const Config = struct {
        driver: ?[]const u8 = null,
        dsn: ?[]const u8 = null,
        username: ?[]const u8 = null,
        password: ?[]const u8 = null,
    };

    attributes: std.StringHashMap([]const u8),
    arena: std.heap.ArenaAllocator,

    /// Initialize a blank `ConnectionInfo` struct with an initialized `attributes` hash map
    /// and arena allocator.
    pub fn init(allocator: *Allocator) ConnectionInfo {
        return .{ 
            .attributes = std.StringHashMap([]const u8).init(allocator),
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    /// Initialize a `ConnectionInfo` using the information provided in the config data.
    pub fn initWithConfig(allocator: *Allocator, config: Config) !ConnectionInfo {
        var connection_info = ConnectionInfo.init(allocator);
        if (config.driver) |driver| try connection_info.setDriver(driver);
        if (config.dsn) |dsn| try connection_info.setDSN(dsn);
        if (config.username) |username| try connection_info.setUsername(username);
        if (config.password) |password| try connection_info.setPassword(password);

        return connection_info;
    }

    pub fn deinit(self: *ConnectionInfo) void {
        self.attributes.deinit();
        self.arena.deinit();
    }

    pub fn setAttribute(self: *ConnectionInfo, attr_name: []const u8, attr_value: []const u8) !void {
        try self.attributes.put(attr_name, attr_value);
    }

    pub fn getAttribute(self: *ConnectionInfo, attr_name: []const u8) ?[]const u8 {
        return self.attributes.get(attr_name);
    }

    pub fn setDriver(self: *ConnectionInfo, driver_value: []const u8) !void {
        try self.setAttribute("DRIVER", driver_value);
    }

    pub fn getDriver(self: *ConnectionInfo) ?[]const u8 {
        return self.getAttribute("DRIVER");
    }

    pub fn setUsername(self: *ConnectionInfo, user_value: []const u8) !void {
        try self.setAttribute("UID", user_value);
    }

    pub fn getUsername(self: *ConnectionInfo) ?[]const u8 {
        return self.getAttribute("UID");
    }

    pub fn setPassword(self: *ConnectionInfo, password_value: []const u8) !void {
        try self.setAttribute("PWD", password_value);
    }

    pub fn getPassword(self: *ConnectionInfo) ?[]const u8 {
        return self.getAttribute("PWD");
    }

    pub fn setDSN(self: *ConnectionInfo, dsn_value: []const u8) !void {
        try self.setAttribute("DSN", dsn_value);
    }

    pub fn getDSN(self: *ConnectionInfo) ?[]const u8 {
        return self.getAttribute("DSN");
    }

    pub fn toConnectionString(self: *ConnectionInfo) ![]const u8 {
        var string_builder = std.ArrayList(u8).init(&self.arena.allocator);
        errdefer string_builder.deinit();
        
        _ = try string_builder.writer().write("ODBC;");

        var attribute_iter = self.attributes.iterator();
        while (attribute_iter.next()) |entry| {
            _ = try string_builder.writer().write(entry.key_ptr.*);
            // _ = try string_builder.writer().write(entry.key);
            _ = try string_builder.writer().write("=");
            _ = try string_builder.writer().write(entry.value_ptr.*);
            // _ = try string_builder.writer().write(entry.value);
            _ = try string_builder.writer().write(";");
        }

        return string_builder.toOwnedSlice();
    }

    pub fn fromConnectionString(allocator: *Allocator, conn_str: []const u8) !ConnectionInfo {
        var conn_info = ConnectionInfo.init(allocator);

        var attr_start: usize = 0;
        var attr_sep_index: usize = 0;

        var current_index: usize = 0;
        while (current_index < conn_str.len) : (current_index += 1) {
            if (conn_str[current_index] == '=') {
                attr_sep_index = current_index;
                continue;
            }

            if (conn_str[current_index] == ';') {
                const attr_name = conn_str[attr_start..attr_sep_index];
                const attr_value = conn_str[attr_sep_index + 1..current_index];
                try conn_info.setAttribute(attr_name, attr_value);  

                attr_start = current_index + 1;  
            } else if (current_index == conn_str.len - 1) {
                const attr_name = conn_str[attr_start..attr_sep_index];
                const attr_value = conn_str[attr_sep_index + 1..];
                try conn_info.setAttribute(attr_name, attr_value);
            }
        }

        return conn_info;
    }
};

pub const DBConnection = struct {
    environment: odbc.Environment,
    connection: odbc.Connection,
    allocator: *Allocator,

    pub fn init(allocator: *Allocator, server_name: []const u8, username: []const u8, password: []const u8) !DBConnection {
        var result: DBConnection = undefined;
        result.allocator = allocator;
        
        result.environment = odbc.Environment.init() catch return error.EnvironmentError;
        errdefer result.environment.deinit() catch {};
        
        result.environment.setOdbcVersion(.Odbc3) catch return error.EnvironmentError;
        
        result.connection = odbc.Connection.init(&result.environment) catch return error.ConnectionError;
        errdefer result.connection.deinit() catch {};

        try result.connection.connect(server_name, username, password);

        return result;
    }

    pub fn initWithConnectionString(allocator: *Allocator, connection_string: []const u8) !DBConnection {
        var result: DBConnection = undefined;
        result.allocator = allocator;
        
        result.environment = odbc.Environment.init() catch return error.EnvironmentError;
        errdefer result.environment.deinit() catch {};
        
        result.environment.setOdbcVersion(.Odbc3) catch return error.EnvironmentError;
        
        result.connection = odbc.Connection.init(&result.environment) catch return error.ConnectionError;
        errdefer result.connection.deinit() catch {};

        try result.connection.connectExtended(connection_string, .NoPrompt);

        return result;
    }

    pub fn initWithInfo(allocator: *Allocator, connection_info: *ConnectionInfo) !DBConnection {
        return try DBConnection.initWithConnectionString(allocator, try connection_info.toConnectionString());
    }

    pub fn deinit(self: *DBConnection) void {
        self.connection.deinit() catch {};
        self.environment.deinit() catch {};
    }

    pub fn getCursor(self: *DBConnection) !Cursor {
        return try Cursor.init(self.allocator, self.connection);
    }

};

test "ConnectionInfo" {
    const allocator = std.testing.allocator;

    var connection_info = ConnectionInfo.init(allocator);
    defer connection_info.deinit();

    try connection_info.setDriver("A Driver");
    try connection_info.setDSN("Some DSN Value");
    try connection_info.setUsername("User");
    try connection_info.setPassword("Password");
    try connection_info.setAttribute("RandomAttr", "Random Value");

    const connection_string = try connection_info.toConnectionString();

    var derived_conn_info = try ConnectionInfo.fromConnectionString(allocator, connection_string);
    defer derived_conn_info.deinit();

    std.testing.expectEqualStrings("A Driver", derived_conn_info.getDriver().?);
    std.testing.expectEqualStrings("Some DSN Value", derived_conn_info.getDSN().?);
    std.testing.expectEqualStrings("User", derived_conn_info.getUsername().?);
    std.testing.expectEqualStrings("Password", derived_conn_info.getPassword().?);
    std.testing.expectEqualStrings("Random Value", derived_conn_info.getAttribute("RandomAttr").?);
}