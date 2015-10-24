# vim:set ft= ts=4 sw=4 et fdm=marker:
use lib 'lib';
use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
};

$ENV{TEST_NGINX_RESOLVER} = '8.8.8.8';

#worker_connections(1014);
#master_on();
workers(2);
#log_level('warn');

repeat_each(2);
#repeat_each(1);

plan tests => repeat_each() * (blocks() * 3);

#no_diff();
#no_long_string();
run_tests();


__DATA__

=== TEST 1: request_uri (check the default path)
--- config
    location /lua {
        content_by_lua '
            local http = require "resty.http"
            local httpc = http.new()
            
            local res, err = httpc:request_uri("http://127.0.0.1:"..ngx.var.server_port)

            if res and 200 == res.status then
                ngx.print("OK")
            else
                ngx.print("FAIL")
            end
        ';
    }

    location =/ {
        content_by_lua '
            ngx.print("OK")
        ';
    }
--- request
GET /lua
--- response_body_like chop
OK$
--- no_error_log
[error]

