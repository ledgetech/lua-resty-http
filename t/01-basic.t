use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (blocks() * 4) + 1;

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
=== TEST 1: Simple default get.
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua '
            local http = require "resty.http"
            local httpc = http.new()
            httpc:connect{
                scheme = "http",
                host = "127.0.0.1",
                port = ngx.var.server_port
            }

            local res, err = httpc:request{
                path = "/b"
            }

            ngx.status = res.status
            ngx.print(res:read_body())

            httpc:close()
        ';
    }
    location = /b {
        echo "OK";
    }
--- request
GET /a
--- response_body
OK
--- no_error_log
[error]
[warn]


=== TEST 2: HTTP 1.0
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua '
            local http = require "resty.http"
            local httpc = http.new()
            httpc:connect{
                scheme = "http",
                host = "127.0.0.1",
                port = ngx.var.server_port
            }

            local res, err = httpc:request{
                version = 1.0,
                path = "/b"
            }

            ngx.status = res.status
            ngx.print(res:read_body())

            httpc:close()
        ';
    }
    location = /b {
        echo "OK";
    }
--- request
GET /a
--- response_body
OK
--- no_error_log
[error]
[warn]


=== TEST 3: Status code and reason phrase
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua '
            local http = require "resty.http"
            local httpc = http.new()
            local ok, err = httpc:connect{
                scheme = "http",
                host = "127.0.0.1",
                port = ngx.var.server_port
            }

            local res, err = httpc:request{
                path = "/b"
            }

            ngx.status = res.status
            ngx.say(res.reason)
            ngx.print(res:read_body())

            httpc:close()
        ';
    }
    location = /b {
        content_by_lua '
            ngx.status = 404
            ngx.say("OK")
        ';
    }
--- request
GET /a
--- response_body
Not Found
OK
--- error_code: 404
--- no_error_log
[error]
[warn]


=== TEST 4: Response headers
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua '
            local http = require "resty.http"
            local httpc = http.new()
            httpc:connect{
                scheme = "http",
                host = "127.0.0.1",
                port = ngx.var.server_port
            }

            local res, err = httpc:request{
                path = "/b"
            }

            ngx.status = res.status
            ngx.say(res.headers["X-Test"])

            httpc:close()
        ';
    }
    location = /b {
        content_by_lua '
            ngx.header["X-Test"] = "x-value"
            ngx.say("OK")
        ';
    }
--- request
GET /a
--- response_body
x-value
--- no_error_log
[error]
[warn]


=== TEST 5: Query
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua '
            local http = require "resty.http"
            local httpc = http.new()
            httpc:connect{
                scheme = "http",
                host = "127.0.0.1",
                port = ngx.var.server_port
            }

            local res, err = httpc:request{
                query = {
                    a = 1,
                    b = 2,
                },
                path = "/b"
            }

            ngx.status = res.status

            for k,v in pairs(res.headers) do
                ngx.header[k] = v
            end

            ngx.print(res:read_body())

            httpc:close()
        ';
    }
    location = /b {
        content_by_lua '
            for k,v in pairs(ngx.req.get_uri_args()) do
                ngx.header["X-Header-" .. string.upper(k)] = v
            end
        ';
    }
--- request
GET /a
--- response_headers
X-Header-A: 1
X-Header-B: 2
--- no_error_log
[error]
[warn]


=== TEST 7: HEAD has no body.
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua '
            local http = require "resty.http"
            local httpc = http.new()
            httpc:connect{
                scheme = "http",
                host = "127.0.0.1",
                port = ngx.var.server_port
            }

            local res, err = httpc:request{
                method = "HEAD",
                path = "/b"
            }

            local body = res:read_body()

            if body then
                ngx.print(body)
            end
            httpc:close()
        ';
    }
    location = /b {
        echo "OK";
    }
--- request
GET /a
--- response_body
--- no_error_log
[error]
[warn]


=== TEST 8: Errors when not initialized
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua '
            local http = require "resty.http"

            local res, err = http:connect{
                scheme = "http",
                host = "127.0.0.1",
                port = ngx.var.server_port
            }
            if not res then ngx.say(err) end

            local res, err = http:set_timeout(500)
            if not res then ngx.say(err) end

            local res, err = http:set_keepalive()
            if not res then ngx.say(err) end

            local res, err = http:get_reused_times()
            if not res then ngx.say(err) end

            local res, err = http:close()
            if not res then ngx.say(err) end
        ';
    }
