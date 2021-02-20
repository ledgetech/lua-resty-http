local ngx_re_gmatch = ngx.re.gmatch
local ngx_re_sub = ngx.re.sub
local ngx_re_find = ngx.re.find

--[[
A connection function that incorporates:
  - tcp connect
  - ssl handshake
  - http proxy (options to be set using "set_proxy_options")
Due to this it will be better at setting up a socket pool where connections can
be kept alive.


Call it with a single options table as follows:

client:connect {
    scheme = "https"        -- scheme to use, or nil for unix domain socket
    host = "myhost.com",    -- target machine, or a unix domain socket
    port = nil,             -- port on target machine, will default to 80/443 based on scheme
    pool = nil,             -- connection pool name, leave blank! this function knows best!
    pool_size = nil,        -- options as per: https://github.com/openresty/lua-nginx-module#tcpsockconnect
    backlog = nil,

    ssl = {                 -- ssl will be used when either scheme = https, or when ssl is truthy
        server_name = nil,  -- options as per: https://github.com/openresty/lua-nginx-module#tcpsocksslhandshake
        ssl_verify = true,  -- defaults to true
        ctx = nil,          -- NOT supported
    },
}
]]
local function connect(self, options)
    local sock = self.sock
    if not sock then
        return nil, "not initialized"
    end

    local ok, err

    local request_scheme = options.scheme
    local request_host = options.host
    local request_port = options.port

    local poolname = options.pool
    local pool_size = options.pool_size
    local backlog = options.backlog

    if request_scheme and not request_port then
        request_port = (request_scheme == "https" and 443 or 80)
    elseif request_port and not request_scheme then
        return nil, "'scheme' is required when providing a port"
    end

    -- ssl settings
    local ssl, ssl_server_name, ssl_verify
    if request_scheme ~= "http" then
        -- either https or unix domain socket
        ssl = options.ssl
        if type(options.ssl) == "table" then
            ssl_server_name = ssl.server_name
            ssl_verify = (ssl.verify == nil) or (not not ssl.verify) -- default to true, and force to bool
            ssl = true
        else
            if ssl then
                ssl = true
                ssl_verify = true       -- default to true
            else
                ssl = false
            end
        end
    else
        -- plain http
        ssl = false
    end

    -- proxy related settings
    local proxy, proxy_uri, proxy_uri_t, proxy_authorization, proxy_host, proxy_port
    proxy = self.proxy_opts

    if proxy then
        if request_scheme == "https" then
            proxy_uri = proxy.https_proxy
            proxy_authorization = proxy.https_proxy_authorization
        else
            proxy_uri = proxy.http_proxy
            proxy_authorization = proxy.http_proxy_authorization
        end
        if not proxy_uri then
            proxy = nil
        end
    end

    if proxy and proxy.no_proxy then
        -- Check if the no_proxy option matches this host. Implementation adapted
        -- from lua-http library (https://github.com/daurnimator/lua-http)
        if proxy.no_proxy == "*" then
            -- all hosts are excluded
            proxy = nil

        else
            local host = request_host
            local no_proxy_set = {}
            -- wget allows domains in no_proxy list to be prefixed by "."
            -- e.g. no_proxy=.mit.edu
            for host_suffix in ngx_re_gmatch(proxy.no_proxy, "\\.?([^,]+)") do
                no_proxy_set[host_suffix[1]] = true
            end

            -- From curl docs:
            -- matched as either a domain which contains the hostname, or the
            -- hostname itself. For example local.com would match local.com,
            -- local.com:80, and www.local.com, but not www.notlocal.com.
            --
            -- Therefore, we keep stripping subdomains from the host, compare
            -- them to the ones in the no_proxy list and continue until we find
            -- a match or until there's only the TLD left
            repeat
                if no_proxy_set[host] then
                    proxy = nil
                    proxy_uri = nil
                    proxy_authorization = nil
                    break
                end

                -- Strip the next level from the domain and check if that one
                -- is on the list
                host = ngx_re_sub(host, "^[^.]+\\.", "")
            until not ngx_re_find(host, "\\.")
        end
    end

    if proxy then
        proxy_uri_t, err = self:parse_uri(proxy_uri)
        if not proxy_uri_t then
            return nil, err
        end

        local proxy_scheme = proxy_uri_t[1]
        if proxy_scheme ~= "http" then
            return nil, "protocol " .. tostring(proxy_scheme) ..
                        " not supported for proxy connections"
        end
        proxy_host = proxy_uri_t[2]
        proxy_port = proxy_uri_t[3]
    end

    -- construct a poolname unique within proxy and ssl info
    if not poolname then
        poolname = (request_scheme or "")
                   .. ":" .. request_host
                   .. ":" .. tostring(request_port)
                   .. ":" .. tostring(ssl)
                   .. ":" .. (ssl_server_name or "")
                   .. ":" .. tostring(ssl_verify)
                   .. ":" .. (proxy_uri or "")
                   .. ":" .. (proxy_authorization or "")
    end

    -- do TCP level connection
    local tcp_opts = { pool = poolname, pool_size = pool_size, backlog = backlog }
    if proxy then
        -- proxy based connection
        ok, err = sock:connect(proxy_host, proxy_port, tcp_opts)
        if not ok then
            return nil, err
        end

        if request_scheme == "https" and sock:getreusedtimes() == 0 then
            -- Make a CONNECT request to create a tunnel to the destination through
            -- the proxy. The request-target and the Host header must be in the
            -- authority-form of RFC 7230 Section 5.3.3. See also RFC 7231 Section
            -- 4.3.6 for more details about the CONNECT request
            local destination = request_host .. ":" .. request_port
            local res, err = self:request({
                method = "CONNECT",
                path = destination,
                headers = {
                    ["Host"] = destination,
                    ["Proxy-Authorization"] = proxy_authorization,
                }
            })

            if not res then
                return nil, err
            end

            if res.status < 200 or res.status > 299 then
                return nil, "failed to establish a tunnel through a proxy: " .. res.status
            end
        end

    elseif not request_port then
        -- non-proxy, without port -> unix domain socket
        ok, err = sock:connect(request_host, tcp_opts)
        if not ok then
            return nil, err
        end

    else
        -- non-proxy, regular network tcp
        ok, err = sock:connect(request_host, request_port, tcp_opts)
        if not ok then
            return nil, err
        end
    end

    -- Now do the ssl handshake
    if ssl and sock:getreusedtimes() == 0 then
        local ok, err = self:ssl_handshake(nil, ssl_server_name, ssl_verify)
        if not ok then
            self:close()
            return nil, err
        end
    end

    self.host = request_host
    self.port = request_port
    self.keepalive = true
    self.ssl = ssl

    return true
end

return connect
