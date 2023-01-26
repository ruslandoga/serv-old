defmodule Bench do
  require Record
  Record.defrecord(:state, [:a, :b, :c])

  def tuples(state, n) when n < 1000 do
    state(a: a, b: b, c: c) = state
    tuples(state(a: a + 1, b: b + 1, c: c + 1), n + 1)
  end

  def tuples(state, _n), do: state

  def stack(a, b, c, n) when n < 1000 do
    stack(a + 1, b + 1, c + 1, n + 1)
  end

  def stack(a, b, c, _n), do: {a, b, c}

  def maps(state, n) when n < 1000 do
    %{a: a, b: b, c: c} = state
    maps(%{state | a: a + 1, b: b + 1, c: c + 1}, n + 1)
  end

  def maps(state, _n), do: state

  def cells(state, n) when n < 1000 do
    [a | b] = state
    cells([a + 1 | b + 1], n + 1)
  end

  def cells(state, _), do: state
end

Benchee.run(
  %{
    "tuples" => fn -> Bench.tuples({:state, 0, 0, 0}, 0) end,
    "maps" => fn -> Bench.maps(%{a: 0, b: 0, c: 0}, 0) end,
    "stack" => fn -> Bench.stack(0, 0, 0, 0) end,
    "cells" => fn -> Bench.cells([0 | 0], 0) end
  },
  memory_time: 2
)
