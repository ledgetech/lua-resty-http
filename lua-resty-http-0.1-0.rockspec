package = "lua-resty-http"
version = "0.1-0"
source = {
  url = "",
  dir = "fakengx"
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
