# lua-resty-http


Lua HTTP client driver for [ngx_lua](https://github.com/chaoslawful/lua-nginx-module) based on the cosocket API. Supports HTTP 1.0 and 1.1, including chunked transfer encoding for response bodies, and provides a streaming interface to the body irrespective of transfer encoding.

## Status

This is newish, but works and passes tests. Please send any design feedback or actual bugs on the issues page.

## Synopsis

```` lua
lua_package_path "/path/to/lua-resty-http/lib/?.lua;;";

server {
  location /simpleinterface {
    content_by_lua '
    
      -- For simple work, use the URI interface...
      local httpc = http.new()
      local res, err = httpc:request_uri("http://example.com/helloworld", {
        method = "POST",
        body = "a=1&b=2",
        headers = {
          ["Content-Type"] = "application/x-www-form-urlencoded",
        }
      })
      
      -- In this simple form, there is no manual connection step, so the body is read 
      -- all in one go, including any trailers, and the connection closed or keptalive 
      -- for you.
  
      ngx.status = res.status
      
      for k,v in pairs(res.headers) do
          --
      end
      
      ngx.say(res.body)
    ';
  }

  location /generic {
    content_by_lua '
      local http = require "resty.http"
      local httpc = http.new()
      
      -- The generic form gives us more control. We must connect manually...
      httpc:set_timeout(500)
      httpc:connect("127.0.0.1", 80)
      
      -- And request using a path, rather than a full URI...
      local res, err = httpc:request{
          path = "/helloworld",
          headers = {
              ["Host"] = "example.com",
          },
      }

      -- Or stream the request body in
      local request_reader, err = httpc:get_request_reader()
      if not request_reader then
          if err == "chunked request bodies not supported yet" then
              ngx.status = 411
              ngx.say("411 Length Required")
              ngx.exit(ngx.status)
          end
      end

      local res, err = httpc:request{
          path = "/helloworld",
          body = request_reader,
          headers = {
              ["Host"] = "example.com",
          },
      }

      if not res then
          ngx.log(ngx.ERR, err)
          ngx.exit(500)
      end
      
      ngx.say(res.status)
      
      for k,v in pairs(res.headers) do
          --
      end
      
      -- METHOD 1.
      -- At this point, the body has not been read. You can read it in one go 
      -- if you like...
      local body = res:read_body()
      
      
      -- METHOD 2.
      -- Or, stream the body using an iterator, for predictable memory usage 
      -- in Lua land.
      local reader = res.body_reader
      
      repeat
        local chunk, err = reader(8192)
        if err then
          ngx.log(ngx.ERR, err)
          break
        end
        
        if chunk then
          -- process
        end
      until not chunk
      
      
      -- METHOD 3.
      -- Or, introduce your own coroutine filter to modify the chunks as they arrive.
      function get_filter(reader)
          return coroutine.wrap(function(max_bytes)
              repeat
                  local chunk, err = reader(max_bytes)
                  if not chunk then
                      coroutine.yield(nil, err)
                      break
                  end
      
                  -- Process data
      
                  coroutine.yield(chunk)
              until not chunk
          end)
      end

      -- pass the body reader to your filter
      local reader = get_filter(res.body_reader)
      
      -- then read via your filter(s) as above
      repeat
        local chunk, err = reader(8192)
        if err then
          ngx.log(ngx.ERR, err)
          break
        end
        
        if chunk then
          ngx.print(chunk)
        end
      until not chunk
        
      
      -- If the response advertised trailers, you can merge them with the headers now
      res:read_trailers()
      
      httpc:set_keepalive()
    ';
  }
}
````

## API

### Connection

#### new

`syntax: httpc = http.new()`

Creates the http object. In case of failures, returns `nil` and a string describing the error.

#### connect

`syntax: ok, err = httpc:connect(host, port, options_table?)`

`syntax: ok, err = httpc:connect("unix:/path/to/unix.sock", options_table?)`

Attempts to connect to the web server.

Before actually resolving the host name and connecting to the remote backend, this method will always look up the connection pool for matched idle connections created by previous calls of this method.

An optional Lua table can be specified as the last argument to this method to specify various connect options:

* `pool`
: Specifies a custom name for the connection pool being used. If omitted, then the connection pool name will be generated from the string template `<host>:<port>` or `<unix-socket-path>`.

#### set_timeout

`syntax: httpc:set_timeout(time)`

Sets the timeout (in ms) protection for subsequent operations, including the `connect` method.

#### set_keepalive

`syntax: ok, err = httpc:set_keepalive(max_idle_timeout, pool_size)`

Attempts to puts the current connection into the ngx_lua cosocket connection pool.

You can specify the max idle timeout (in ms) when the connection is in the pool and the maximal size of the pool every nginx worker process.

Only call this method in the place you would have called the `close` method instead. Calling this method will immediately turn the current http object into the `closed` state. Any subsequent operations other than `connect()` on the current objet will return the `closed` error.

Note that calling this instead of `close` is "safe" in that it will conditionally close depending on the type of request. Specifically, a `1.0` request without `Connection: Keep-Alive` will be closed, as will a `1.1` request with `Connection: Close`.

In case of success, returns `1`. In case of errors, returns `nil` with a string describing the error. In the case where the conneciton is conditionally closed as described above, returns `2` and the error string `connection must be closed`.

#### get_reused_times

`syntax: times, err = httpc:get_reused_times()`

This method returns the (successfully) reused times for the current connection. In case of error, it returns `nil` and a string describing the error.

If the current connection does not come from the built-in connection pool, then this method always returns `0`, that is, the connection has never been reused (yet). If the connection comes from the connection pool, then the return value is always non-zero. So this method can also be used to determine if the current connection comes from the pool.

#### close

`syntax: ok, err = http:close()`

Closes the current connection and returns the status.

In case of success, returns `1`. In case of errors, returns `nil` with a string describing the error.

#### get_request_reader

`syntax: reader, err = httpc:get_request_reader()`

Returns an iterator function which can be used to read the request body in a chunked fashion. This iterator can be set used as the body field in request params.

```lua
local req_reader = httpc:get_request_reader()

repeat
  local chunk, err = req_reader(8192)
  if err then
    ngx.log(ngx.ERR, err)
    break
  end

  if chunk then
    -- process
  end
until not chunk
```

### Requesting

#### request

`syntax: res, err = httpc:request(params)`

Returns a `res` table or `nil` and an error message.

The `params` table accepts the following fields:

* `version` The HTTP version number, currently supporting 1.0 or 1.1.
* `method` The HTTP method string.
* `path` The path string.
* `headers` A table of request headers.
* `body` The request body as a string or aniterator function.

When the request is successful, `res` will contain the following fields:

* `status` The status code.
* `headers` A table of headers.
* `body_reader` An iterator function for reading the body in a streaming fashion.
* `read_body` A method to read the entire body into a string.
* `read_trailers` A method to merge any trailers underneath the headers, after reading the body.

##### res.body_reader

The `body_reader` iterator can be used to stream the response body in chunk sizes of your choosing, as follows:

````lua
local reader = res.body_reader

repeat
  local chunk, err = reader(8192)
  if err then
    ngx.log(ngx.ERR, err)
    break
  end
  
  if chunk then
    -- process
  end
until not chunk
````

If the reader is called with no arguments, the behaviour depends on the type of connection. If the response is encoded as chunked, then the iterator will return the chunks as they arrive. If not, it will simply return the entire body.

Note that the size provided is actually a **maximum** size. So in the chunked transfer case, you may get chunks smaller than the size you ask, as a remainder of the actual HTTP chunks.

##### res:read_body

`syntax: body, err = res:read_body()`

Reads the body into a local string.


##### res:read_trailers

`syntax: res:read_trailers()`

This merges any trailers headers underneath the `res.headers` table itself.


#### request_uri

`syntax: res, err = httpc:request_uri(uri, params)`

The simple interface. Options supplied in the `params` table are the same as in the generic interface, and will override components found in the uri itself.

In this mode, there is no need to connect manually first. The connection is made on your behalf, suiting cases where you simply need to grab a URI without too much hassle.

Additionally there is no ability to stream the response body in this mode. If the request is successful, `res` will contain the following fields:

* `status` The status code.
* `headers` A table of headers.
* `body` The response body as a string.


### Utility

#### parse_uri

`syntax: local scheme, host, port, path = unpack(httpc:parse_uri(uri))`

This is a convenience function allowing one to more easily use the generic interface, when the input data is a URI. 


## Author

James Hurst <james@pintsized.co.uk>

Originally started life based on https://github.com/bakins/lua-resty-http-simple. Cosocket docs and implementation borrowed from the other lua-resty-* cosocket modules.


## Licence

This module is licensed under the 2-clause BSD license.

Copyright (c) 2013, James Hurst <james@pintsized.co.uk>

All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

* Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

* Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
