use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (blocks() * 4);

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
=== TEST 1: POST form-urlencoded
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua '
            local http = require "resty.http"
            local httpc = http.new()
            httpc:connect({
                scheme = "http",
                host = "127.0.0.1",
                port = ngx.var.server_port
            })

            local res, err = httpc:request{
                body = "a=1&b=2&c=3",
                path = "/b",
                headers = {
                    ["Content-Type"] = "application/x-www-form-urlencoded",
                }
            }

            ngx.say(res:read_body())
            httpc:close()
        ';
    }
    location = /b {
        content_by_lua '
            ngx.req.read_body()
            local args = ngx.req.get_post_args()
            ngx.say("a: ", args.a)
            ngx.say("b: ", args.b)
            ngx.print("c: ", args.c)
        ';
    }
--- request
GET /a
--- response_body
a: 1
b: 2
c: 3
--- no_error_log
[error]
[warn]


=== TEST 2: POST form-urlencoded 1.0
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua '
            local http = require "resty.http"
            local httpc = http.new()
            httpc:connect({
                scheme = "http",
                host = "127.0.0.1",
                port = ngx.var.server_port
            })

            local res, err = httpc:request{
                method = "POST",
                body = "a=1&b=2&c=3",
                path = "/b",
                headers = {
                    ["Content-Type"] = "application/x-www-form-urlencoded",
                },
                version = 1.0,
            }

            ngx.say(res:read_body())
            httpc:close()
        ';
    }
    location = /b {
        content_by_lua '
            ngx.req.read_body()
            local args = ngx.req.get_post_args()
            ngx.say(ngx.req.get_method())
            ngx.say("a: ", args.a)
            ngx.say("b: ", args.b)
            ngx.print("c: ", args.c)
        ';
    }
--- request
GET /a
--- response_body
POST
a: 1
b: 2
c: 3
--- no_error_log
[error]
[warn]


=== TEST 3: 100 Continue does not end requset
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua '
            local http = require "resty.http"
            local httpc = http.new()
            httpc:connect({
                scheme = "http",
                host = "127.0.0.1",
                port = ngx.var.server_port
            })

            local res, err = httpc:request{
                body = "a=1&b=2&c=3",
                path = "/b",
                headers = {
                    ["Expect"] = "100-continue",
                    ["Content-Type"] = "application/x-www-form-urlencoded",
                }
            }
            ngx.say(res.status)
            ngx.say(res:read_body())
            httpc:close()
        ';
    }
    location = /b {
        content_by_lua '
            ngx.req.read_body()
            local args = ngx.req.get_post_args()
            ngx.say("a: ", args.a)
            ngx.say("b: ", args.b)
            ngx.print("c: ", args.c)
        ';
    }
--- request
GET /a
--- response_body
200
a: 1
b: 2
c: 3
--- no_error_log
[error]
[warn]

=== TEST 4: Return non-100 status to user
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua '
            local http = require "resty.http"
            local httpc = http.new()
            httpc:connect({
                scheme = "http",
                host = "127.0.0.1",
                port = ngx.var.server_port
            })

            local res, err = httpc:request{
                path = "/b",
                headers = {
                    ["Expect"] = "100-continue",
                    ["Content-Type"] = "application/x-www-form-urlencoded",
                }
            }
            if not res then
                ngx.say(err)
            end
            ngx.say(res.status)
            ngx.say(res:read_body())
            httpc:close()
        ';
    }
    location = /b {
        return 417 "Expectation Failed";
    }
--- request
GET /a
--- response_body
417
Expectation Failed
--- no_error_log
[error]
[warn]
