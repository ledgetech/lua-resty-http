# vim:set ft= ts=4 sw=4 et:

use Test::Nginx::Socket;
use Cwd qw(cwd);

repeat_each(2);

plan tests => repeat_each() * (blocks() * 4);

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
    location = /get_1 {
        content_by_lua '
            local http = require "resty.http"
            local httpc = http.connect("127.0.0.1", ngx.var.server_port)
            
            local status, headers, body = httpc:request{
                path = "/get_1_up"
            }

            ngx.status = status
            
            for k,v in pairs(headers) do
            --    ngx.header[k] = v
            end

            ngx.print(body)
            
            httpc:close()
        ';
    }
    location = /get_1_up {
        echo "OK";
    }
--- request
GET /get_1
--- response_body
OK
--- no_error_log
[error]
[warn]


