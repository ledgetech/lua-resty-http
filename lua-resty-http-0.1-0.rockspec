package = "lua-resty-http"
version = "0.1-0"
source = {
  url = "https://github.com/DorianGray/lua-resty-http/archive/v0.1.tar.gz",
  dir = "lua-resty-http-0.1"
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
    ["resty.http"] = "lib/resty/http.lua"
  }
}
