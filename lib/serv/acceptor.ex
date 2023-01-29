# TODO split into ranch/cowboy kind of setup
defmodule Serv.Acceptor do
  @moduledoc "Basic HTTP acceptor"

  require Logger
  require Serv.Adapter
  alias Serv.Adapter

  require Record
  Record.defrecord(:timeouts, [:accept, :request, :headers])

  def start_link(parent, listen_socket, timeouts, plug) do
    :proc_lib.spawn_link(__MODULE__, :accept, [parent, listen_socket, timeouts, plug])
  end

  @doc false
  def accept(parent, listen_socket, timeouts, plug) do
    # TODO try/do?
    case :socket.accept(listen_socket, timeouts(timeouts, :accept)) do
      {:ok, socket} ->
        GenServer.cast(parent, :accepted)
        __MODULE__.keepalive_loop(socket, <<>>, timeouts, plug)

      {:error, :timeout} ->
        __MODULE__.accept(parent, listen_socket, timeouts, plug)

      {:error, :econnaborted} ->
        __MODULE__.accept(parent, listen_socket, timeouts, plug)

      {:error, :closed} ->
        :ok

      {:error, _reason} = error ->
        exit(error)
    end
  end

  @doc false
  def keepalive_loop(socket, buffer, timeouts, plug) do
    case __MODULE__.handle_request(socket, buffer, timeouts, plug) do
      Adapter.req(connection: "close") -> :socket.close(socket)
      Adapter.req(buffer: buffer) -> __MODULE__.keepalive_loop(socket, buffer, timeouts, plug)
    end
  end

  @doc false
  def handle_request(socket, buffer, timeouts, plug) do
    timeouts(request: request_timeout, headers: headers_timeout) = timeouts

    {method, raw_path, version, buffer, req} = get_request(socket, buffer, request_timeout)
    {req_headers, buffer, host, req} = get_headers(socket, version, buffer, headers_timeout, req)
    conn = build_conn(socket, method, raw_path, req_headers, buffer, host, req)

    # TODO websock upgrade and stuff
    # TODO opts
    # TODO try/catch?
    %{adapter: {_, req}} = plug.call(conn, [])

    receive do
      {:plug_conn, :sent} -> :ok
    after
      0 -> :ok
    end

    req
  end

  defp get_request(socket, buffer, timeout) when byte_size(buffer) <= 1_000 do
    case :erlang.decode_packet(:http_bin, buffer, []) do
      {:more, _} ->
        case :socket.recv(socket, 0, timeout) do
          {:ok, data} ->
            get_request(socket, buffer <> data, timeout)

          {:error, _reason} ->
            :socket.close(socket)
            exit(:normal)
        end

      {:ok, {:http_request, method, raw_path, version}, buffer} ->
        {method, raw_path, version, buffer, Adapter.req(version: version)}

      {:ok, {:http_error, _}, _} ->
        send_bad_request(socket)
        :socket.close(socket)
        exit(:normal)

      {:ok, {:http_response, _, _, _}, _} ->
        :socket.close(socket)
        exit(:normal)
    end
  end

  defp get_request(socket, _buffer, _timeout) do
    send_bad_request(socket)
    :socket.close(socket)
    exit(:normal)
  end

  defp get_headers(socket, {1, _}, buffer, timeout, req) do
    get_headers(socket, buffer, [], 0, timeout, nil, req)
  end

  defp get_headers(_socket, {0, 9}, buffer, _timeout, req) do
    {[], buffer, req}
  end

  defp get_headers(socket, buffer, headers, count, timeout, host, req)
       when byte_size(buffer) <= 1_000 and count < 100 do
    case :erlang.decode_packet(:httph_bin, buffer, []) do
      {:ok, {:http_header, _, k, k_bin, v}, buffer} ->
        case k do
          :"Transfer-Encoding" ->
            v = String.downcase(v)
            req = Adapter.req(req, transfer_encoding: v)
            headers = [{"transfer-encoding", v} | headers]
            get_headers(socket, buffer, headers, count + 1, timeout, host, req)

          :Connection ->
            v = String.downcase(v)
            req = Adapter.req(req, connection: v)
            headers = [{"connection", v} | headers]
            get_headers(socket, buffer, headers, count + 1, timeout, host, req)

          :Host ->
            headers = [{"host", v} | headers]
            get_headers(socket, buffer, headers, count + 1, timeout, v, req)

          :"Content-Length" ->
            i = String.to_integer(v)
            req = Adapter.req(req, content_length: i)
            headers = [{"content-length", v} | headers]
            get_headers(socket, buffer, headers, count + 1, timeout, host, req)

          _ ->
            headers = [{header(k, k_bin), v} | headers]
            get_headers(socket, buffer, headers, count + 1, timeout, host, req)
        end

      {:ok, :http_eoh, buffer} ->
        {headers, buffer, host, req}

      {:ok, {:http_error, _}, buffer} ->
        get_headers(socket, buffer, headers, count, timeout, host, req)

      {:more, _} ->
        case :socket.recv(socket, timeout) do
          {:ok, data} ->
            get_headers(socket, buffer <> data, headers, count, timeout, host, req)

          {:error, _reason} ->
            :socket.close(socket)
            exit(:normal)
        end
    end
  end

  defp get_headers(socket, _buffer, _headers, _count, _timeout, _host, _req) do
    send_bad_request(socket)
    :socket.close(socket)
    exit(:normal)
  end

  defp build_conn(socket, method, raw_path, req_headers, buffer, host, req) do
    path =
      case raw_path do
        {:abs_path, path} ->
          path

        {:absoluteURI, _scheme, _host, _port, path} ->
          path

        _other ->
          send_bad_request(socket)
          exit(:normal)
      end

    # TODO optimise (with benches)
    {path, path_info, query_string} = split_path_qs(path)

    # TODO https://www.erlang.org/doc/man/inet.html#type-returned_non_ip_address
    {:ok, %{addr: remote_ip, port: port}} = :socket.peername(socket)
    req = Adapter.req(req, socket: socket, buffer: buffer, req_headers: req_headers)
    # [buffer | req] ???

    %Plug.Conn{
      adapter: {Adapter, req},
      host: host,
      port: port,
      remote_ip: remote_ip,
      query_string: query_string,
      req_headers: req_headers,
      request_path: path,
      scheme: :http,
      method: Atom.to_string(method),
      path_info: path_info,
      owner: self()
    }
  end

  defp send_bad_request(socket) do
    :socket.send(socket, "HTTP/1.1 400 Bad Request\r\ncontent-length: 11\r\n\r\nBad Request")
  end

  defp split_path_qs(path) do
    case :binary.split(path, "?") do
      [path] -> {path, split_path(path), ""}
      [path, query_string] -> {path, split_path(path), query_string}
    end
  end

  defp split_path(path) do
    path |> :binary.split("/", [:global]) |> clean_segments()
  end

  @compile inline: [clean_segments: 1]
  defp clean_segments(["" | rest]), do: clean_segments(rest)
  defp clean_segments([segment | rest]), do: [segment | clean_segments(rest)]
  defp clean_segments([] = done), do: done

  headers = [
    :"Cache-Control",
    # :Connection,
    :Date,
    :Pragma,
    # :"Transfer-Encoding",
    :Upgrade,
    :Via,
    :Accept,
    :"Accept-Charset",
    :"Accept-Encoding",
    :"Accept-Language",
    :Authorization,
    :From,
    # :Host,
    :"If-Modified-Since",
    :"If-Match",
    :"If-None-Match",
    :"If-Range",
    :"If-Unmodified-Since",
    :"Max-Forwards",
    :"Proxy-Authorization",
    :Range,
    :Referer,
    :"User-Agent",
    :Age,
    :Location,
    :"Proxy-Authenticate",
    :Public,
    :"Retry-After",
    :Server,
    :Vary,
    :Warning,
    :"Www-Authenticate",
    :Allow,
    :"Content-Base",
    :"Content-Encoding",
    :"Content-Language",
    # :"Content-Length",
    :"Content-Location",
    :"Content-Md5",
    :"Content-Range",
    :"Content-Type",
    :Etag,
    :Expires,
    :"Last-Modified",
    :"Accept-Ranges",
    :"Set-Cookie",
    :"Set-Cookie2",
    :"X-Forwarded-For",
    :Cookie,
    :"Keep-Alive",
    :"Proxy-Connection"
  ]

  for h <- headers do
    defp header(unquote(h), _), do: unquote(String.downcase(to_string(h)))
  end

  defp header(_, h), do: String.downcase(h)
end
