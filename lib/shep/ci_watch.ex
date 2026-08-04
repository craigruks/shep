defmodule Shep.CIWatch do
  @moduledoc """
  Behaviour boundary for watching CI on a PR.

  The default adapter, `Shep.CIWatch.GitHub`, polls `gh pr checks`
  until the run resolves. Tests inject a scripted adapter via the
  `:ci_watch_adapter` app env, following the `Shep.Tracker` pattern.

  A watch settles four ways, because "nothing is failing" is not the
  same claim as "something passed": `:passed` needs a real check
  verdict, `{:conflict, _}` is a PR GitHub refuses to merge (and for
  which it therefore creates no check suites at all), and
  `{:unverified, _}` is a PR on which nothing ever ran.
  """

  @typedoc """
  How a watch settled.

  * `:passed` — at least one real check reported and none failed.
  * `{:failed, check}` — a check reported failure.
  * `{:conflict, detail}` — the PR conflicts with its base; an agent
    can fix it by merging the base branch and re-pushing.
  * `{:unverified, reason}` — no check ever produced a verdict, so
    nothing about this PR has been verified.
  """
  @type verdict ::
          :passed
          | {:failed, String.t()}
          | {:conflict, String.t()}
          | {:unverified, String.t()}

  @doc "Watch a PR until CI settles or retries are exhausted. Returns the final verdict."
  @callback watch(repo :: String.t(), pr_number :: String.t(), opts :: keyword()) :: verdict()

  @doc "Collect failing-check logs for a PR, tail-capped, for a fix turn."
  @callback failure_logs(repo :: String.t(), pr_number :: String.t()) :: String.t()

  @doc "The configured CI watch adapter module."
  @spec adapter() :: module()
  def adapter do
    Application.get_env(:shep, :ci_watch_adapter, Shep.CIWatch.GitHub)
  end

  @doc "Watch a PR until CI settles or retries are exhausted. Returns the final verdict."
  @spec watch(String.t(), String.t(), keyword()) :: verdict()
  def watch(repo, pr_number, opts \\ []), do: adapter().watch(repo, pr_number, opts)

  @doc "Collect failing-check logs for a PR, tail-capped, for a fix turn."
  @spec failure_logs(String.t(), String.t()) :: String.t()
  def failure_logs(repo, pr_number), do: adapter().failure_logs(repo, pr_number)
end
