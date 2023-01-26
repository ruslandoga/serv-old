defmodule Serv.Adapter do
  @moduledoc false
  @behaviour Plug.Conn.Adapter

  require Record
  Record.defrecord(:state, [:socket, :version, :req_headers, :buffer, :close?])

  @impl true
  def send_resp(state, status, headers, body) do
    state(socket: socket, version: version, req_headers: req_headers) = state

    {connection, close?} = ensure_connection(version, headers, req_headers)
    headers = [connection, ensure_content_length(headers, body) | headers]
    response = ["HTTP/1.1 ", status(status), "\r\n", encode_headers(headers), "\r\n" | body]

    # TODO telemetry
    :socket.send(socket, response)
    state = state(state, close?: close?)
    {:ok, nil, state}
  end

  @impl true
  @dialyzer {:no_improper_lists, send_file: 6}
  def send_file(state, status, headers, file, offset, length) do
    state(socket: socket, version: version, req_headers: req_headers) = state

    {connection, close?} = ensure_connection(version, headers, req_headers)
    headers = [connection | headers]
    response = ["HTTP/1.1 ", status(status), "\r\n", encode_headers(headers) | "\r\n"]

    with {:ok, fd} <- :file.open(file, [:read, :raw, :binary]) do
      try do
        with :ok <- :socket.send(socket, response) do
          # TODO length = :all
          :socket.sendfile(socket, fd, offset, length)
        end
      after
        :file.close(fd)
      end
    end

    state = state(state, close?: close?)
    {:ok, nil, state}
  end

  @impl true
  @dialyzer {:no_improper_lists, send_chunked: 3}
  def send_chunked(state, status, headers) do
    state(socket: socket, version: version, req_headers: req_headers) = state

    {connection, _close?} = ensure_connection(version, headers, req_headers)
    headers = [{"transfer-encoding", "chunked"}, connection | headers]
    response = ["HTTP/1.1 ", status(status), "\r\n", encode_headers(headers) | "\r\n"]

    :socket.send(socket, response)

    # TODO
    state = state(state, close?: false)
    {:ok, nil, state}
  end

  @impl true
  @dialyzer {:no_improper_lists, chunk: 2}
  def chunk(state, body) do
    # TODO head? -> no response
    state(socket: socket) = state
    length = IO.iodata_length(body)
    :socket.send(socket, [Integer.to_string(length, 16), "\r\n", body | "\r\n"])
  end

  # TODO stream
  @impl true
  def read_req_body(state, opts) do
    state(socket: socket, req_headers: req_headers, buffer: buffer) = state

    case List.keyfind(req_headers, "content-length", 0) do
      nil ->
        case List.keyfind(req_headers, "transfer-encoding", 0) do
          nil ->
            {:ok, <<>>, state}

          {_, encoding} ->
            case String.downcase(encoding) do
              # TODO
              "chunked" -> {:error, "chunked requests are not supported"}
              other -> {:error, "unsupported transfer-encoding method: #{other}"}
            end
        end

      {_, content_length} ->
        content_length = String.to_integer(content_length)
        maybe_send_continue(socket, req_headers)

        case content_length - byte_size(buffer) do
          0 ->
            {:ok, buffer, state(state, buffer: <<>>)}

          n when n > 0 ->
            timeout = Keyword.get(opts, :read_timeout, :timer.seconds(15))

            case :socket.recv(socket, n, timeout) do
              {:ok, data} -> {:ok, buffer <> data, state(state, buffer: <<>>)}
              {:error, _reason} = error -> error
            end

          _ ->
            <<body::size(content_length)-bytes, rest::bytes>> = buffer
            {:ok, body, state(state, buffer: rest)}
        end
    end
  end

  @impl true
  def push(_state, _path, _headers) do
    {:error, :not_supported}
  end

  @impl true
  def inform(_state, _status, _headers) do
    {:error, :not_supported}
  end

  @impl true
  @dialyzer {:no_improper_lists, upgrade: 3}
  def upgrade(state, :websocket, _opts) do
    state(socket: socket, req_headers: req_headers) = state

    with {_, version} <- List.keyfind(req_headers, "sec-websocket-version", 0),
         version = String.to_integer(version),
         true <- version in [7, 8, 13],
         {_, key} <- List.keyfind(req_headers, "sec-websocket-key", 0) do
      challenge = Base.encode64(:crypto.hash(:sha, [key, "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"]))

      headers = [
        {"connection", "upgrade"},
        {"upgrade", "websocket"},
        {"sec-websocket-accept", challenge}
      ]

      response = ["HTTP/1.1 ", status(101), "\r\n", encode_headers(headers) | "\r\n"]

      with :ok <- :socket.send(socket, response) do
        {:ok, state}
      end
    else
      _ ->
        {:error, :not_supported}
    end
  end

  def upgrade(_state, _protocol, _opts) do
    {:error, :not_supported}
  end

  @impl true
  def get_peer_data(state(socket: socket)) do
    {:ok, {address, port}} = :inet.peername(socket)
    %{address: address, port: port, ssl_cert: nil}
  end

  @impl true
  def get_http_protocol(state(version: version)) do
    case version do
      {1, 1} -> :"HTTP/1.1"
      {1, 0} -> :"HTTP/1"
      {0, 9} -> :"HTTP/0.9"
    end
  end

  defp ensure_connection(version, resp_headers, req_headers) do
    case List.keyfind(resp_headers, "connection", 0) do
      nil -> connection(version, req_headers)
      {_, connection} -> {[], String.downcase(connection) == "close"}
    end
  end

  defp connection({1, 1}, req_headers) do
    case List.keyfind(req_headers, "connection", 0) do
      nil -> {{"connection", "keep-alive"}, false}
      {_, connection} = h -> {h, String.downcase(connection) == "close"}
    end
  end

  defp connection({1, 0}, req_headers) do
    case List.keyfind(req_headers, "connection", 0) do
      nil -> "close"
      {_, connection} = h -> {h, String.downcase(connection) == "close"}
    end
  end

  defp connection({0, 9}, _req_headers) do
    {{"connection", "close"}, true}
  end

  defp ensure_content_length(headers, body) do
    case List.keyfind(headers, "content-length", 0) do
      nil -> {"content-length", IO.iodata_length(body)}
      {_, _} -> []
    end
  end

  defp encode_headers([{k, v} | rest]) do
    [encode_value(k), ": ", encode_value(v), "\r\n" | encode_headers(rest)]
  end

  defp encode_headers([[] | rest]), do: encode_headers(rest)
  defp encode_headers([] = done), do: done

  defp encode_value(i) when is_integer(i), do: Integer.to_string(i)
  defp encode_value(b) when is_binary(b), do: b
  defp encode_value(l) when is_list(l), do: List.to_string(l)

  defp status(100), do: "100 Continue"
  defp status(101), do: "101 Switching Protocols"
  defp status(102), do: "102 Processing"
  defp status(200), do: "200 OK"
  defp status(201), do: "201 Created"
  defp status(202), do: "202 Accepted"
  defp status(203), do: "203 Non-Authoritative Information"
  defp status(204), do: "204 No Content"
  defp status(205), do: "205 Reset Content"
  defp status(206), do: "206 Partial Content"
  defp status(207), do: "207 Multi-Status"
  defp status(226), do: "226 IM Used"
  defp status(300), do: "300 Multiple Choices"
  defp status(301), do: "301 Moved Permanently"
  defp status(302), do: "302 Found"
  defp status(303), do: "303 See Other"
  defp status(304), do: "304 Not Modified"
  defp status(305), do: "305 Use Proxy"
  defp status(306), do: "306 Switch Proxy"
  defp status(307), do: "307 Temporary Redirect"
  defp status(400), do: "400 Bad Request"
  defp status(401), do: "401 Unauthorized"
  defp status(402), do: "402 Payment Required"
  defp status(403), do: "403 Forbidden"
  defp status(404), do: "404 Not Found"
  defp status(405), do: "405 Method Not Allowed"
  defp status(406), do: "406 Not Acceptable"
  defp status(407), do: "407 Proxy Authentication Required"
  defp status(408), do: "408 Request Timeout"
  defp status(409), do: "409 Conflict"
  defp status(410), do: "410 Gone"
  defp status(411), do: "411 Length Required"
  defp status(412), do: "412 Precondition Failed"
  defp status(413), do: "413 Request Entity Too Large"
  defp status(414), do: "414 Request-URI Too Long"
  defp status(415), do: "415 Unsupported Media Type"
  defp status(416), do: "416 Requested Range Not Satisfiable"
  defp status(417), do: "417 Expectation Failed"
  defp status(418), do: "418 I'm a teapot"
  defp status(422), do: "422 Unprocessable Entity"
  defp status(423), do: "423 Locked"
  defp status(424), do: "424 Failed Dependency"
  defp status(425), do: "425 Unordered Collection"
  defp status(426), do: "426 Upgrade Required"
  defp status(428), do: "428 Precondition Required"
  defp status(429), do: "429 Too Many Requests"
  defp status(431), do: "431 Request Header Fields Too Large"
  defp status(500), do: "500 Internal Server Error"
  defp status(501), do: "501 Not Implemented"
  defp status(502), do: "502 Bad Gateway"
  defp status(503), do: "503 Service Unavailable"
  defp status(504), do: "504 Gateway Timeout"
  defp status(505), do: "505 HTTP Version Not Supported"
  defp status(506), do: "506 Variant Also Negotiates"
  defp status(507), do: "507 Insufficient Storage"
  defp status(510), do: "510 Not Extended"
  defp status(511), do: "511 Network Authentication Required"
  defp status(b) when is_binary(b), do: b

  defp maybe_send_continue(socket, req_headers) do
    with {_, "100-continue"} <- List.keyfind(req_headers, "expect", 0) do
      :socket.send(socket, "HTTP/1.1 100 Continue\r\ncontent-length: 0\r\n\r\n")
    end
  end
end
