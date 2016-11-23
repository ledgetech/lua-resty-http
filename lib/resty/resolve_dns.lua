-- code from the blog
-- http://hambut.com/2016/09/09/how-to-resolve-the-domain-name-in-openresty/?utm_source=tuicool&utm_medium=referral
local require = require
local ngx_re_find = ngx.re.find
local lrucache = require "resty.lrucache"
local resolver = require "resty.dns.resolver"
local cache_storage = lrucache.new(200)
local pcall = pcall
local io_open = io.open
local ngx_re_gmatch = ngx.re.gmatch

local ok, new_tab = pcall(require, "table.new")

if not ok then
    new_tab = function (narr, nrec) return {} end
end

local _dns_servers = new_tab(5, 0)

local _read_file_data = function(path)
    local f, err = io_open(path, 'r')

    if not f or err then
        return nil, err
    end

    local data = f:read('*all')
    f:close()
    return data, nil
end

local _read_dns_servers_from_resolv_file = function()
    local text = _read_file_data('/etc/resolv.conf')

    local captures, it, err
    it, err = ngx_re_gmatch(text, [[^nameserver\s+(\d+?\.\d+?\.\d+?\.\d+$)]], "jomi")

    for captures, err in it do
        if not err then
            _dns_servers[#_dns_servers + 1] = captures[1]
        end
    end
end

local _is_addr = function(hostname)
    return ngx_re_find(hostname, [[\d+?\.\d+?\.\d+?\.\d+$]], "jo")
end

local _get_addr = function(hostname)
    if _is_addr(hostname) then
        return hostname, hostname
    end

    local addr = cache_storage:get(hostname)

    if addr then
        return addr, hostname
    end

    _read_dns_servers_from_resolv_file()
    local r, err = resolver:new({
        nameservers = _dns_servers,
        retrans = 5,  -- 5 retransmissions on receive timeout
        timeout = 2000,  -- 2 sec
    })

    if not r then
        return nil, hostname
    end

    local answers, err = r:query(hostname, {qtype = r.TYPE_A})

    if not answers or answers.errcode then
        return nil, hostname
    end

    for i, ans in ipairs(answers) do
        if ans.address then
            cache_storage:set(hostname, ans.address, 300)
            return ans.address, hostname
        end
    end

    return nil, hostname
end

return _get_addr
