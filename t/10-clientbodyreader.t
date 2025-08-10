use Test::Nginx::Socket 'no_plan';
use Cwd qw(cwd);

my $pwd = cwd();

$ENV{TEST_NGINX_RESOLVER} = '8.8.8.8';
$ENV{TEST_COVERAGE} ||= 0;

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;/usr/local/share/lua/5.1/?.lua;;";
    error_log logs/error.log debug;

    lua_shared_dict test_dict 1m;

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

=== TEST 1: Issue a notice (but do not error) if trying to read the request body in a subrequest
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        echo_location /b;
    }
    location = /b {
        content_by_lua '
            local http = require "resty.http"
            local httpc = http.new()
            httpc:connect({
                scheme = "http",
                host = "127.0.0.1",
                port = ngx.var.server_port,
            })

            local res, err = httpc:request{
                path = "/c",
                headers = {
                    ["Content-Type"] = "application/x-www-form-urlencoded",
                }
            }
            if not res then
                ngx.say(err)
            end
            ngx.print(res:read_body())
            httpc:close()
        ';
    }
    location /c {
        echo "OK";
    }
--- request
GET /a
--- response_body
OK
--- no_error_log
[error]
[warn]



=== TEST 2: Read request body
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua_block {
            local httpc = require("resty.http").new()

            local reader, err = assert(httpc:get_client_body_reader())

            repeat
                local buffer, err = reader()
                if err then
                    ngx.log(ngx.ERR, err)
                end

                if buffer then
                    ngx.print(buffer)
                end
            until not buffer
        }
    }
--- request
POST /a
foobar
--- response_body: foobar
--- no_error_log
[error]
[warn]



=== TEST 3: Read chunked request body, errors as not yet supported
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua_block {
            local httpc = require("resty.http").new()
            local _, err = httpc:get_client_body_reader()
            ngx.log(ngx.ERR, err)
        }
    }
--- more_headers
Transfer-Encoding: chunked
--- request eval
"POST /a
3\r
foo\r
3\r
bar\r
0\r
\r
"
--- error_log
chunked request bodies not supported yet
--- no_error_log
[warn]



=== TEST 4: Read a body in a timer context with explicitly provided socket and headers(1 byte buffer)
--- http_config eval: $::HttpConfig
--- config
    location = /b {
        content_by_lua_block {
            ngx.header["Content-Length"] = 3
            ngx.print("foo")
        }
    }

    location = /a {
        content_by_lua_block {
            -- ngx.var / ngx.req.* are not available inside a timer, so
            -- capture what we need and pass it in explicitly.
            local port = ngx.var.server_port

            local function handler(premature, port)
                local sock = ngx.socket.tcp()
                local ok, err = sock:connect("127.0.0.1", port)
                if not ok then
                    ngx.shared.test_dict:set("body", "connect failed: " .. err)
                    return
                end

                sock:send("GET /b HTTP/1.0\r\nHost: localhost\r\n\r\n")

                -- Read the status line and response headers off the socket.
                local content_length
                while true do
                    local line = sock:receive("*l")
                    if not line or line == "" then
                        break
                    end
                    local k, v = line:match("^([^:]+):%s*(.+)$")
                    if k and k:lower() == "content-length" then
                        content_length = tonumber(v)
                    end
                end

                -- Use the explicit socket + headers overloads since
                -- ngx.req.socket() / ngx.req.get_headers() do not work here.
                local httpc = require("resty.http").new()
                local headers = { ["Content-Length"] = content_length }
                local reader, err = httpc:get_client_body_reader(1, sock, headers)
                if not reader then
                    ngx.shared.test_dict:set("body", "no reader: " .. (err or "nil"))
                    return
                end

                local body = {}
                repeat
                    local buffer, err = reader()
                    if err then
                        ngx.shared.test_dict:set("body", "read error: " .. err)
                        return
                    end
                    if buffer then
                        body[#body + 1] = buffer
                    end
                until not buffer

                sock:close()
                ngx.shared.test_dict:set("body", table.concat(body))
            end

            local ok, err = ngx.timer.at(0, handler, port)
            if not ok then
                ngx.say("failed to create timer: ", err)
                return
            end

            -- Wait for the timer to finish and store its result.
            local body
            for _ = 1, 100 do
                body = ngx.shared.test_dict:get("body")
                if body then
                    break
                end
                ngx.sleep(0.01)
            end

            ngx.say(body)
        }
    }
--- request
GET /a
--- response_body
foo
--- no_error_log
[error]
[warn]



=== TEST 5: Read a body in a timer context with explicitly provided socket and headers (2 bytes buffer)
--- http_config eval: $::HttpConfig
--- config
    location = /b {
        content_by_lua_block {
            ngx.header["Content-Length"] = 3
            ngx.print("foo")
        }
    }

    location = /a {
        content_by_lua_block {
            -- ngx.var / ngx.req.* are not available inside a timer, so
            -- capture what we need and pass it in explicitly.
            local port = ngx.var.server_port

            local function handler(premature, port)
                local sock = ngx.socket.tcp()
                local ok, err = sock:connect("127.0.0.1", port)
                if not ok then
                    ngx.shared.test_dict:set("body", "connect failed: " .. err)
                    return
                end

                sock:send("GET /b HTTP/1.0\r\nHost: localhost\r\n\r\n")

                -- Read the status line and response headers off the socket.
                local content_length
                while true do
                    local line = sock:receive("*l")
                    if not line or line == "" then
                        break
                    end
                    local k, v = line:match("^([^:]+):%s*(.+)$")
                    if k and k:lower() == "content-length" then
                        content_length = tonumber(v)
                    end
                end

                -- Use the explicit socket + headers overloads since
                -- ngx.req.socket() / ngx.req.get_headers() do not work here.
                local httpc = require("resty.http").new()
                local headers = { ["Content-Length"] = content_length }
                local reader, err = httpc:get_client_body_reader(2, sock, headers)
                if not reader then
                    ngx.shared.test_dict:set("body", "no reader: " .. (err or "nil"))
                    return
                end

                local body = {}
                repeat
                    local buffer, err = reader()
                    if err then
                        ngx.shared.test_dict:set("body", "read error: " .. err)
                        return
                    end
                    if buffer then
                        body[#body + 1] = buffer
                    end
                until not buffer

                sock:close()
                ngx.shared.test_dict:set("body", table.concat(body))
            end

            local ok, err = ngx.timer.at(0, handler, port)
            if not ok then
                ngx.say("failed to create timer: ", err)
                return
            end

            -- Wait for the timer to finish and store its result.
            local body
            for _ = 1, 100 do
                body = ngx.shared.test_dict:get("body")
                if body then
                    break
                end
                ngx.sleep(0.01)
            end

            ngx.say(body)
        }
    }
--- request
GET /a
--- response_body
foo
--- no_error_log
[error]
[warn]
