local ngx_socket_tcp = ngx.socket.tcp
local str_gmatch = string.gmatch
local str_lower = string.lower
local str_upper = string.upper
local str_find = string.find
local str_sub = string.sub
local tbl_insert = table.insert
local tbl_concat = table.concat
local ngx_encode_args = ngx.encode_args
local ngx_re_match = ngx.re.match


local _M = {
    _VERSION = '0.01',
}


local HTTP = {
    [1.0] = " HTTP/1.0\r\n",
    [1.1] = " HTTP/1.1\r\n",
}

local USER_AGENT = "Resty/HTTP " .. _M._VERSION .. " (Lua)"

local default_params = {
    method = "GET",
    path = "/",
    version = 1.1,
}


local mt = { __index = _M }


local function _should_receive_body(method, code)
    if method == "HEAD" then return nil end
    if code == 204 or code == 304 then return nil end
    if code >= 100 and code < 200 then return nil end
    return true
end


local function _format_request(params)
    local version = params.version
    local headers = params.headers or {}
    local body = params.body

    local query = params.query
    if query then
        if type(query) == "table" then
            query = ngx_encode_args(params.query)
        end
    end

    -- Initialize request
    local req = {
        str_upper(params.method),
        " ",
        params.path,
        query,
        HTTP[version],
        -- Pre-allocate slots for minimum headers and carriage return.
        true,
        true,
        true,
    }
    local c = 6 -- req table index - it's faster to do this inline vs table.insert

    -- Append headers
    for key, values in pairs(headers) do
        if type(values) ~= "table" then
            values = {values}
        end

        key = tostring(key)
        for _, value in pairs(values) do
            req[c] = key .. ": " .. tostring(value) .. "\r\n"
            c = c + 1
        end
    end

    -- Close headers
    req[c] = "\r\n"

    return tbl_concat(req)
end


local function _receive_status(sock)
    local line, err = sock:receive("*l")
    if not line then
        return nil, err
    end

    return tonumber(str_sub(line, 10, 12))
end


local function _receive_headers(self)
    local sock = self.sock
    local headers = {}

    repeat
        local line = sock:receive()

        for key, val in str_gmatch(line, "([%w%-]+)%s*:%s*(.+)") do
            if headers[key] then
                headers[key] = headers[key] .. ", " .. tostring(val)
            else
                headers[key] = tostring(val)
            end
        end
    until str_find(line, "^%s*$")

    return headers, nil
end


local function _receive_chunked(sock)
    local chunks = {}
    local c = 1

    local size = 0

    repeat
        local str, err = sock:receive("*l")
        if not str then
            return nil, err
        end

        local length = tonumber(str, 16)

        if not length then
            return nil, "unable to read chunksize"
        end

        if length > 0 then
            local str, err = sock:receive(length)
            if not str then
                return nil, err
            end
            chunks[c] = str
            c = c + 1
        end

        sock:receive(2) -- read \r\n
    until length == 0

    return tbl_concat(chunks), nil
end


local function _receive_body(self, headers)
    local sock = self.sock
    local length = tonumber(headers["Content-Length"])
    local body
    local err

    local keepalive = true

    if length then
        body, err = sock:receive(length)
    else
        local encoding = headers["Transfer-Encoding"]
        if encoding and str_lower(encoding) == "chunked" then
            body, err = _receive_chunked(sock)
        else
            body, err = sock:receive("*a")
            keepalive = false
        end
    end

    if not body then 
        keepalive = false
    end

    self.keepalive = keepalive

    return body
end


local function _request_raw(self, params)
    local sock = self.sock

    -- Apply defaults
    for k,v in pairs(default_params) do
        if not params[k] then
            params[k] = v
        end
    end
    
    local body = params.body
    local headers = params.headers
    
    -- Ensure minimal headers are set
    if body then
        headers["Content-Length"] = #body
    end
    if not headers["Host"] then
        headers["Host"] = host
    end
    if not headers["User-Agent"] then
        headers["User-Agent"] = USER_AGENT
    end
    if params.version == 1.0 and not headers["Connection"] then
        headers["Connection"] = "Keep-Alive"
    end

    -- Format and send request
    local req = _format_request(params)
    ngx.log(ngx.NOTICE, "\n"..req)
    sock:send(req)

    local status = _receive_status(sock)
    local headers = _receive_headers(self)
    local body = nil

    if _should_receive_body(params.method, status) then
        body = _receive_body(self, headers)
    end

    return status, headers, body
end
_M._request_raw = _request_raw


function _M.connect(host, port)
    local sock, err = ngx_socket_tcp()
    if not sock then
        return nil, err
    end

    local c, err = sock:connect(host, port)
    if not c then
        return nil, err
    end

    return setmetatable({ sock = sock, host = host, port = port }, mt)
end


function _M.close(self)
    local sock = self.sock
    local keepalive = self.keepalive
    
    if keepalive then
        ngx.log(ngx.NOTICE, "Socket reused " .. sock:getreusedtimes() .. " times")
        sock:setkeepalive()
    else
        sock:close()
    end
end


-- Choose between simple and raw interfaces.
function _M.request(...)
    return _request_raw(...)
--[[
    local args = {...}
    if type(args[1]) == "string" then
        return _request_simple(...)
    elseif type(args[1]) == "table" then
        return _request_raw(...)
    end
]]--
end


return _M
