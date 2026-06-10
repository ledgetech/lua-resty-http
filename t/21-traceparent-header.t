use Test::Nginx::Socket 'no_plan';
use Cwd qw(cwd);

my $pwd = cwd();

$ENV{TEST_NGINX_RESOLVER} = '8.8.8.8';
$ENV{TEST_NGINX_PWD} ||= $pwd;
$ENV{TEST_COVERAGE} ||= 0;

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;/usr/local/share/lua/5.1/?.lua;;";
    error_log logs/error.log debug;
    resolver 8.8.8.8 ipv6=off;

    init_by_lua_block {
        if $ENV{TEST_COVERAGE} == 1 then
            jit.off()
            require("luacov.runner").init()
        end

        require("resty.http").debug(true)
    }
};

no_long_string();
#no_diff();

run_tests();

__DATA__
=== TEST 1: No traceparent header is set
--- http_config eval: $::HttpConfig
--- config
    location /lua {
        content_by_lua '
            require("resty.http").debug(true)
            local http = require "resty.http"
            local httpc = http.new()

            local res, err = httpc:request_uri("http://www.google.com")
        ';
    }
--- request
GET /lua
--- no_error_log
[error]
traceparent:


=== TEST 2: The traceparent header is correctly added when ngx.var.http_traceparent is used
--- http_config eval: $::HttpConfig
--- config
    location /lua {
        # emulate nginx-otel behavior here
        set $http_traceparent '00-000000000000000019f4e02c82857913-11488c6e00d1d248-01';
        content_by_lua '
            require("resty.http").debug(true)
            local http = require "resty.http"
            local httpc = http.new()
            local res, err = httpc:request_uri("http://www.google.com")
        ';
    }
--- request
GET /lua
--- no_error_log
[error]
--- error_log
traceparent: 00-000000000000000019f4e02c82857913-11488c6e00d1d248-01


=== TEST 3: The traceparent header is not modified from ngx.var.http_traceparent if it is already set
--- http_config eval: $::HttpConfig
--- config
    location /lua {
        # emulate nginx-otel behavior here
        set $http_traceparent '00-000000000000000019f4e02c82857913-11488c6e00d1d248-01';
        content_by_lua '
            require("resty.http").debug(true)
            local http = require "resty.http"
            local httpc = http.new()
            local req_headers = {}
            req_headers["traceparent"] = "00-00000000000000006633c2d00527dd33-1af98f7e6ecd16ff-01"
            local res, err = httpc:request_uri("http://www.google.com", {method = GET, headers = req_headers})
        ';
    }
--- request
GET /lua
--- no_error_log
[error]
traceparent: 00-000000000000000019f4e02c82857913-11488c6e00d1d248-01
--- error_log
traceparent: 00-00000000000000006633c2d00527dd33-1af98f7e6ecd16ff-01
