# nim-http
An alternate http client for nim
why?
- add unix socket support
- add ability to recv stream data in sync that doesn't require the body to finish
- sync and async api

## Todo
- [ ] http2 support
- [ ] add more tests
- [ ] add multipart support
- [ ] add more examples
- [ ] add proxy support
- [x] add send body
- [x] add send body in chunks
- [x] add ssl support
- [x] add unix socket support
- [x] add data stream and iter chunk support
- [x] convert code to multisync
- [ ] add http error raising (?) probably not


## Usage
```nim
import nim-client

proc main() =
  let client: HttpClient
  let resp = client.fetch(HttpGet, "https://httpbin.org/get")
  
  case resp.httpCode:
  of Http200:
    # data iterator 
    for data in resp.body():
        echo data
    ## get body all at once  
    # resp.body()
    ## data stream
    ## happens all at once
    #resp.recvStream()
    ## then this happens
    #resp.stream.readAll()
  else:
    raise 
 
proc mainAsync() {.async.} =
  let client: AsyncHttpClient
  let resp = await client.fetch(HttpGet, "https://httpbin.org/get")
  for data in resp.body():
    echo data

when isMainModule:
  main()
  mainAsync()

```
