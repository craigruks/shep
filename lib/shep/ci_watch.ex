defmodule Shep.CIWatch do
  @moduledoc "Watches CI status on a PR, retries agent on failure (up to 3 attempts)."

  require Logger

  @max_ci_retries 3
  @poll_interval_ms 30_000
  @max_poll_errors 5

  @doc "Watch a PR until CI passes or retries are exhausted. Returns final status."
  @spec watch(String.t(), String.t(), keyword()) :: :passed | {:failed, String.t()}
  def watch(repo, pr_number, opts \\ []) do
    max_retries = Keyword.get(opts, :max_retries, @max_ci_retries)
    do_watch(repo, pr_number, 0, max_retries, nil, 0)
  end

  defp do_watch(_repo, _pr, attempt, max, last_failure, _poll_errors) when attempt >= max do
    Logger.error("CI retries exhausted (#{max} attempts)")
    {:failed, last_failure || "ci-loop-exhausted"}
  end

  defp do_watch(repo, pr_number, attempt, max, _last_failure, poll_errors) do
    Logger.info("Watching CI for PR ##{pr_number} (attempt #{attempt + 1}/#{max})")

    case poll_checks(repo, pr_number) do
      :passed ->
        Logger.info("CI passed for PR ##{pr_number}")
        :passed

      {:failed, reason} ->
        Logger.warning("CI failed for PR ##{pr_number}: #{reason}")
        do_watch(repo, pr_number, attempt + 1, max, reason, 0)

      {:error, reason} ->
        new_errors = poll_errors + 1

        if new_errors >= @max_poll_errors do
          Logger.error("CI poll errors exhausted (#{new_errors} consecutive failures)")
          {:failed, "poll-error: #{reason}"}
        else
          Logger.warning("CI poll error #{new_errors}/#{@max_poll_errors}: #{reason}")
          Process.sleep(@poll_interval_ms)
          do_watch(repo, pr_number, attempt, max, nil, new_errors)
        end

      :pending ->
        Process.sleep(@poll_interval_ms)
        do_watch(repo, pr_number, attempt, max, nil, 0)
    end
  end

  @doc "Check current CI status for a PR."
  @spec poll_checks(String.t(), String.t()) ::
          :passed | :pending | {:failed, String.t()} | {:error, String.t()}
  def poll_checks(repo, pr_number) do
    case gh(["pr", "checks", pr_number, "--repo", repo, "--json", "name,state,bucket"]) do
      {:ok, json} ->
        checks = Jason.decode!(json)
        evaluate_checks(checks)

      {:error, reason} ->
        Logger.warning("Failed to fetch PR checks: #{reason}")
        {:error, reason}
    end
  end

  defp evaluate_checks([]), do: :pending

  defp evaluate_checks(checks) do
    states = Enum.map(checks, &normalize_check/1)

    cond do
      Enum.any?(states, &(&1 == :failed)) ->
        failed = Enum.find(checks, fn c -> normalize_check(c) == :failed end)
        {:failed, failed["name"] || "unknown check"}

      Enum.all?(states, &(&1 == :passed)) ->
        :passed

      true ->
        :pending
    end
  end

  defp normalize_check(%{"bucket" => bucket}) do
    case bucket do
      "pass" -> :passed
      "fail" -> :failed
      "skipping" -> :passed
      _ -> :pending
    end
  end

  defp normalize_check(_), do: :pending

  defp gh(args) do
    case System.cmd("gh", args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, _} -> {:error, String.trim(output)}
    end
  end
end
