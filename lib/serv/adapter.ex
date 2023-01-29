defmodule Serv.Adapter do
  @moduledoc false
  @behaviour Plug.Conn.Adapter

  require Record
  # TODO remove :host
  Record.defrecord(:req, [
    :socket,
    :buffer,
    :transfer_encoding,
    :content_length,
    :connection,
    :version,
    :req_headers
  ])

  @impl true
  def send_resp(req, status, headers, body) do
    req(socket: socket) = req

    response = [
      http_line(status),
      encode_headers([ensure_content_length(headers, body) | headers]) | body
    ]

    :socket.send(socket, response)

    case List.keyfind(headers, "connection", 0) do
      {_, connection} -> {:ok, nil, req(req, connection: connection)}
      nil -> {:ok, nil, req}
    end
  end

  @impl true
  @dialyzer {:no_improper_lists, send_file: 6}
  def send_file(req, status, headers, file, offset, length) do
    req(socket: socket) = req
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

    case List.keyfind(headers, "connection", 0) do
      {_, connection} -> {:ok, nil, req(req, connection: connection)}
      nil -> {:ok, nil, req}
    end
  end

  @impl true
  @dialyzer {:no_improper_lists, send_chunked: 3}
  def send_chunked(req, status, headers) do
    req(socket: socket) = req
    response = [http_line(status) | encode_headers([{"transfer-encoding", "chunked"} | headers])]
    :socket.send(socket, response)

    case List.keyfind(headers, "connection", 0) do
      {_, connection} -> {:ok, nil, req(req, connection: connection)}
      nil -> {:ok, nil, req}
    end
  end

  @impl true
  @dialyzer {:no_improper_lists, chunk: 2}
  def chunk(req, body) do
    # TODO head? -> no response
    req(socket: socket) = req
    length = body |> IO.iodata_length() |> Integer.to_string(16)
    :socket.send(socket, [length, "\r\n", body | "\r\n"])
  end

  @impl true
  def read_req_body(req, opts) do
    req(
      socket: socket,
      buffer: buffer,
      content_length: content_length,
      transfer_encoding: transfer_encoding,
      req_headers: req_headers
    ) = req

    want_length = opts[:length] || 8_000_000
    read_length = opts[:read_length] || 1_000_000
    read_timeout = opts[:read_timeout] || 15_000

    # TODO use req.state, not buffer type (after the first read_req_body call buffer becomes a list)
    case buffer do
      bin when is_binary(bin) -> maybe_send_continue(socket, req_headers)
      _ -> :ok
    end

    case content_length do
      0 ->
        {:ok, <<>>, req}

      _ ->
        recv_result =
          case transfer_encoding do
            # TODO
            # "chunked" ->
            #   case unchunk(buffer) do
            #     {:ok, _data, _rest} = done ->
            #       done

            #     {:more, data, buffer} ->
            #       recv_chunked(
            #         socket,
            #         rest,
            #         byte_size(data),
            #         want_length,
            #         read_length,
            #         read_timeout,
            #         data
            #       )
            #   end

            nil ->
              recv_until(
                socket,
                buffer,
                byte_size(buffer),
                want_length,
                read_length,
                read_timeout
              )

            _other ->
              {:error, :unsupported_transfer_encoding}
          end

        case recv_result do
          {:ok, body, buffer} ->
            case content_length - want_length do
              left when left > 0 -> {:more, body, req(req, buffer: buffer, content_length: left)}
              0 -> {:ok, body, req(req, buffer: buffer, content_length: 0)}
            end

          {:error, {reason, _data}} ->
            {:error, reason}

          {:error, _reason} = error ->
            error
        end
    end
  end

  # def recv_chunked(socket, data, data_size, want_length, read_length, read_timeout) do
  #   case want_length - data_size do
  #     0 -> {:ok, IO.iodata_to_binary(data), []}
  #   end
  # end

  # chunk_headers = [
  #   {quote(do: <<size, "\r\n", chunk::size()-bytes, "\r\n">>)}
  # ]

  # defp unchunk(<<a, "\r\n", rest>>, size, acc) do
  #   case rest do
  #     <<chunk::size(size)-bytes, "\r\n"::bytes, rest::bytes>> ->
  #       unchunk(rest, 0, [acc | chunk])
  #   end
  # end

  # defp unchunk(<<h, rest>>, size, acc) do
  #   case h do
  #     h >= ?0 and h <= ?9 -> unchunk(rest, (size <<< 4) + h - ?0, acc)
  #     h >= ?A and h <= ?F -> unchunk(rest, (size <<< 4) + h - ?A + 0xA, acc)
  #     h >= ?a and h <= ?f -> unchunk(rest, (size <<< 4) + h - ?a + 0xA, acc)
  #   end
  # end

  @dialyzer {:no_improper_lists, recv_until: 6}
  defp recv_until(socket, buffer, buffer_size, want_length, read_length, read_timeout) do
    case want_length - buffer_size do
      0 ->
        {:ok, IO.iodata_to_binary(buffer), []}

      n when n > 0 and n <= read_length ->
        case :socket.recv(socket, n, read_timeout) do
          {:ok, data} -> {:ok, IO.iodata_to_binary([buffer | data]), []}
          {:error, _reason} = error -> error
        end

      n when n > 0 ->
        case :socket.recv(socket, read_length, read_timeout) do
          {:ok, data} ->
            recv_until(
              socket,
              [buffer | data],
              buffer_size + read_length,
              want_length,
              read_length,
              read_timeout
            )

          {:error, _reason} = error ->
            error
        end

      _ ->
        case buffer do
          <<body::size(want_length)-bytes, buffer::bytes>> -> {:ok, body, [buffer]}
          _ -> split_iolist(buffer, want_length)
        end
    end
  end

  @dialyzer {:no_improper_lists, split_iolist: 3}
  defp split_iolist([data | rest], want_length, acc \\ []) do
    byte_size = byte_size(data)

    case want_length - byte_size do
      0 ->
        {:ok, IO.iodata_to_binary([acc | data]), rest}

      n when n > 0 ->
        split_iolist(rest, n, [acc | data])

      _ ->
        <<d1::size(want_length)-bytes, d2::bytes>> = data
        {:ok, IO.iodata_to_binary([acc | d1]), [rest | d2]}
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
  def upgrade(req, :websocket, _opts) do
    req(socket: socket, req_headers: req_headers) = req

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
        {:ok, req}
      end
    else
      _ ->
        # TODO proper error
        {:error, :failed_websocket_upgrade}
    end
  end

  def upgrade(_state, _protocol, _opts) do
    {:error, :not_supported}
  end

  @impl true
  def get_peer_data(req(socket: socket)) do
    {:ok, {address, port}} = :inet.peername(socket)
    %{address: address, port: port, ssl_cert: nil}
  end

  @impl true
  def get_http_protocol(req(version: version)) do
    case version do
      {1, 1} -> :"HTTP/1.1"
      {1, 0} -> :"HTTP/1"
      {0, 9} -> :"HTTP/0.9"
    end
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
