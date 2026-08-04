defmodule Shep.CIWatch.GitHub do
  @moduledoc """
  Default `Shep.CIWatch` adapter: polls `gh pr checks`, retries the
  watch on failure (up to 3 attempts), and assembles failing-check
  logs from `gh run view --log-failed`.

  Green is decided on evidence of presence, never on absence of
  failure. GitHub cannot compute a merge ref for a conflicting PR, so
  it creates no check suites for it at all — "nothing failing" there
  means "nothing ran". Two guards keep that state out of `:passed`:
  every poll reads mergeability first and short-circuits a conflict to
  `{:conflict, _}` (which a fix turn can resolve by merging the base),
  and a PR that produces no real check verdict within the grace window
  settles as `{:unverified, _}`.
  """

  @behaviour Shep.CIWatch

  require Logger

  @max_ci_retries 3
  @poll_interval_ms 30_000
  @max_poll_errors 5
  @grace_ms 300_000

  @typedoc "The verdict of a single poll, before the watch loop settles it."
  @type poll ::
          :passed
          | {:pending, :evidence | :no_evidence}
          | {:failed, String.t()}
          | {:conflict, String.t()}
          | {:error, String.t()}

  @impl true
  def watch(repo, pr_number, opts \\ []) do
    max_retries = Keyword.get(opts, :max_retries, @max_ci_retries)
    do_watch(repo, pr_number, 0, max_retries, nil, opts)
  end

  defp do_watch(_repo, _pr, attempt, max, last_failure, _opts) when attempt >= max do
    Logger.error("CI retries exhausted (#{max} attempts)")
    {:failed, last_failure || "ci-loop-exhausted"}
  end

  defp do_watch(repo, pr_number, attempt, max, _last_failure, opts) do
    Logger.info("Watching CI for PR ##{pr_number} (attempt #{attempt + 1}/#{max})")

    case poll_until_settled(repo, pr_number, 0, 0, opts) do
      :passed ->
        Logger.info("CI passed for PR ##{pr_number}")
        :passed

      {:conflict, detail} ->
        Logger.warning("PR ##{pr_number} cannot be merged, so CI cannot run: #{detail}")
        {:conflict, detail}

      {:unverified, reason} ->
        Logger.error("CI never reported on PR ##{pr_number}: #{reason}")
        {:unverified, reason}

      {:failed, reason} ->
        Logger.warning("CI failed for PR ##{pr_number}: #{reason}")
        do_watch(repo, pr_number, attempt + 1, max, reason, opts)

      {:poll_errors_exhausted, reason} ->
        {:failed, "poll-error: #{reason}"}
    end
  end

  # One attempt: re-poll through :pending (and transient poll errors)
  # without re-logging the attempt banner. `waited_ms` is the grace
  # clock, and it only bounds the wait for the FIRST real check
  # verdict; once something has reported, a slow suite may take as
  # long as it likes.
  defp poll_until_settled(repo, pr_number, poll_errors, waited_ms, opts) do
    case poll_once(repo, pr_number, opts) do
      {:pending, :no_evidence} -> await_evidence(repo, pr_number, waited_ms, opts)
      {:pending, :evidence} -> sleep_and_poll(repo, pr_number, 0, waited_ms, opts)
      {:error, reason} -> poll_error(repo, pr_number, poll_errors, waited_ms, opts, reason)
      settled -> settled
    end
  end

  defp poll_once(repo, pr_number, opts) do
    case merge_state(repo, pr_number) do
      {:conflict, detail} -> {:conflict, detail}
      :ok -> poll_checks(repo, pr_number, opts)
    end
  end

  defp await_evidence(repo, pr_number, waited_ms, opts) do
    grace = Keyword.get(opts, :grace_ms, @grace_ms)

    if waited_ms >= grace do
      {:unverified, "no check reported a verdict within #{div(grace, 1000)}s"}
    else
      sleep_and_poll(repo, pr_number, 0, waited_ms, opts)
    end
  end

  defp sleep_and_poll(repo, pr_number, poll_errors, waited_ms, opts) do
    interval = Keyword.get(opts, :poll_interval_ms, @poll_interval_ms)
    Process.sleep(interval)
    poll_until_settled(repo, pr_number, poll_errors, waited_ms + interval, opts)
  end

  defp poll_error(repo, pr_number, poll_errors, waited_ms, opts, reason) do
    errors = poll_errors + 1

    if errors >= @max_poll_errors do
      Logger.error("CI poll errors exhausted (#{errors} consecutive failures)")
      {:poll_errors_exhausted, reason}
    else
      Logger.warning("CI poll error #{errors}/#{@max_poll_errors}: #{reason}")
      sleep_and_poll(repo, pr_number, errors, waited_ms, opts)
    end
  end

  @doc """
  Mergeability of a PR.

  `{:conflict, detail}` when GitHub reports the head branch as
  conflicting with the base: the state in which it creates no check
  suites, so waiting for checks would wait forever. Everything else,
  including an unreadable answer, is `:ok` — this guard adds a failure
  path, it never invents one.
  """
  @spec merge_state(String.t(), String.t()) :: :ok | {:conflict, String.t()}
  def merge_state(repo, pr_number) do
    args = ["pr", "view", pr_number, "--repo", repo, "--json", "mergeable,mergeStateStatus"]

    case Shep.GH.run(args) do
      {:ok, json} ->
        json |> Jason.decode!() |> classify_merge_state()

      {:error, reason} ->
        Logger.debug("Could not read mergeability of PR ##{pr_number}: #{reason}")
        :ok
    end
  rescue
    _ -> :ok
  end

  defp classify_merge_state(%{"mergeable" => "CONFLICTING"} = pr), do: {:conflict, describe(pr)}
  defp classify_merge_state(%{"mergeStateStatus" => "DIRTY"} = pr), do: {:conflict, describe(pr)}
  defp classify_merge_state(_pr), do: :ok

  defp describe(pr) do
    "mergeable=#{pr["mergeable"] || "UNKNOWN"} " <>
      "mergeStateStatus=#{pr["mergeStateStatus"] || "UNKNOWN"}"
  end

  @doc """
  Check current CI status for a PR.

  `{:pending, :no_evidence}` means nothing has reported yet — the state
  a conflicted or workflow-less PR sits in forever, and the one a
  caller must never read as success. `{:pending, :evidence}` means real
  checks are running and the answer is simply not in yet.
  """
  @spec poll_checks(String.t(), String.t(), keyword()) :: poll()
  def poll_checks(repo, pr_number, opts \\ []) do
    args = ["pr", "checks", pr_number, "--repo", repo, "--json", "name,state,bucket,link"]

    case Shep.GH.run(args) do
      {:ok, json} -> json |> Jason.decode!() |> evaluate_checks(required_checks(opts))
      {:error, reason} -> classify_error(reason)
    end
  end

  # `gh pr checks` exits non-zero with this message when the PR has no
  # check suites at all. That is the absence this adapter exists to
  # catch, not a transient poll error.
  defp classify_error(reason) do
    if String.contains?(reason, "no checks reported") do
      {:pending, :no_evidence}
    else
      Logger.warning("Failed to fetch PR checks: #{reason}")
      {:error, reason}
    end
  end

  defp required_checks(opts) do
    opts |> Keyword.get(:required_checks) |> List.wrap() |> Enum.filter(&is_binary/1)
  end

  defp evaluate_checks(checks, required) do
    case Enum.find(checks, &(bucket(&1) == :fail)) do
      nil -> evaluate_unfailed(checks, required)
      failed -> {:failed, failed["name"] || "unknown check"}
    end
  end

  defp evaluate_unfailed(checks, required) do
    cond do
      not Enum.any?(checks, &evidence?/1) -> {:pending, :no_evidence}
      required != [] -> required_verdict(checks, required)
      Enum.any?(checks, &(bucket(&1) == :pending)) -> {:pending, :evidence}
      true -> :passed
    end
  end

  # With a required list configured the answer is the branch-protection
  # answer: those checks passed, whatever else a third-party app is
  # still doing on the side.
  defp required_verdict(checks, required) do
    passed = for c <- checks, bucket(c) == :pass, into: MapSet.new(), do: c["name"]

    case Enum.reject(required, &MapSet.member?(passed, &1)) do
      [] -> :passed
      _missing -> {:pending, :evidence}
    end
  end

  # A check is evidence only if something really looked at this commit:
  # a completed non-skipped verdict from any provider, or a check GitHub
  # Actions created at all — a workflow that ran and skipped by path
  # filter still proves the suite exists. A conflicted PR gets no Actions
  # check suites whatsoever, so a skipped review bot and a queued
  # third-party app, which is all it ever shows, count for nothing.
  defp evidence?(check) do
    bucket(check) in [:pass, :fail] or run_id_from_link(check["link"]) != nil
  end

  defp bucket(%{"bucket" => "pass"}), do: :pass
  defp bucket(%{"bucket" => "fail"}), do: :fail
  defp bucket(%{"bucket" => "skipping"}), do: :skip
  defp bucket(_check), do: :pending

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
