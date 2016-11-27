package = "lua-resty-http"
version = "0.2-0"
source = {
  url = "https://github.com/DorianGray/lua-resty-http/archive/v0.2.tar.gz",
  dir = "lua-resty-http-0.2"
}
description = {
  summary = "",
  detailed = [[
  ]],
  homepage = "",
  license = ""
}
dependencies = {
  "lua >= 5.1",
}
build = {
  type = "builtin",
  modules = {
    ["resty.http"] = "lib/resty/http.lua",
    ["resty.http_headers"] = "lib/resty/http_headers.lua"
  }
}
