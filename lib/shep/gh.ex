defmodule Shep.GH do
  @moduledoc """
  Thin seam over the `gh` CLI.

  Adapters shell out through `run/1` so tests can inject a scripted
  runner via `Application.put_env(:shep, :gh_runner, fun)` and assert
  on argument lists instead of network effects. The default runner
  preserves the previous inline behavior exactly: trimmed stdout on
  exit 0, trimmed combined output as the error otherwise.
  """

  @doc "Run `gh` with args via the configured runner (default: `System.cmd/3`)."
  @spec run([String.t()]) :: {:ok, String.t()} | {:error, String.t()}
  def run(args) when is_list(args) do
    runner = Application.get_env(:shep, :gh_runner, &gh_system/1)
    runner.(args)
  end

  defp gh_system(args) do
    case System.cmd("gh", args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, _} -> {:error, String.trim(output)}
    end
  end
end
