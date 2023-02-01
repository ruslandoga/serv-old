defmodule Serv.ConnCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      import Plug.Conn
      import Serv.ConnCase
    end
  end

  def connect(port, opts \\ []) do
    addr = opts[:addr] || {127, 0, 0, 1}
    hostname = opts[:hostname] || "localhost"
    Mint.HTTP.connect(:http, addr, port, mode: :passive, hostname: hostname)
  end

  def request(conn, verb, path, headers \\ [], body \\ "") do
    {:ok, conn, _ref} = Mint.HTTP.request(conn, verb, path, headers, body)
    recv(conn)
  end

  def recv(conn, acc \\ []) do
    with {:ok, conn, messages} <- Mint.HTTP.recv(conn, 0, :infinity) do
      case handle_messages(messages, []) do
        {:ok, messages} -> acc ++ messages
        {:more, messages} -> recv(conn, acc ++ messages)
      end
    end
  end

  def handle_messages([{k, _ref, v} | rest], acc) when k in [:status, :headers, :data] do
    handle_messages(rest, [v | acc])
  end

  def handle_messages([{:done, _ref}], acc) do
    {:ok, :lists.reverse(acc)}
  end

  def handle_messages([], acc) do
    {:more, acc}
  end

  def started(ctx) do
    plug = ctx[:plug] || raise "missing :plug"
    {:ok, serv: start_supervised!({Serv, plug: plug})}
  end

  def connected(%{serv: serv}) do
    %{port: port} = Serv.sockname(serv)
    {:ok, conn} = connect(port)
    {:ok, conn: conn}
  end
end
