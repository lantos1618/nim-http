import
    httpcore,
    net,
    streams,
    uri,
    strutils


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

    Response* = object
        httpCode: HttpCode
        headers: HttpHeaders
        stream: Stream
        socket: Socket
    Chunk = object
        size: int
        ext: HttpHeaders
        data: string

    HttpError = object of IOError

    

proc initSocket(uri: Uri): Socket =
    var uri = uri
    var port = if uri.port != "": Port(uri.port.parseInt()) 
        elif uri.scheme == "https": Port(443)
        else: Port(80)
    return net.dial(uri.hostname, port)


proc sendGreeting(socket: Socket, httpMethod: HttpMethod, path: string): void =
    let message = $httpMethod & " " & path & " HTTP/1.1\r\n"
    when defined(verbose): echo "> ", message
    socket.send(message)

proc sendHeaders(socket: Socket, headers: HttpHeaders): void =
    for key, value in headers:
        socket.send(key & ": " & value & "\r\n")
    socket.send("\r\n")

proc sendBody(socket: Socket, body: string): void =
    socket.send(body)

proc recvGreeting(socket: Socket): Greeting =
    var line = socket.recvLine()
    var parts = line.split(" ")
    if not parts.len >= 3:
        raise newException(HttpError, "Invalid greeting: " & line)

    if parts[0] != "HTTP/1.1":
        raise newException(HttpError, "Invalid greeting: " & line)
    
    result.httpVersion = HttpVer11
    result.httpCode = HttpCode(parts[1].parseInt())
    result.ok = result.httpCode == Http200
    result.message = parts[2..parts.high].join(" ")

proc recvHeaders(socket: Socket): HttpHeaders =
    while true:
        var line = socket.recvLine()
        if line == "\r\n":
            break
        var posSplit = line.find(":")
        if posSplit < 0:
            raise newException(HttpError, "Invalid header: " & line)
        result.add(line[0..posSplit].strip(), line[posSplit..line.high].strip())

proc recvChunk*(socket: Socket): Chunk =
    let chunkHeader = socket.recvLine()
    let chunkHeaderSpacePos = chunkHeader.find(' ')

    if chunkHeaderSpacePos == -1:
        result.size = fromHex[int](chunkHeader)
    else:
        result.size = fromHex[int](chunkHeader[0..chunkHeaderSpacePos])
        let chunkExtention = chunkHeader[chunkHeaderSpacePos..chunkHeader.high]
        raise newException(HttpError, "chunk extention not supported: " & chunkExtention)
    
    # pass the data of expected size
    result.data = socket.recv(result.size)
    when defined(verbose):
        echo "r< ", cast[seq[char]](result.data)

    # then receve the trailing \r\n
    let expectedNewLine = socket.recvLine()
    if expectedNewLine != "\r\n":
        raise newException(HttpError, "expected \\r\\n but got: " & expectedNewLine)

iterator recvData*(response: Response): string =
    ## iterator over the data of the response
    ## if you want to work with streams use recvStream instead which implements this iterator
    var chunked = response.headers.getOrDefault("Transfer-Encoding").contains("chunked")
    var contentLength = if response.headers.hasKey("Content-Length"): response.headers["Content-Length"].parseInt() else: -1
    if chunked:
        var chunk = response.socket.recvChunk()
        while chunk.size > 0 and chunk.data != "\r\n":
            chunk = response.socket.recvChunk()
            yield chunk.data
    elif  contentLength > 0: 
        let line = response.socket.recv(contentLength)
        yield line
    else:
        while true:
            let line = response.socket.recvLine()
            if line.len == 0 or line == "\r\n":
                break
            yield line

proc recvStream*(response: Response): void =
    ## use this to return a stream of data
    ## this will block until finished if using in a sync context
    ## use recvData if you want to do something with the data as it comes in
    defer: response.stream.close()
    for data in response.recvData():
        response.stream.write(data)
  

proc fetch*(
        client: Sync | Async,
        httpMethod: HttpMethod,
        uri: Uri | string,
        body: string = "",
        # multiPart: MultiPart
        headers: HttpHeaders = newHttpHeaders(),
        sslContext: SslContext = nil
    ): Response =
    # set up the uri
    when uri is string:
        var uri = parseUri(uri)
    else:
        var uri = uri
    # set up the socket
    var socket = initSocket(uri)
    when defined(ssl):
        wrapConnectedSocket(client.sslContext, socket, handshakeAsClient, uri.hostname)
    
    # make sure we have a host header
    if not headers.hasKey("Host"):
        headers.add("Host", uri.hostname)
    echo uri
    socket.sendGreeting(httpMethod, uri.path & uri.query)
    socket.sendHeaders(headers)
    socket.sendBody(body)
    let greeting = socket.recvGreeting()
    let headers = socket.recvHeaders()

    result.httpCode = greeting.httpCode
    result.headers = headers

when isMainModule:
    var client: Sync
    var response = client.fetch(HttpGet, "http://www.google.com")

    for data in response.recvData():
        echo data