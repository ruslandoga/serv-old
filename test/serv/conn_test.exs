defmodule Serv.ConnTest do
  use Serv.ConnCase, async: true
  import ExUnit.CaptureLog

  alias Plug.Conn
  import Plug.Conn

  @already_sent {:plug_conn, :sent}

  def init(opts) do
    opts
  end

  def call(conn, []) do
    # Assert we never have a lingering @already_sent entry in the inbox
    refute_received @already_sent

    function = String.to_atom(List.first(conn.path_info) || "root")
    apply(__MODULE__, function, [conn])
  rescue
    exception ->
      receive do
        {:plug_conn, :sent} ->
          :erlang.raise(:error, exception, __STACKTRACE__)
      after
        0 ->
          send_resp(
            conn,
            500,
            Exception.message(exception) <>
              "\n" <>
              Exception.format_stacktrace(__STACKTRACE__)
          )
      end
  end

  def root(%Conn{} = conn) do
    assert conn.method == "HEAD"
    assert conn.path_info == []
    assert conn.query_string == "foo=bar&baz=bat"
    assert conn.request_path == "/"
    # resp(conn, 200, "ok")
    send_resp(conn, 200, "ok")
  end

  def build(%Conn{} = conn) do
    assert {Serv.Adapter, _} = conn.adapter
    assert conn.path_info == ["build", "foo", "bar"]
    assert conn.query_string == ""
    assert conn.scheme == :http
    # assert conn.host == "localhost"
    # assert conn.port == 8003
    assert conn.method == "GET"
    assert conn.remote_ip == {127, 0, 0, 1}
    assert get_http_protocol(conn) == :"HTTP/1.1"
    # resp(conn, 200, "ok")
    send_resp(conn, 200, "ok")
  end

  setup do
    {:ok, plug: __MODULE__}
  end

  setup [:started, :connected]

  test "builds a connection", %{conn: conn} do
    assert [200, _] = request(conn, "HEAD", "/?foo=bar&baz=bat")
    assert [200, _, _] = request(conn, "GET", "/build/foo/bar")
    assert [200, _, _] = request(conn, "GET", "//build//foo//bar")
  end

  def return_request_path(%Conn{} = conn) do
    # resp(conn, 200, conn.request_path)
    send_resp(conn, 200, conn.request_path)
  end

  test "request_path", %{conn: conn} do
    assert [200, _, "/return_request_path/foo"] =
             request(conn, "GET", "/return_request_path/foo?barbat")

    assert [200, _, "/return_request_path/foo/bar"] =
             request(conn, "GET", "/return_request_path/foo/bar?bar=bat")

    assert [200, _, "/return_request_path/foo/bar/"] =
             request(conn, "GET", "/return_request_path/foo/bar/?bar=bat")

    assert [200, _, "/return_request_path/foo//bar"] =
             request(conn, "GET", "/return_request_path/foo//bar")

    assert [200, _, "//return_request_path//foo//bar//"] =
             request(conn, "GET", "//return_request_path//foo//bar//")
  end

  def headers(conn) do
    assert get_req_header(conn, "foo") == ["bar"]
    assert get_req_header(conn, "baz") == ["bat"]
    # resp(conn, 200, "ok")
    send_resp(conn, 200, "ok")
  end

  test "stores request headers", %{conn: conn} do
    assert [200, _, _] = request(conn, "GET", "/headers", [{"foo", "bar"}, {"baz", "bat"}])
  end

  def telemetry(conn) do
    Process.sleep(30)
    send_resp(conn, 200, "TELEMETRY")
  end

  def telemetry_exception(conn) do
    # send first because of the `rescue` in `call`
    send_resp(conn, 200, "Fail")
    raise "BadTimes"
  end

  test "emits telemetry events for start/stop", %{conn: conn} do
    :telemetry.attach_many(
      :start_stop_test,
      [
        [:serv, :request, :start],
        [:serv, :request, :stop],
        [:serv, :request, :exception]
      ],
      fn event, measurements, metadata, test ->
        send(test, {:telemetry, event, measurements, metadata})
      end,
      self()
    )

    assert [200, _, "TELEMETRY"] = request(conn, "GET", "/telemetry?foo=bar")

    assert_receive {:telemetry, [:cowboy, :request, :start], %{system_time: _}, %{req: req}}

    assert req.path == "/telemetry"

    assert_receive {:telemetry, [:cowboy, :request, :stop], %{duration: duration}, %{req: ^req}}

    duration_ms = System.convert_time_unit(duration, :native, :millisecond)

    assert duration_ms >= 30
    assert duration_ms < 100

    refute_received {:telemetry, [:cowboy, :request, :exception], _, _}

    :telemetry.detach(:start_stop_test)
  end
end
