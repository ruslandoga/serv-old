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
    response = [http_line(status), encode_headers(headers) | body]

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
    response = [http_line(status) | encode_headers(headers)]

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
    response = [http_line(status) | encode_headers(headers)]

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

      response = [http_line(101) | encode_headers(headers)]

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
      nil -> {[], false}
      {_, connection} = h -> {h, String.downcase(connection) == "close"}
    end
  end

  defp connection({1, 0}, req_headers) do
    case List.keyfind(req_headers, "connection", 0) do
      nil -> {[], true}
      {_, connection} = h -> {h, String.downcase(connection) == "close"}
    end
  end

  defp connection({0, 9}, _req_headers) do
    {[], true}
  end

  defp ensure_content_length(headers, body) do
    case List.keyfind(headers, "content-length", 0) do
      nil -> {"content-length", IO.iodata_length(body)}
      {_, _} -> []
    end
  end

  @dialyzer {:no_improper_lists, encode_headers: 1}
  defp encode_headers([{k, v} | rest]) do
    [encode_value(k), ": ", encode_value(v), "\r\n" | encode_headers(rest)]
  end

  defp encode_headers([[] | rest]), do: encode_headers(rest)
  defp encode_headers([]), do: "\r\n"

  defp encode_value(i) when is_integer(i), do: Integer.to_string(i)
  defp encode_value(b) when is_binary(b), do: b
  defp encode_value(l) when is_list(l), do: List.to_string(l)

  statuses = [
    {200, "200 OK"},
    {404, "404 Not Found"},
    {500, "500 Internal Server Error"},
    {400, "400 Bad Request"},
    {401, "401 Unauthorized"},
    {403, "403 Forbidden"},
    {429, "429 Too Many Requests"},
    {201, "201 Created"},
    # ----------------------------------------
    {100, "100 Continue"},
    {101, "101 Switching Protocols"},
    {102, "102 Processing"},
    {202, "202 Accepted"},
    {203, "203 Non-Authoritative Information"},
    {204, "204 No Content"},
    {205, "205 Reset Content"},
    {206, "206 Partial Content"},
    {207, "207 Multi-Status"},
    {226, "226 IM Used"},
    {300, "300 Multiple Choices"},
    {301, "301 Moved Permanently"},
    {302, "302 Found"},
    {303, "303 See Other"},
    {304, "304 Not Modified"},
    {305, "305 Use Proxy"},
    {306, "306 Switch Proxy"},
    {307, "307 Temporary Redirect"},
    {402, "402 Payment Required"},
    {405, "405 Method Not Allowed"},
    {406, "406 Not Acceptable"},
    {407, "407 Proxy Authentication Required"},
    {408, "408 Request Timeout"},
    {409, "409 Conflict"},
    {410, "410 Gone"},
    {411, "411 Length Required"},
    {412, "412 Precondition Failed"},
    {413, "413 Request Entity Too Large"},
    {414, "414 Request-URI Too Long"},
    {415, "415 Unsupported Media Type"},
    {416, "416 Requested Range Not Satisfiable"},
    {417, "417 Expectation Failed"},
    {418, "418 I'm a teapot"},
    {422, "422 Unprocessable Entity"},
    {423, "423 Locked"},
    {424, "424 Failed Dependency"},
    {425, "425 Unordered Collection"},
    {426, "426 Upgrade Required"},
    {428, "428 Precondition Required"},
    {431, "431 Request Header Fields Too Large"},
    {501, "501 Not Implemented"},
    {502, "502 Bad Gateway"},
    {503, "503 Service Unavailable"},
    {504, "504 Gateway Timeout"},
    {505, "505 HTTP Version Not Supported"},
    {506, "506 Variant Also Negotiates"},
    {507, "507 Insufficient Storage"},
    {510, "510 Not Extended"},
    {511, "511 Network Authentication Required"}
  ]

  for {code, status} <- statuses do
    def status(unquote(code)), do: unquote(status)
    defp http_line(unquote(code)), do: unquote("HTTP/1.1 " <> status <> "\r\n")
  end

  defp maybe_send_continue(socket, req_headers) do
    with {_, "100-continue"} <- List.keyfind(req_headers, "expect", 0) do
      :socket.send(socket, "HTTP/1.1 100 Continue\r\ncontent-length: 0\r\n\r\n")
    end
  end
end
