local ngx_socket_tcp = ngx.socket.tcp
local ngx_req = ngx.req
local ngx_req_socket = ngx_req.socket
local ngx_req_get_headers = ngx_req.get_headers
local str_gmatch = string.gmatch
local str_lower = string.lower
local str_upper = string.upper
local str_find = string.find
local str_sub = string.sub
local tbl_concat = table.concat
local ngx_encode_args = ngx.encode_args
local ngx_re_match = ngx.re.match
local ngx_log = ngx.log
local ngx_DEBUG = ngx.DEBUG
local ngx_ERR = ngx.ERR
local co_yield = coroutine.yield
local co_create = coroutine.create
local co_status = coroutine.status
local co_resume = coroutine.resume


-- Reimplemented coroutine.wrap, returning "nil, err" if the coroutine cannot
-- be resumed. This protects user code from inifite loops when doing things like
-- repeat
--   local chunk, err = res.body_reader()
--   if chunk then -- <-- This could be a string msg in the core wrap function.
--     ...
--   end
-- until not chunk
local co_wrap = function(func) 
    local co = co_create(func)
    if not co then
        return nil, "could not create coroutine"
    else
        return function(...)
            if co_status(co) == "suspended" then
                return select(2, co_resume(co, ...))
            else
                return nil, "can't resume a " .. co_status(co) .. " coroutine"
            end
        end
    end
end


local _M = {
    _VERSION = '0.03',
}

local mt = { __index = _M }


local HTTP = {
    [1.0] = " HTTP/1.0\r\n",
    [1.1] = " HTTP/1.1\r\n",
}

local USER_AGENT = "Resty/HTTP " .. _M._VERSION .. " (Lua)"

local DEFAULT_PARAMS = {
    method = "GET",
    path = "/",
    version = 1.1,
}


function _M.new(self)
    local sock, err = ngx_socket_tcp()
    if not sock then
        return nil, err
    end
    return setmetatable({ sock = sock, keepalive = true }, mt)
end


function _M.set_timeout(self, timeout)
    local sock = self.sock
    if not sock then
        return nil, "not initialized"
    end

    return sock:settimeout(timeout)
end


function _M.connect(self, ...)
    local sock = self.sock
    if not sock then
        return nil, "not initialized"
    end

    self.host = select(1, ...)

    return sock:connect(...)
end


function _M.set_keepalive(self, ...)
    local sock = self.sock
    if not sock then
        return nil, "not initialized"
    end

    if self.keepalive == true then
        return sock:setkeepalive(...)
    else
        -- The server said we must close the connection, so we cannot setkeepalive.
        -- If close() succeeds we return 2 instead of 1, to differentiate between 
        -- a normal setkeepalive() failure and an intentional close().
        local res, err = sock:close()
        if res then
            return 2, "connection must be closed"
        else
            return res, err
        end
    end
end


function _M.get_reused_times(self)
    local sock = self.sock
    if not sock then
        return nil, "not initialized"
    end

    return sock:getreusedtimes()
end


function _M.close(self)
    local sock = self.sock
    if not sock then
        return nil, "not initialized"
    end

    return sock:close()
end


local function _should_receive_body(method, code)
    if method == "HEAD" then return nil end
    if code == 204 or code == 304 then return nil end
    if code >= 100 and code < 200 then return nil end
    return true
end


