use Test::Nginx::Socket 'no_plan';
use Cwd qw(cwd);

my $pwd = cwd();

$ENV{TEST_NGINX_RESOLVER} = '8.8.8.8';
$ENV{TEST_COVERAGE} ||= 0;

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;/usr/local/share/lua/5.1/?.lua;;";
    error_log logs/error.log debug;

    init_by_lua_block {
        if $ENV{TEST_COVERAGE} == 1 then
            jit.off()
            require("luacov.runner").init()
        end
    }
};

no_long_string();
#no_diff();

run_tests();

__DATA__
=== TEST 1: Non chunked.
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua '
            local http = require "resty.http"
            local httpc = http.new()
            httpc:connect("127.0.0.1", ngx.var.server_port)

            local res, err = httpc:request{
                path = "/b"
            }

            local body = res:read_body()

            ngx.say(#body)
            httpc:close()
        ';
    }
    location = /b {
        chunked_transfer_encoding off;
        content_by_lua '
            local len = 32768
            local t = {}
            for i=1,len do
                t[i] = 0
            end
            ngx.print(table.concat(t))
        ';
    }
--- request
GET /a
--- response_body
32768
--- no_error_log
[error]
[warn]


=== TEST 2: Chunked. The number of chunks received when no max size is given proves the response was in fact chunked.
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua '
            local http = require "resty.http"
            local httpc = http.new()
            httpc:connect("127.0.0.1", ngx.var.server_port)

            local res, err = httpc:request{
                path = "/b"
            }

            local chunks = {}
            local c = 1
            repeat
                local chunk, err = res.body_reader()
                if chunk then
                    chunks[c] = chunk
                    c = c + 1
                end
            until not chunk

            local body = table.concat(chunks)

            ngx.say(#body)
            ngx.say(#chunks)
            httpc:close()
        ';
    }
    location = /b {
        content_by_lua '
            local len = 32768
            local t = {}
            for i=1,len do
                t[i] = 0
            end
            ngx.print(table.concat(t))
            local len = 32768
            local t = {}
            for i=1,len do
                t[i] = 0
            end
            ngx.print(table.concat(t))
        ';
    }
--- request
GET /a
--- response_body
65536
2
--- no_error_log
[error]
[warn]


=== TEST 3: Chunked using read_body method.
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua '
            local http = require "resty.http"
            local httpc = http.new()
            httpc:connect("127.0.0.1", ngx.var.server_port)

            local res, err = httpc:request{
                path = "/b"
            }

            local body = res:read_body()

            ngx.say(#body)
            httpc:close()
        ';
    }
    location = /b {
        content_by_lua '
            local len = 32768
            local t = {}
            for i=1,len do
                t[i] = 0
            end
            ngx.print(table.concat(t))
            local len = 32768
            local t = {}
            for i=1,len do
                t[i] = 0
            end
            ngx.print(table.concat(t))
        ';
    }
--- request
GET /a
--- response_body
65536
--- no_error_log
[error]
[warn]


=== TEST 4: Chunked. multiple-headers, mixed case
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua_block {
            local http = require "resty.http"
            local httpc = http.new()
            httpc:connect("127.0.0.1", ngx.var.server_port)

            local res, err = httpc:request{
                path = "/b"
            }

            local chunks = {}
            local c = 1
            repeat
                local chunk, err = res.body_reader()
                if chunk then
                    chunks[c] = chunk
                    c = c + 1
                end
            until not chunk

            local body = table.concat(chunks)

            ngx.say(#body)
            ngx.say(#chunks)
            ngx.say(type(res.headers["Transfer-Encoding"]))
            httpc:close()
        }
    }
    location = /b {
        header_filter_by_lua_block {
            ngx.header["Transfer-Encoding"] = {"chUnked", "CHunked"}
        }
        content_by_lua_block {
            local len = 32768
            local t = {}
            for i=1,len do
                t[i] = 0
            end
            ngx.print(table.concat(t))
            local len = 32768
            local t = {}
            for i=1,len do
                t[i] = 0
            end
            ngx.print(table.concat(t))
        }
    }
--- request
GET /a
--- response_body
65536
2
table
--- no_error_log
[error]
[warn]
