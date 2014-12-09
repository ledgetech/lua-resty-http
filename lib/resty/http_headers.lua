local   rawget, rawset, setmetatable = 
        rawget, rawset, setmetatable

local str_gsub = string.gsub
local str_lower = string.lower


local _M = {
    _VERSION = '0.01',
}

local mt = { 
    normalised = {}
}


mt.__index = function(t, k)
    k = str_gsub(str_lower(k), "-", "_")
    if mt.normalised[k] then
        return rawget(t, mt.normalised[k])
    end
end


mt.__newindex = function(t, k, v)
    local k_low = str_gsub(str_lower(k), "-", "_")
    if not mt.normalised[k_low] then
        mt.normalised[k_low] = k
        rawset(t, k, v)
    else
        rawset(t, mt.normalised[k_low], v)
    end
end


function _M.new(self)
    return setmetatable({}, mt)
end


return _M
