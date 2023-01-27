defmodule Bench do
  def naive(path) do
    %{path: path} = parsed = :uri_string.parse(path)
    segments = :binary.split(path, "/", [:global])
    path_info = for segment <- segments, segment != "", do: segment
    {path, path_info, parsed[:query] || ""}
  end

  def elli(path) do
    case :binary.split(path, "?") do
      [path] -> {path, split_path(path), ""}
      [path, query_string] -> {path, split_path(path), query_string}
    end
  end

  defp split_path(path) do
    path |> :binary.split("/", [:global]) |> clean_segments()
  end

  defp clean_segments(["" | rest]), do: clean_segments(rest)
  defp clean_segments([segment | rest]), do: [segment | clean_segments(rest)]
  defp clean_segments([] = done), do: done
end

Benchee.run(
  %{
    "naive" => fn path -> Bench.naive(path) end,
    "elli" => fn path -> Bench.elli(path) end
  },
  memory_time: 2,
  inputs: %{
    "small" => "/api/echo?query=search"
  }
)
