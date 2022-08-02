import
  httpcore,
  net,
  asyncnet,
  asyncdispatch,
  streams,
  uri,
  strutils,
  os,
  jsony,
  print

type
  HttpClient* = object
    uri: Uri
    sslContext: SslContext

  Async* = object
  Sync* = object
  Greeting* = object
    httpVersion: HttpVersion
    httpCode: HttpCode
    ok: bool
    message: string

  Response = object
    httpCode: HttpCode
    headers: HttpHeaders
    stream: Stream
    socket: Socket
  AsyncResponse = object
    httpCode: HttpCode
    headers: HttpHeaders
    stream: Stream
    socket: AsyncSocket

  Chunk = object
    size: int
    ext: HttpHeaders
    data: string

  HttpError = object of IOError


proc initAsyncUnixSocket*(uri: Uri | string): Future[AsyncSocket] {.async.} =
  var uri = when uri is string: uri.parseUri() else: uri
  result = newAsyncSocket(
    Domain.AF_UNIX,
    SockType.SOCK_STREAM,
    Protocol.IPPROTO_IP
  )
  await result.connectUnix(uri.hostname)

proc initUnixSocket*(uri: Uri | string): Socket =
  var uri = when uri is string: uri.parseUri() else: uri
  result = newSocket(
    Domain.AF_UNIX,
    SockType.SOCK_STREAM,
    Protocol.IPPROTO_IP
  )
  result.connectUnix(uri.hostname)



proc initSocket(uri: Uri): Socket =
  var uri = uri
  var port = if uri.port != "": Port(uri.port.parseInt()) 
    elif uri.scheme == "https": Port(443)
    else: Port(80)
  if uri.scheme == "unix":
    return initUnixSocket(uri)
  return net.dial(uri.hostname, port)

proc initAsyncSocket(uri: Uri): Future[AsyncSocket] {.async.} =
  var uri = uri
  var port = if uri.port != "": Port(uri.port.parseInt()) 
    elif uri.scheme == "https": Port(443)
    else: Port(80)
  if uri.scheme == "unix":
    return await initAsyncUnixSocket(uri)
  return await asyncnet.dial(uri.hostname, port)

proc sendGreeting(socket: Socket | AsyncSocket, httpMethod: HttpMethod, path: string): Future[void] {.multisync.} =
  let message = $httpMethod & " " & path & " HTTP/1.1\r\n"
  when defined(verbose): echo "> ", message
  await socket.send(message)

proc sendHeaders(socket: Socket | AsyncSocket, headers: HttpHeaders): Future[void] {.multisync.} =
  for key, value in headers:
    when defined(verbose): echo "h> ", key, ": ", value
    await socket.send(key & ": " & value & "\r\n")
  await socket.send("\r\n")

proc sendBody(socket: Socket | AsyncSocket, body: string): Future[void] {.multisync.} =
  # TODO: chunked encoding
  await socket.send(body)

proc recvGreeting(socket: Socket | AsyncSocket): Future[Greeting] {.multisync.} =
  var line = await socket.recvLine()
  var parts = line.split(" ")
  if not parts.len >= 3:
    raise newException(HttpError, "Invalid greeting: " & line)
  if parts[0] != "HTTP/1.1":
    raise newException(HttpError, "Invalid greeting: " & line)
  
  result.httpVersion = HttpVer11
  result.httpCode = HttpCode(parts[1].parseInt())
  result.ok = result.httpCode == Http200
  result.message = parts[2..parts.high].join(" ")

proc recvHeaders(socket: Socket | AsyncSocket): Future[HttpHeaders] {.multisync.} =
  result = newHttpHeaders()
  while true:
    var line = await socket.recvLine()
    when defined(verbose): echo "h< ", line
    if line == "\r\n":
      break
    var posSplit = line.find(":")
    if posSplit < 0:
      raise newException(HttpError, "Invalid header: " & line)
    result.add(line[0..posSplit-1].strip(), line[posSplit+1..line.high].strip())