--- request
GET /a
--- response_body
not initialized
not initialized
not initialized
not initialized
not initialized
--- no_error_log
[error]
[warn]


=== TEST 9: Parse URI errors if malformed
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua '
            local http = require("resty.http").new()
            local parts, err = http:parse_uri("http:///example.com")
            if not parts then ngx.say(err) end
        ';
    }
--- request
GET /a
--- response_body
bad uri: http:///example.com
--- no_error_log
[error]
[warn]


=== TEST 10: Parse URI fills in defaults correctly
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua '
            local http = require("resty.http").new()

            local function test_uri(uri)
                local scheme, host, port, path, query = unpack(http:parse_uri(uri, false))
                ngx.say("scheme: ", scheme, ", host: ", host, ", port: ", port, ", path: ", path, ", query: ", query)
            end

            test_uri("http://example.com")
            test_uri("http://example.com/")
            test_uri("https://example.com/foo/bar")
            test_uri("https://example.com/foo/bar?a=1&b=2")
            test_uri("http://example.com?a=1&b=2")
            test_uri("//example.com")
            test_uri("//example.com?a=1&b=2")
            test_uri("//example.com/foo/bar?a=1&b=2")
        ';
    }
--- request
GET /a
--- response_body
scheme: http, host: example.com, port: 80, path: /, query: 
scheme: http, host: example.com, port: 80, path: /, query: 
scheme: https, host: example.com, port: 443, path: /foo/bar, query: 
scheme: https, host: example.com, port: 443, path: /foo/bar, query: a=1&b=2
scheme: http, host: example.com, port: 80, path: /, query: a=1&b=2
scheme: http, host: example.com, port: 80, path: /, query: 
scheme: http, host: example.com, port: 80, path: /, query: a=1&b=2
scheme: http, host: example.com, port: 80, path: /foo/bar, query: a=1&b=2
--- no_error_log
[error]
[warn]


=== TEST 11: Parse URI fills in defaults correctly, using backwards compatible mode
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua '
            local http = require("resty.http").new()

            local function test_uri(uri)
                local scheme, host, port, path, query = unpack(http:parse_uri(uri))
                ngx.say("scheme: ", scheme, ", host: ", host, ", port: ", port, ", path: ", path)
            end

            test_uri("http://example.com")
            test_uri("http://example.com/")
            test_uri("https://example.com/foo/bar")
            test_uri("https://example.com/foo/bar?a=1&b=2")
            test_uri("http://example.com?a=1&b=2")
            test_uri("//example.com")
            test_uri("//example.com?a=1&b=2")
            test_uri("//example.com/foo/bar?a=1&b=2")
        ';
    }
--- request
GET /a
--- response_body
scheme: http, host: example.com, port: 80, path: /
scheme: http, host: example.com, port: 80, path: /
scheme: https, host: example.com, port: 443, path: /foo/bar
scheme: https, host: example.com, port: 443, path: /foo/bar?a=1&b=2
scheme: http, host: example.com, port: 80, path: /?a=1&b=2
scheme: http, host: example.com, port: 80, path: /
scheme: http, host: example.com, port: 80, path: /?a=1&b=2
scheme: http, host: example.com, port: 80, path: /foo/bar?a=1&b=2
--- no_error_log
[error]
[warn]


=== TEST 12: Allow empty HTTP header values (RFC7230)
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua_block {
            local httpc = require("resty.http").new()

            -- Create a TCP connection and return an raw HTTP-response because
            -- there is no way to set an empty header value in nginx.
            assert(httpc:connect{
                scheme = "http",
                host = "127.0.0.1",
                port = 12345,
            }, "connect should return positively")

            local res = httpc:request({ path = "/b" })
            if res.headers["X-Header-Empty"] == "" then
                ngx.say("Empty")
            end
            ngx.say(res.headers["X-Header-Test"])
            ngx.print(res:read_body())
        }
    }
--- tcp_listen: 12345
--- tcp_reply
HTTP/1.0 200 OK
Date: Mon, 23 Jul 2018 13:00:00 GMT
X-Header-Empty:
X-Header-Test: Test
Server: OpenResty

OK
--- request
GET /a
--- response_body
Empty
Test
OK
--- no_error_log
[error]
[warn]
