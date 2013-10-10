# vim:set ft= ts=4 sw=4 et:

use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (blocks() * 4) + 1;

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
};

$ENV{TEST_NGINX_RESOLVER} = '8.8.8.8';

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
            local httpc = http.connect("127.0.0.1", ngx.var.server_port)
            
            local status, headers, body = httpc:request{
                path = "/b"
            }

            ngx.status = status
            ngx.print(body)
            
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
            local httpc = http.connect("127.0.0.1", ngx.var.server_port)
            
            local status, headers, body = httpc:request{
                version = 1.0,
                path = "/b"
            }

            ngx.status = status
            ngx.print(body)
            
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


=== TEST 3: Status code
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua '
            local http = require "resty.http"
            local httpc = http.connect("127.0.0.1", ngx.var.server_port)
            
            local status, headers, body = httpc:request{
                path = "/b"
            }

            ngx.status = status
            ngx.print(body)
            
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
            local httpc = http.connect("127.0.0.1", ngx.var.server_port)
            
            local status, headers, body = httpc:request{
                path = "/b"
            }

            ngx.status = status
            ngx.say(headers["X-Test"])
            
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
            local httpc = http.connect("127.0.0.1", ngx.var.server_port)
            
            local status, headers, body = httpc:request{
                query = {
                    a = 1,
                    b = 2,
                },
                path = "/b"
            }

            ngx.status = status

            for k,v in pairs(headers) do
                ngx.header[k] = v
            end

            ngx.print(body)
            
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


