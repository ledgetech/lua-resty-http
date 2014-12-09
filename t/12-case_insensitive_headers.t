# vim:set ft= ts=4 sw=4 et:

use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (blocks() * 4);

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    error_log logs/error.log debug;
};

$ENV{TEST_NGINX_RESOLVER} = '8.8.8.8';

no_long_string();
#no_diff();

run_tests();

__DATA__
=== TEST 1: Test headers can be accessed in all cases
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

            ngx.status = res.status
            ngx.say(res.headers["X-Foo-Header"])
            ngx.say(res.headers["x-fOo-heaDeR"])
            ngx.say(res.headers.x_foo_header)
            
            httpc:close()
        ';
    }
    location = /b {
        content_by_lua '
            ngx.header["X-Foo-Header"] = "bar"
            ngx.say("OK")
        ';
    }
--- request
GET /a
--- response_body
bar
bar
bar
--- no_error_log
[error]
[warn]


=== TEST 2: Test request headers are normalised
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua '
            local http = require "resty.http"
            local httpc = http.new()
            httpc:connect("127.0.0.1", ngx.var.server_port)

            local res, err = httpc:request{
                path = "/b",
                headers = {
                    user_agent = "test_user_agent",
                },
            }

            ngx.status = res.status
            ngx.say(res:read_body())
            
            httpc:close()
        ';
    }
    location = /b {
        content_by_lua '
            ngx.say(ngx.req.get_headers()["User-Agent"])
        ';
    }
--- request
GET /a
--- response_body
test_user_agent
--- no_error_log
[error]
[warn]
