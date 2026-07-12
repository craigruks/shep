defmodule Shep.CIWatch do
  @moduledoc """
  Behaviour boundary for watching CI on a PR.

  The default adapter, `Shep.CIWatch.GitHub`, polls `gh pr checks`
  until the run resolves. Tests inject a scripted adapter via the
  `:ci_watch_adapter` app env, following the `Shep.Tracker` pattern.
  """

  @doc "Watch a PR until CI passes or retries are exhausted. Returns final status."
  @callback watch(repo :: String.t(), pr_number :: String.t(), opts :: keyword()) ::
              :passed | {:failed, String.t()}

  @doc "Collect failing-check logs for a PR, tail-capped, for a fix turn."
  @callback failure_logs(repo :: String.t(), pr_number :: String.t()) :: String.t()

  @doc "The configured CI watch adapter module."
  @spec adapter() :: module()
  def adapter do
    Application.get_env(:shep, :ci_watch_adapter, Shep.CIWatch.GitHub)
  end

  @doc "Watch a PR until CI passes or retries are exhausted. Returns final status."
  @spec watch(String.t(), String.t(), keyword()) :: :passed | {:failed, String.t()}
  def watch(repo, pr_number, opts \\ []), do: adapter().watch(repo, pr_number, opts)

  @doc "Collect failing-check logs for a PR, tail-capped, for a fix turn."
  @spec failure_logs(String.t(), String.t()) :: String.t()
  def failure_logs(repo, pr_number), do: adapter().failure_logs(repo, pr_number)
end
