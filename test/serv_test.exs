defmodule ServTest do
  use ExUnit.Case

  defmodule OkPlug do
    @behaviour Plug

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, _opts) do
      Plug.Conn.send_resp(conn, 200, "Ok.")
    end
  end

  test "it works" do
    serv = start_supervised!({Serv, plug: OkPlug})
    %{addr: addr, port: port} = Serv.sockname(serv)

    {:ok, conn} = Mint.HTTP.connect(:http, addr, port, mode: :passive, hostname: "localhost")
    {:ok, conn, _ref} = Mint.HTTP.request(conn, "GET", "/", [], "")

    assert [200, headers | data] = recv(conn)

    assert headers == [
             {"content-length", "3"},
             {"cache-control", "max-age=0, private, must-revalidate"}
           ]

    assert IO.iodata_to_binary(data) == "Ok."
  end

  defp recv(conn, acc \\ []) do
    with {:ok, conn, messages} <- Mint.HTTP.recv(conn, 0, :infinity) do
      case handle_messages(messages, []) do
        {:ok, messages} -> acc ++ messages
        {:more, messages} -> recv(conn, acc ++ messages)
      end
    end
  end

  defp handle_messages([{k, _ref, v} | rest], acc) when k in [:status, :headers, :data] do
    handle_messages(rest, [v | acc])
  end

  defp handle_messages([{:done, _ref}], acc) do
    {:ok, :lists.reverse(acc)}
  end
end
