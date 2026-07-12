defmodule Shep.CIWatch.GitHub do
  @moduledoc """
  Default `Shep.CIWatch` adapter: polls `gh pr checks`, retries the
  watch on failure (up to 3 attempts), and assembles failing-check
  logs from `gh run view --log-failed`.
  """

  @behaviour Shep.CIWatch

  require Logger

  @max_ci_retries 3
  @poll_interval_ms 30_000
  @max_poll_errors 5

  @impl true
  def watch(repo, pr_number, opts \\ []) do
    max_retries = Keyword.get(opts, :max_retries, @max_ci_retries)
    do_watch(repo, pr_number, 0, max_retries, nil)
  end

  defp do_watch(_repo, _pr, attempt, max, last_failure) when attempt >= max do
    Logger.error("CI retries exhausted (#{max} attempts)")
    {:failed, last_failure || "ci-loop-exhausted"}
  end

  defp do_watch(repo, pr_number, attempt, max, _last_failure) do
    Logger.info("Watching CI for PR ##{pr_number} (attempt #{attempt + 1}/#{max})")

    case poll_until_settled(repo, pr_number, 0) do
      :passed ->
        Logger.info("CI passed for PR ##{pr_number}")
        :passed

      {:failed, reason} ->
        Logger.warning("CI failed for PR ##{pr_number}: #{reason}")
        do_watch(repo, pr_number, attempt + 1, max, reason)

      {:poll_errors_exhausted, reason} ->
        {:failed, "poll-error: #{reason}"}
    end
  end

  # One attempt: re-poll through :pending (and transient poll errors)
  # without re-logging the attempt banner.
  defp poll_until_settled(repo, pr_number, poll_errors) do
    case poll_checks(repo, pr_number) do
      :passed ->
        :passed

      {:failed, reason} ->
        {:failed, reason}

      {:error, reason} ->
        new_errors = poll_errors + 1

        if new_errors >= @max_poll_errors do
          Logger.error("CI poll errors exhausted (#{new_errors} consecutive failures)")
          {:poll_errors_exhausted, reason}
        else
          Logger.warning("CI poll error #{new_errors}/#{@max_poll_errors}: #{reason}")
          Process.sleep(@poll_interval_ms)
          poll_until_settled(repo, pr_number, new_errors)
        end

      :pending ->
        Process.sleep(@poll_interval_ms)
        poll_until_settled(repo, pr_number, 0)
    end
  end

  @doc "Check current CI status for a PR."
  @spec poll_checks(String.t(), String.t()) ::
          :passed | :pending | {:failed, String.t()} | {:error, String.t()}
  def poll_checks(repo, pr_number) do
    case Shep.GH.run(["pr", "checks", pr_number, "--repo", repo, "--json", "name,state,bucket"]) do
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

  @impl true
  def failure_logs(repo, pr_number) do
    case Shep.GH.run(["pr", "checks", pr_number, "--repo", repo, "--json", "name,bucket,link"]) do
      {:ok, json} ->
        json
        |> Jason.decode!()
        |> Enum.filter(&(&1["bucket"] == "fail"))
        |> Enum.map_join("\n\n", &check_log(repo, &1))

      {:error, _} ->
        ""
    end
  rescue
    _ -> ""
  end

  defp check_log(repo, check) do
    case run_id_from_link(check["link"]) do
      nil ->
        "#{check["name"]}: failed (no logs available)"

      run_id ->
        case Shep.GH.run(["run", "view", run_id, "--repo", repo, "--log-failed"]) do
          {:ok, log} -> "### #{check["name"]}\n" <> Shep.Goal.tail(log, 6_000)
          {:error, _} -> "#{check["name"]}: failed (logs unavailable)"
        end
    end
  end

  @doc false
  def run_id_from_link(link) when is_binary(link) do
    case Regex.run(~r{/runs/(\d+)}, link) do
      [_, id] -> id
      _ -> nil
    end
  end

  def run_id_from_link(_), do: nil
end
