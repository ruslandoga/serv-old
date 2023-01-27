defmodule Serv do
  @moduledoc "Basic HTTP/1.1 server"
  use GenServer
  require Logger
  require Serv.Acceptor
  alias Serv.Acceptor

  require Record
  Record.defrecordp(:state, [:socket, :acceptors, :timeouts, :plug])

  def start_link(opts) do
    {genserver_opts, opts} = Keyword.split(opts, [:name, :debug])
    GenServer.start_link(__MODULE__, opts, genserver_opts)
  end

  def acceptors(pid) do
    GenServer.call(pid, :acceptors)
  end

  def sockname(pid) do
    GenServer.call(pid, :sockname)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    plug = Keyword.fetch!(opts, :plug)
    validate_plug(plug)

    ip = Keyword.get(opts, :ip, {127, 0, 0, 1})
    port = Keyword.get(opts, :port, 0)
    min_acceptors = opts[:min_acceptors] || 100

    timeouts = opts[:timeouts] || []

    timeouts =
      Acceptor.timeouts(
        accept: timeouts[:accept] || :timer.seconds(10),
        request: timeouts[:request] || :timer.seconds(60),
        headers: timeouts[:headers] || :timer.seconds(10)
      )

    {:ok, socket} = :socket.open(:inet, :stream, :tcp)

    :ok = :socket.setopt(socket, {:socket, :reuseaddr}, true)
    :ok = :socket.setopt(socket, {:socket, :linger}, %{onoff: true, linger: 30})
    :ok = :socket.setopt(socket, {:tcp, :nodelay}, true)
    :ok = :socket.bind(socket, %{family: :inet, port: port, addr: ip})
    :ok = :socket.listen(socket, opts[:backlog] || 1024)

    acceptors = :ets.new(:acceptors, [:private, :set])
    state = state(socket: socket, acceptors: acceptors, timeouts: timeouts, plug: plug)

    for _ <- 1..min_acceptors do
      start_acceptor(state)
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:acceptors, _from, state(acceptors: acceptors) = state) do
    pids = Enum.map(:ets.tab2list(acceptors), &elem(&1, 0))
    {:reply, pids, state}
  end

  def handle_call(:sockname, _from, state(socket: socket) = state) do
    {:ok, sockname} = :socket.sockname(socket)
    {:reply, sockname, state}
  end

  @impl true
  def handle_cast(:accepted, state) do
    start_acceptor(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:EXIT, _pid, {:error, :emfile}}, state) do
    Logger.error("No more file descriptors, shutting down")
    {:stop, :emfile, state}
  end

  def handle_info({:EXIT, pid, :normal}, state) do
    remove_acceptor(state, pid)
    {:noreply, state}
  end

  def handle_info({:EXIT, pid, reason}, state) do
    Logger.error("Acceptor (pid #{inspect(pid)}) crashed:\n" <> Exception.format_exit(reason))
    remove_acceptor(state, pid)
    {:noreply, state}
  end

  defp remove_acceptor(state(acceptors: acceptors), pid) do
    :ets.delete(acceptors, pid)
  end

  defp start_acceptor(state) do
    state(socket: socket, acceptors: acceptors, timeouts: timeouts, plug: plug) = state
    pid = Acceptor.start_link(self(), socket, timeouts, plug)
    :ets.insert(acceptors, {pid})
  end

  defp validate_plug(plug) do
    unless is_atom(plug) and function_exported?(plug, :call, 2) do
      raise "#{plug} is not a valid Plug callback module as it doesn't define `call/2` function"
    end
  end
end
