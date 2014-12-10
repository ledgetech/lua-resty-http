local   rawget, rawset, setmetatable = 
        rawget, rawset, setmetatable

local str_gsub = string.gsub
local str_lower = string.lower


local _M = {
    _VERSION = '0.01',
}


-- Returns an empty headers table with internalised case normalisation. 
-- Supports the same cases as in ngx_lua:
--
-- headers.content_length
-- headers["content-length"]
-- headers["Content-Length"]
function _M.new(self)
    local mt = { 
        normalised = {},
    }


    mt.__index = function(t, k)
        local k_hyphened = str_gsub(k, "_", "-")
        local matched = rawget(t, k)
        if matched then
            return matched
        else
            local k_normalised = str_lower(k_hyphened)
            return rawget(mt.normalised, k_normalised)
        end
    end


    mt.__newindex = function(t, k, v)
        local k_hyphened = str_gsub(k, "_", "-")
        local k_normalised = str_lower(k_hyphened)
        rawset(mt.normalised, k_normalised, v)
        rawset(t, k_hyphened, v)
    end

    return setmetatable({}, mt)
end


return _M
