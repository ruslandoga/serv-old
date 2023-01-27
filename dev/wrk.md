### Cowboy

```elixir
Mix.install [:plug_cowboy]

defmodule OkPlug do
  def init(opts), do: opts
  def call(conn, _opts), do: Plug.Conn.send_resp(conn, 200, "Ok.")
end

Plug.Cowboy.http(OkPlug, [], port: 8001)
```

```console
$ wrk -t64 -c128 -d10s http://localhost:8001
Running 10s test @ http://localhost:8001
  64 threads and 128 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency     1.89ms    4.97ms 126.43ms   97.11%
    Req/Sec     1.66k   229.15     2.99k    76.19%
  1064602 requests in 10.10s, 148.25MB read
Requests/sec: 105355.41
Transfer/sec:     14.67MB
```

### Bandit

```elixir
Mix.install [:bandit]

defmodule OkPlug do
  def init(opts), do: opts
  def call(conn, _opts), do: Plug.Conn.send_resp(conn, 200, "Ok.")
end

Bandit.start_link(plug: OkPlug, options: [port: 8002])
```

```console
$ wrk -t64 -c128 -d10s http://localhost:8002
Running 10s test @ http://localhost:8002
  64 threads and 128 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency     4.71ms   12.94ms 165.50ms   92.66%
    Req/Sec     1.92k   789.88     6.51k    75.16%
  1228227 requests in 10.10s, 152.27MB read
Requests/sec: 121552.22
Transfer/sec:     15.07MB
```

### Serv

```elixir
Mix.install [{:serv, github: "ruslandoga/serv"}]

defmodule OkPlug do
  def init(opts), do: opts
  def call(conn, _opts), do: Plug.Conn.send_resp(conn, 200, "Ok.")
end

Serv.start_link(plug: OkPlug, port: 8003)
```

```console
$ wrk -t64 -c128 -d10s http://localhost:8003
Running 10s test @ http://localhost:8003
  64 threads and 128 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency    13.22ms   30.32ms 250.54ms   87.77%
    Req/Sec     2.19k     1.52k   28.11k    79.57%
  1385295 requests in 10.10s, 154.57MB read
Requests/sec: 137149.37
Transfer/sec:     15.30MB
```