proc recvChunk*(socket: Socket | AsyncSocket): Future[Chunk] {.multisync.} =
  let chunkHeader = await socket.recvLine()
  when defined(verbose): echo "ch< ", cast[seq[char]](chunkHeader)
  let chunkHeaderSpacePos = chunkHeader.find(' ')

  if chunkHeaderSpacePos == -1:
    result.size = fromHex[int](chunkHeader)
  else:
    result.size = fromHex[int](chunkHeader[0..chunkHeaderSpacePos-1])
    let chunkExtention = chunkHeader[chunkHeaderSpacePos+1..chunkHeader.high]
    raise newException(HttpError, "chunk extention not supported: " & chunkExtention)
  
  # pass the data of expected size
  result.data = await socket.recv(result.size)
  when defined(verbose): echo "cd< ", cast[seq[char]](result.data)

  # then receve the trailing \r\n
  let expectedNewLine = await socket.recvLine()
  when defined(verbose): echo "enl< ", cast[seq[char]](expectedNewLine)

  if expectedNewLine != "\r\n":
    raise newException(HttpError, "expected \\r\\n but got: " & expectedNewLine)

iterator recvData*(response: Response | AsyncResponse): string =
  ## iterator over the data of the response
  ## if you want to work with streams use recvStream instead which implements this iterator
  var chunked = response.headers.getOrDefault("Transfer-Encoding").contains("chunked")
  var contentLength = if response.headers.hasKey("Content-Length"): response.headers["Content-Length"].parseInt() else: -1
  if chunked:
    var chunk = when response is Response: response.socket.recvChunk() else: waitFor response.socket.recvChunk()
    while chunk.size > 0 and chunk.data != "\r\n":
      yield chunk.data
      chunk = when response is Response: response.socket.recvChunk() else: waitFor response.socket.recvChunk()
  elif  contentLength > 0: 
    let line = when response is Response: response.socket.recv(contentLength) else: waitFor response.socket.recv(contentLength)
    when defined(verbose): echo "cl< ", cast[seq[char]](line)
    yield line
  else:
    while true:
      let line = when response is Response: response.socket.recvLine() else: waitFor response.socket.recvLine()
      when defined(verbose): echo "r< ", cast[seq[char]](line)
      if line.len == 0 or line == "\r\n":
        break
      yield line

proc recvStream*(response: Response): void =
  ## use this to return a stream of data
  ## this will block until finished if using in a sync context
  ## use recvData if you want to do something with the data as it comes in
  ## Note: Errors are returned as httpCodes in response
  defer: response.stream.close()
  for data in response.recvData():
    response.stream.write(data)
  
let defaultHeaders = {
  "user-agent": "nim-httpclient/0.1",
  "Accept": "*/*",
}

proc fetch*(
    client: Sync | Async,
    httpMethod: HttpMethod,
    uri: Uri | string,
    body: string = "",
    # multiPart: MultiPart
    headers: HttpHeaders = newHttpHeaders(defaultHeaders),
    sslContext: SslContext = nil
  ): Future[Response | AsyncResponse] {.multisync.} =
  # set up the uri
  var uri = when uri is string: parseUri(uri) else: uri
  # set up the socket
  var socket = when client is Sync: initSocket(uri) else: await initAsyncSocket(uri) 
  when defined(ssl):
    if uri.scheme == "https":
      let sslContext = if sslContext != nil: sslContext else: newContext()
      wrapConnectedSocket(sslContext, socket, handshakeAsClient, uri.hostname)
  
  # make sure we have a host header
  if not headers.hasKey("Host"):
    headers.add("Host", uri.hostname)

  # construct path
  var path = if uri.path == "": "/" else: uri.path
  path = if uri.query != "": path & "?" & uri.query else: path

  await socket.sendGreeting(httpMethod, path)
  await socket.sendHeaders(headers)
  await socket.sendBody(body)

  
  let greeting = await socket.recvGreeting()
  let headers = await socket.recvHeaders()

  result.httpCode = greeting.httpCode
  result.headers = headers
  result.socket = socket

proc mainAsync() {.async.} =
  var client: Async
  var response = await client.fetch(HttpGet, "http://info.cern.ch/hypertext/WWW/TheProject.html")
  for data in response.recvData():
    echo data

  let headers = newHttpHeaders({
    "user-agent": "nim-httpclient/0.1",
    "Accept": "*/*",
    "Host": "v1.41",
  })
  let path = Uri(scheme: "unix", hostname: "/var/run/docker.sock", path: "/v1.41/containers/json")
  response = await client.fetch(HttpGet, path, headers= headers)
  for data in response.recvData():
    echo data

when isMainModule:
  waitFor mainAsync()