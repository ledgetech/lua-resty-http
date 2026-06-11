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

# Same as $HttpConfig, but fires a request from a request-less phase
# (an init_worker timer) where ngx.var is disabled.
our $HttpConfigInitWorker = qq{
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

    init_worker_by_lua_block {
        local function make_request(premature)
            if premature then
                return
            end

            local http = require "resty.http"
            local httpc = http.new()
            local res, err = httpc:request_uri("http://www.google.com")
            if err then
                ngx.log(ngx.ERR, "init_worker request failed: ", err)
            end
            ngx.log(ngx.INFO, "init_worker request completed")
        end

        -- cosockets are unavailable directly in init_worker, so defer to a
        -- timer. The timer phase is also request-less (ngx.var disabled).
        local ok, err = ngx.timer.at(0, make_request)
        if not ok then
            ngx.log(ngx.ERR, "failed to create timer: ", err)
        end
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


=== TEST 4: A request from a request-less phase does not error reading ngx.var
--- http_config eval: $::HttpConfigInitWorker
--- config
    location /lua {
        content_by_lua_block {
            -- give the init_worker timer time to fire and finish
            ngx.sleep(0.5)
            ngx.say("ok")
        }
    }
--- request
GET /lua
--- response_body
ok
--- no_error_log
[error]
API disabled in the context of ngx.timer
--- error_log
init_worker request completed
