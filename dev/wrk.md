```elixir
defmodule OkPlug do
  def init(opts), do: opts
  def call(conn, _opts) do
    Plug.Conn.send_resp(conn, 200, """
    <!DOCTYPE html>
    <html>
    <head>
    <title>Welcome to nginx!</title>
    <style>
    html { color-scheme: light dark; }
    body { width: 35em; margin: 0 auto;
    font-family: Tahoma, Verdana, Arial, sans-serif; }
    </style>
    </head>
    <body>
    <h1>Welcome to nginx!</h1>
    <p>If you see this page, the nginx web server is successfully installed and
    working. Further configuration is required.</p>

    <p>For online documentation and support please refer to
    <a href="http://nginx.org/">nginx.org</a>.<br/>
    Commercial support is available at
    <a href="http://nginx.com/">nginx.com</a>.</p>

    <p><em>Thank you for using nginx.</em></p>
    </body>
    </html>
    """)
  end
end
```

### Cowboy

```elixir
Mix.install [:plug_cowboy]
Plug.Cowboy.http(OkPlug, [], port: 8001)
```

```console
$ wrk -t64 -c128 -d10s http://localhost:8001
Running 10s test @ http://localhost:8001
  64 threads and 128 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency     2.09ms    5.82ms 124.79ms   96.58%
    Req/Sec     1.67k   245.96     2.87k    78.07%
  1069807 requests in 10.10s, 775.41MB read
Requests/sec: 105876.41
Transfer/sec:     76.74MB
```

### Bandit

```elixir
Mix.install [:bandit]
Bandit.start_link(plug: OkPlug, options: [port: 8002])
```

```console
$ wrk -t64 -c128 -d10s http://localhost:8002
Running 10s test @ http://localhost:8002
  64 threads and 128 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency     5.01ms   12.84ms 169.80ms   91.45%
    Req/Sec     1.97k   842.30     7.55k    74.69%
  1262405 requests in 10.10s, 0.87GB read
Requests/sec: 124936.14
Transfer/sec:     88.65MB
```

### Serv

```elixir
Mix.install [{:serv, github: "ruslandoga/serv"}]
Serv.start_link(plug: OkPlug, port: 8003)
```

```console
$ wrk -t64 -c128 -d10s http://localhost:8003
Running 10s test @ http://localhost:8003
  64 threads and 128 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency     3.60ms   10.83ms 130.39ms   93.54%
    Req/Sec     2.15k   819.54     7.87k    77.39%
  1382510 requests in 10.10s, 0.91GB read
Requests/sec: 136838.35
Transfer/sec:     92.26MB
```
