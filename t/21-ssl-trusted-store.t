use Test::Nginx::Socket::Lua 'no_plan';


log_level 'debug';

no_long_string();

sub read_file {
    my $infile = shift;
    open my $in, $infile
        or die "cannot open $infile for reading: $!";
    my $cert = do { local $/; <$in> };
    close $in;
    $cert;
}

our $TestCert = read_file("t/cert/test.crt");
our $TestKey = read_file("t/cert/test.key");

our $HtmlDir = html_dir;

use Cwd qw(cwd);
my $pwd = cwd();

our $http_config = <<"_EOC_";
    lua_package_path "$pwd/lib/?.lua;/usr/local/share/lua/5.1/?.lua;;";
server {
    listen unix:$::HtmlDir/ssl.sock ssl;

    ssl_certificate        $::HtmlDir/test.crt;
    ssl_certificate_key    $::HtmlDir/test.key;
    server_tokens          off;
    server_name            example.com;

    location / {
        echo -n "hello";
    }
}
_EOC_

our $user_files = <<"_EOC_";
>>> test.crt
$::TestCert
>>> test.key
$::TestKey
_EOC_

run_tests();

__DATA__

=== TEST 1: ssl_trusted_store rejects non-cdata values
--- http_config eval: $::http_config
--- config eval
"
lua_ssl_trusted_certificate $::HtmlDir/test.crt;
location /t {
    content_by_lua_block {
        local httpc = assert(require('resty.http').new())

        local ok, err = httpc:connect {
          scheme = 'https',
          host = 'unix:$::HtmlDir/ssl.sock',
          ssl_trusted_store = 'not_a_cdata',
        }

        if not ok then
          ngx.status = 400
          ngx.say(err)
        else
          ngx.say('unexpected success')
        end
    }
}
"
--- user_files eval: $::user_files
--- request
GET /t
--- error_code: 400
--- response_body
bad ssl_trusted_store: cdata expected, got string
--- no_error_log
[error]
[warn]


=== TEST 2: ssl_trusted_store rejects table values
--- http_config eval: $::http_config
--- config eval
"
lua_ssl_trusted_certificate $::HtmlDir/test.crt;
location /t {
    content_by_lua_block {
        local httpc = assert(require('resty.http').new())

        local ok, err = httpc:connect {
          scheme = 'https',
          host = 'unix:$::HtmlDir/ssl.sock',
          ssl_trusted_store = {},
        }

        if not ok then
          ngx.status = 400
          ngx.say(err)
        else
          ngx.say('unexpected success')
        end
    }
}
"
--- user_files eval: $::user_files
--- request
GET /t
--- error_code: 400
--- response_body
bad ssl_trusted_store: cdata expected, got table
--- no_error_log
[error]
[warn]


=== TEST 3: ssl_trusted_store is ignored for non-https schemes
--- http_config eval: $::http_config
--- config eval
"
location /backend {
    echo -n 'ok';
}

location /t {
    content_by_lua_block {
        local httpc = assert(require('resty.http').new())

        local ok, err = httpc:connect {
          scheme = 'http',
          host = '127.0.0.1',
          port = \$TEST_NGINX_SERVER_PORT,
          ssl_trusted_store = 'should_be_ignored',
        }

        if not ok then
          ngx.say('connect failed: ' .. err)
          return
        end

        local res, err = httpc:request {
          method = 'GET',
          path = '/backend',
        }

        if not res then
          ngx.say('request failed: ' .. err)
          return
        end

        ngx.say(res:read_body())
        httpc:close()
    }
}
"
--- user_files eval: $::user_files
--- request
GET /t
--- error_code: 200
--- response_body
ok
--- no_error_log
[error]
[warn]


=== TEST 4: same ssl_trusted_store reuses pool, different store gets a new pool
--- http_config eval: $::http_config
--- config eval
"
lua_ssl_trusted_certificate $::HtmlDir/test.crt;
location /t {
    content_by_lua_block {
        local x509_store = require('resty.openssl.x509.store')

        local store1 = assert(x509_store.new())
        local store2 = assert(x509_store.new())

        -- First connection with store1
        local httpc1 = assert(require('resty.http').new())
        local ok, err = httpc1:connect {
          scheme = 'https',
          host = 'unix:$::HtmlDir/ssl.sock',
          ssl_trusted_store = store1.ctx,
          ssl_verify = false,
        }
        assert(ok and not err, 'connect 1 failed: ' .. (err or ''))
        httpc1:set_keepalive()

        -- Second connection with the same store1 — should reuse the pool
        local httpc2 = assert(require('resty.http').new())
        ok, err = httpc2:connect {
          scheme = 'https',
          host = 'unix:$::HtmlDir/ssl.sock',
          ssl_trusted_store = store1.ctx,
          ssl_verify = false,
        }
        assert(ok and not err, 'connect 2 failed: ' .. (err or ''))
        ngx.say('same store reused: ', httpc2:get_reused_times())
        httpc2:set_keepalive()

        -- Third connection with a different store2 — should NOT reuse the pool
        local httpc3 = assert(require('resty.http').new())
        ok, err = httpc3:connect {
          scheme = 'https',
          host = 'unix:$::HtmlDir/ssl.sock',
          ssl_trusted_store = store2.ctx,
          ssl_verify = false,
        }
        assert(ok and not err, 'connect 3 failed: ' .. (err or ''))
        ngx.say('different store reused: ', httpc3:get_reused_times())
        httpc3:close()
    }
}
"
--- user_files eval: $::user_files
--- request
GET /t
--- error_code: 200
--- response_body
same store reused: 1
different store reused: 0
--- no_error_log
[error]
[warn]
--- skip_nginx
4: < 1.21.4
