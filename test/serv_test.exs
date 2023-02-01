defmodule ServTest do
  use Serv.ConnCase, async: true

  defmodule OkPlug do
    @behaviour Plug

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, _opts) do
      Plug.Conn.send_resp(conn, 200, "Ok.")
    end
  end

  describe "basic" do
    setup do
      {:ok, plug: OkPlug}
    end

    setup [:started, :connected]

    test "it works", %{conn: conn} do
      assert [200, headers | data] = request(conn, "GET", "/")

      assert headers == [
               {"content-length", "3"},
               {"cache-control", "max-age=0, private, must-revalidate"}
             ]

      assert IO.iodata_to_binary(data) == "Ok."
    end
  end
end