function _M.parse_uri(self, uri)
    local m, err = ngx_re_match(uri, [[^(http[s]*)://([^:/]+)(?::(\d+))?(.*)]], 
        "jo")

    if not m then
        if err then
            return nil, "failed to match the uri: " .. err
        end

        return nil, "bad uri"
    else
        if not m[3] then m[3] = 80 end
        if not m[4] then m[4] = "/" end
        return m, nil
    end
end


local function _format_request(params)
    local version = params.version
    local headers = params.headers or {}

    local query = params.query or ""
    if query then
        if type(query) == "table" then
            query = "?" .. ngx_encode_args(query)
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
    local c = 6 -- req table index it's faster to do this inline vs table.insert

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
        return nil, nil, err
    end

    return tonumber(str_sub(line, 10, 12)), tonumber(str_sub(line, 6, 8))
end


local function _receive_headers(sock)
    local headers = {}

    repeat
        local line, err = sock:receive("*l")
        if not line then 
            return nil, err
        end

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


local function _chunked_body_reader(sock, default_chunk_size)
    return co_wrap(function(max_chunk_size)
        local max_chunk_size = max_chunk_size or default_chunk_size
        local remaining = 0
        local length

        repeat 
            -- If we still have data on this chunk
            if max_chunk_size and remaining > 0 then

                if remaining > max_chunk_size then
                    -- Consume up to max_chunk_size
                    length = max_chunk_size
                    remaining = remaining - max_chunk_size
                else
                    -- Consume all remaining
                    length = remaining
                    remaining = 0
                end
            else -- This is a fresh chunk 

                -- Receive the chunk size
                local str, err = sock:receive("*l")
                if not str then
                    co_yield(nil, err)
                end

                length = tonumber(str, 16)

                if not length then
                    co_yield(nil, "unable to read chunksize")
                end
            
                if max_chunk_size and length > max_chunk_size then
                    -- Consume up to max_chunk_size
                    remaining = length - max_chunk_size
                    length = max_chunk_size
                end
            end

            if length > 0 then
                local str, err = sock:receive(length)
                if not str then
                    co_yield(nil, err)
                end
                
                max_chunk_size = co_yield(str) or default_chunk_size

                -- If we're finished with this chunk, read the carriage return.
                if remaining == 0 then
                    sock:receive(2) -- read \r\n
                end
            else
                -- Read the last (zero length) chunk's carriage return
                sock:receive(2) -- read \r\n
            end

        until length == 0
    end)
end


local function _body_reader(sock, content_length, default_chunk_size)
    return co_wrap(function(max_chunk_size)
        local max_chunk_size = max_chunk_size or default_chunk_size

        if not content_length and max_chunk_size then
            -- We have no length, but wish to stream.
            -- HTTP 1.0 with no length will close connection, so read chunks to the end.
            repeat
                local str, err, partial = sock:receive(max_chunk_size)
                if not str and err == "closed" then
                    max_chunk_size = co_yield(partial, err) or default_chunk_size
                end

                max_chunk_size = co_yield(str) or default_chunk_size
            until not str

        elseif not content_length then
            -- We have no length but don't wish to stream.
            -- HTTP 1.0 with no length will close connection, so read to the end.
            co_yield(sock:receive("*a"))

        elseif not max_chunk_size then
            -- We have a length and potentially keep-alive, but want everything.
            co_yield(sock:receive(content_length))

        else
            -- We have a length and potentially a keep-alive, and wish to stream
            -- the response.
            local received = 0
            repeat
                local length = max_chunk_size
                if received + length > content_length then
                    length = content_length - received
                end

                if length > 0 then
                    local str, err = sock:receive(length)
                    if not str then
                        max_chunk_size = co_yield(nil, err) or default_chunk_size
                    end
                    received = received + length

                    max_chunk_size = co_yield(str) or default_chunk_size
                end

            until length == 0
        end
    end)
end


local function _no_body_reader()
    return nil
end


local function _read_body(res)
    local reader = res.body_reader

    if not reader then 
        -- Most likely HEAD or 304 etc.
        return nil, "no body to be read"
    end

    local chunks = {}
    local c = 1

    local chunk, err
    repeat
        chunk, err = reader()

        if err then
            return nil, err, tbl_concat(chunks) -- Return any data so far.
        end
        if chunk then
            chunks[c] = chunk
            c = c + 1
        end
    until not chunk

    return tbl_concat(chunks)
end


local function _trailer_reader(sock)
    return co_wrap(function()
        co_yield(_receive_headers(sock))
    end)
end


local function _read_trailers(res)
    local reader = res.trailer_reader
    if not reader then
        return nil, "no trailers"
    end

    local trailers = reader()
    setmetatable(res.headers, { __index = trailers })
end


local function _send_body(sock, body)
    if type(body) == 'function' then
        repeat
            local chunk, err, partial = body()

            if chunk then
                local ok,err = sock:send(chunk)

                if not ok then
                    return nil, err
                end
            elseif err ~= nil then
                return nil, err, partial
            end

        until chunk == nil
    elseif body ~= nil then
        local bytes, err = sock:send(body)

        if not bytes then
            return nil, err
        end
    end
    return true, nil
end


local function _handle_continue(sock, body)
    local status, version, err = _receive_status(sock)
    if not status then
        return nil, err
    end

    -- Only send body if we receive a 100 Continue
    if status == 100 then
        local ok, err = sock:receive("*l") -- Read carriage return
        if not ok then
            return nil, err
        end
        _send_body(sock, body)
    end
    return status, version, err
end


function _M.send_request(self, params)
    -- Apply defaults
    setmetatable(params, { __index = DEFAULT_PARAMS })

    local sock = self.sock
    local body = params.body
    local headers = params.headers or {}
    
    -- Ensure minimal headers are set
    if type(body) == 'string' and not headers["Content-Length"] then
        headers["Content-Length"] = #body
    end
    if not headers["Host"] then
        headers["Host"] = self.host
    end
    if not headers["User-Agent"] then
        headers["User-Agent"] = USER_AGENT
    end
    if params.version == 1.0 and not headers["Connection"] then
        headers["Connection"] = "Keep-Alive"
    end

    params.headers = headers

    -- Format and send request
    local req = _format_request(params)
    ngx_log(ngx_DEBUG, "\n", req)
    local bytes, err = sock:send(req)

    if not bytes then
        return nil, err
    end

    -- Send the request body, unless we expect: continue, in which case
    -- we handle this as part of reading the response.
    if headers["Expect"] ~= "100-continue" then
        local ok, err, partial = _send_body(sock, body)
        if not ok then
            return nil, err, partial
        end
    end

    return true
end


function _M.read_response(self, params)
    local sock = self.sock

    local status, version, err

    -- If we expect: continue, we need to handle this, sending the body if allowed.
    -- If we don't get 100 back, then status is the actual status.
    if params.headers["Expect"] == "100-continue" then
        local _status, _version, _err = _handle_continue(sock, params.body)
        if not _status then
            return nil, _err
        elseif _status ~= 100 then
            status, version, err = _status, _version, _err
        end
    end

    -- Just read the status as normal.
    if not status then
        status, version, err = _receive_status(sock)
        if not status then
            return nil, err
        end
    end


    local res_headers, err = _receive_headers(sock)
    if not res_headers then 
        return nil, err
    end

    -- Determine if we should keepalive or not.
    local connection = str_lower(res_headers["Connection"] or "")
    if  (version == 1.1 and connection == "close") or
        (version == 1.0 and connection ~= "keep-alive") then
            self.keepalive = false
    end

    local body_reader = _no_body_reader
    local trailer_reader, err = nil, nil
    local has_body = false

    -- Receive the body_reader
    if _should_receive_body(params.method, status) then
        has_body = true
        local length = tonumber(res_headers["Content-Length"])
        local encoding = res_headers["Transfer-Encoding"] or ""

        if version == 1.1 and str_lower(encoding) == "chunked" then
            body_reader, err = _chunked_body_reader(sock)
        else
            body_reader, err = _body_reader(sock, length)
        end
    end

    if res_headers["Trailer"] then
        trailer_reader, err = _trailer_reader(sock)
    end

    if err then
        return nil, err
    else
        return { 
            status = status, 
            headers = res_headers, 
            has_body = has_body,
            body_reader = body_reader,
            read_body = _read_body,
            trailer_reader = trailer_reader,
            read_trailers = _read_trailers,
        }
    end
end


function _M.request(self, params)
    local res, err = self:send_request(params)
    if not res then
        return res, err
    else
        return self:read_response(params)
    end
end


function _M.request_pipeline(self, requests)
    for i, params in ipairs(requests) do
        if params.headers and params.headers["Expect"] == "100-continue" then
            return nil, "Cannot pipeline request specifying Expect: 100-continue"
        end

        local res, err = self:send_request(params)
        if not res then
            return res, err
        end
    end

    local responses = {}
    for i, params in ipairs(requests) do
        responses[i] = setmetatable({ 
            params = params,
            response_read = false,
        }, {
            -- Read each actual response lazily, at the point the user tries
            -- to access any of the fields.
            __index = function(t, k)
                local res, err
                if t.response_read == false then
                    res, err = _M.read_response(self, t.params)
                    t.response_read = true

                    if not res then
                        ngx_log(ngx_ERR, err)
                    else
                        for rk, rv in pairs(res) do
                            t[rk] = rv
                        end
                    end
                end
                return rawget(t, k)
            end,
        })
    end
    return responses
end


function _M.request_uri(self, uri, params)
    if not params then params = {} end

    local parsed_uri, err = self:parse_uri(uri)
    if not parsed_uri then
        return nil, err
    end

    local scheme, host, port, path = unpack(parsed_uri)
    if not params.path then params.path = path end

    local c, err = self:connect(host, port, {ssl = scheme == "https", ssl_verify_name=true})
    if not c then
        return nil, err
    end

    local res, err = self:request(params)
    if not res then
        return nil, err
    end

    local body, err = res:read_body()
    if not body then
        return nil, err
    end
    
    res.body = body

    local ok, err = self:set_keepalive()
    if not ok then
        ngx_log(ngx_ERR, err)
    end

    return res, nil
end


function _M.get_client_body_reader(self, chunksize)
    local chunksize = chunksize or 65536
    local sock, err = ngx_req_socket()

    if not sock then
        if err == "no body" then
            return nil
        else
            return nil, err
        end
    end

    local headers = ngx_req_get_headers()
    local length = headers["Content-Length"]
    local encoding = headers["Transfer-Encoding"]
    if length then
        return _body_reader(sock, tonumber(length), chunksize)
    elseif str_lower(encoding) == 'chunked' then
        -- Not yet supported by ngx_lua but should just work...
        return _chunked_body_reader(sock, chunksize)
    else
       return nil, "Unknown transfer encoding"
    end
end


return _M
