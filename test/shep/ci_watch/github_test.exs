defmodule Shep.CIWatch.GitHubTest do
  # Installs a scripted :gh_runner in the app env, so this module must
  # not run concurrently with other cases.
  use ExUnit.Case, async: false

  alias Shep.CIWatch.GitHub

  @checks_args ["--json", "name,state,bucket,link"]
  @actions_link "https://github.com/org/repo/actions/runs/123/job/456"

  defp stub_gh(fun) do
    Application.put_env(:shep, :gh_runner, fun)
    on_exit(fn -> Application.delete_env(:shep, :gh_runner) end)
  end

  # The watch reads mergeability every poll, so a checks stub has to
  # answer both calls.
  defp stub_checks(checks, merge \\ %{"mergeable" => "MERGEABLE", "mergeStateStatus" => "CLEAN"}) do
    stub_gh(fn
      ["pr", "checks", _pr, "--repo", _repo | @checks_args] -> {:ok, Jason.encode!(checks)}
      ["pr", "view", _pr, "--repo", _repo, "--json", _fields] -> {:ok, Jason.encode!(merge)}
    end)
  end

  defp check(name, bucket, link \\ nil) do
    %{"name" => name, "state" => "COMPLETED", "bucket" => bucket, "link" => link}
  end

  describe "poll_checks/3" do
    test "a completed pass with nothing pending is :passed" do
      stub_checks([check("Quality", "pass"), check("Build", "pass")])
      assert :passed == GitHub.poll_checks("org/repo", "7")
    end

    test "any failed check returns {:failed, name}" do
      stub_checks([check("Quality", "pass"), check("Build", "fail")])
      assert {:failed, "Build"} == GitHub.poll_checks("org/repo", "7")
    end

    test "a pending check alongside a real verdict is pending with evidence" do
      stub_checks([check("Quality", ""), check("Build", "pass")])
      assert {:pending, :evidence} == GitHub.poll_checks("org/repo", "7")
    end

    test "empty checks are pending with no evidence, never passed" do
      stub_checks([])
      assert {:pending, :no_evidence} == GitHub.poll_checks("org/repo", "7")
    end

    test "skips alone are not evidence: the conflicted-PR shape is not :passed" do
      # Exactly what a CONFLICTING PR shows: a skipped review bot and a
      # queued third-party app. Zero failing, zero Actions runs.
      stub_checks([
        check("CodeRabbit", "skipping"),
        check("some-app", "", "https://example.com/status/1")
      ])

      assert {:pending, :no_evidence} == GitHub.poll_checks("org/repo", "7")
    end

    test "a skip beside a real pass is still :passed" do
      stub_checks([check("Test", "skipping"), check("Build", "pass")])
      assert :passed == GitHub.poll_checks("org/repo", "7")
    end

    test "a queued Actions run counts as evidence" do
      stub_checks([check("Quality", "", @actions_link)])
      assert {:pending, :evidence} == GitHub.poll_checks("org/repo", "7")
    end

    test "workflows that all skipped by path filter are green, not unverified" do
      # Actions built the suite and every job skipped: that is a real
      # verdict on this commit, unlike a third-party bot's skip.
      stub_checks([check("docs-only", "skipping", @actions_link)])
      assert :passed == GitHub.poll_checks("org/repo", "7")
    end

    test "check without bucket field is pending and, unlinked, not evidence" do
      stub_checks([%{"name" => "Test", "state" => "IN_PROGRESS"}])
      assert {:pending, :no_evidence} == GitHub.poll_checks("org/repo", "7")
    end

    test "gh's no-checks error is absence, not a poll error" do
      stub_gh(fn _args -> {:error, "no checks reported on the 'shep/7' branch"} end)
      assert {:pending, :no_evidence} == GitHub.poll_checks("org/repo", "7")
    end

    test "gh failure returns {:error, reason}" do
      stub_gh(fn _args -> {:error, "boom"} end)
      assert {:error, "boom"} == GitHub.poll_checks("org/repo", "7")
    end

    test "required checks must all have passed, whatever else is queued" do
      stub_checks([check("quality", "pass"), check("coderabbit", "", @actions_link)])
      opts = [required_checks: ["quality"]]
      assert :passed == GitHub.poll_checks("org/repo", "7", opts)
    end

    test "a missing required check keeps the verdict pending" do
      stub_checks([check("quality", "pass")])
      opts = [required_checks: ["quality", "release-smoke"]]
      assert {:pending, :evidence} == GitHub.poll_checks("org/repo", "7", opts)
    end
  end

  describe "merge_state/2" do
    test "CONFLICTING is a conflict" do
      stub_checks([], %{"mergeable" => "CONFLICTING", "mergeStateStatus" => "DIRTY"})
      assert {:conflict, detail} = GitHub.merge_state("org/repo", "7")
      assert detail =~ "CONFLICTING"
    end

    test "a DIRTY merge state alone is a conflict" do
      stub_checks([], %{"mergeable" => "UNKNOWN", "mergeStateStatus" => "DIRTY"})
      assert {:conflict, _} = GitHub.merge_state("org/repo", "7")
    end

    test "MERGEABLE and UNKNOWN are both :ok" do
      stub_checks([], %{"mergeable" => "MERGEABLE", "mergeStateStatus" => "CLEAN"})
      assert :ok == GitHub.merge_state("org/repo", "7")

      stub_checks([], %{"mergeable" => "UNKNOWN", "mergeStateStatus" => "UNKNOWN"})
      assert :ok == GitHub.merge_state("org/repo", "7")
    end

    test "an unreadable answer never invents a conflict" do
      stub_gh(fn _args -> {:error, "boom"} end)
      assert :ok == GitHub.merge_state("org/repo", "7")

      stub_gh(fn _args -> {:ok, "not json"} end)
      assert :ok == GitHub.merge_state("org/repo", "7")
    end
  end

  describe "watch/3" do
    test "returns :passed when the first poll is green" do
      stub_checks([check("Quality", "pass")])
      assert :passed == GitHub.watch("org/repo", "7", max_retries: 1)
    end

    test "returns the failing check name when retries are exhausted" do
      stub_checks([check("Quality", "fail")])
      assert {:failed, "Quality"} == GitHub.watch("org/repo", "7", max_retries: 1)
    end

    test "a conflicted PR short-circuits to {:conflict, _} without waiting for checks" do
      stub_checks([], %{"mergeable" => "CONFLICTING", "mergeStateStatus" => "DIRTY"})

      assert {:conflict, detail} =
               GitHub.watch("org/repo", "7", max_retries: 1, grace_ms: 0)

      assert detail =~ "CONFLICTING"
    end

    test "a PR that reports nothing settles as {:unverified, _}, never :passed" do
      stub_checks([check("CodeRabbit", "skipping")])

      assert {:unverified, reason} = GitHub.watch("org/repo", "7", max_retries: 1, grace_ms: 0)
      assert reason =~ "no check reported"
    end

    test "the grace window is a wait, not an immediate verdict" do
      # First poll sees nothing, the second sees a green run: the watch
      # must ride out the grace window rather than settle on absence.
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      stub_gh(fn
        ["pr", "view", _pr, "--repo", _repo, "--json", _fields] ->
          {:ok, Jason.encode!(%{"mergeable" => "MERGEABLE", "mergeStateStatus" => "CLEAN"})}

        ["pr", "checks", _pr, "--repo", _repo | @checks_args] ->
          n = Agent.get_and_update(counter, &{&1, &1 + 1})
          if n == 0, do: {:ok, "[]"}, else: {:ok, Jason.encode!([check("Quality", "pass")])}
      end)

      assert :passed ==
               GitHub.watch("org/repo", "7",
                 max_retries: 1,
                 grace_ms: 60_000,
                 poll_interval_ms: 1
               )
    end
  end

  describe "failure_logs/2" do
    test "assembles the failed check header and the log tail" do
      run_log = "starting...\nerror: assertion failed on line 12"

      stub_gh(fn
        ["pr", "checks", "7", "--repo", "org/repo", "--json", "name,bucket,link"] ->
          {:ok,
           Jason.encode!([
             %{
               "name" => "Quality",
               "bucket" => "fail",
               "link" => "https://github.com/org/repo/actions/runs/123/job/456"
             },
             %{
               "name" => "Build",
               "bucket" => "pass",
               "link" => "https://github.com/org/repo/actions/runs/124/job/457"
             }
           ])}

        ["run", "view", "123", "--repo", "org/repo", "--log-failed"] ->
          {:ok, run_log}
      end)

      logs = GitHub.failure_logs("org/repo", "7")
      assert logs =~ "### Quality"
      assert logs =~ "assertion failed on line 12"
      refute logs =~ "Build"
    end

    test "a failed check without a run link degrades to a stub line" do
      stub_gh(fn ["pr", "checks", _, "--repo", _, "--json", "name,bucket,link"] ->
        {:ok, Jason.encode!([%{"name" => "Lint", "bucket" => "fail", "link" => nil}])}
      end)

      assert "Lint: failed (no logs available)" == GitHub.failure_logs("org/repo", "7")
    end

    test "gh failure on the checks listing returns an empty block" do
      stub_gh(fn _args -> {:error, "boom"} end)
      assert "" == GitHub.failure_logs("org/repo", "7")
    end
  end

  describe "run_id_from_link/1" do
    test "extracts run id from a checks link" do
      link = "https://github.com/o/r/actions/runs/1234567/job/89"
      assert Shep.CIWatch.GitHub.run_id_from_link(link) == "1234567"
    end

    test "nil-safe on garbage" do
      assert Shep.CIWatch.GitHub.run_id_from_link("https://example.com") == nil
      assert Shep.CIWatch.GitHub.run_id_from_link(nil) == nil
    end
  end

  test "the default gh runner returns {:error, reason} on gh failure" do
    # No stub installed here: exercises the real System.cmd path in
    # Shep.GH against a repo that cannot exist.
    Application.delete_env(:shep, :gh_runner)
    assert {:error, _} = Shep.CIWatch.GitHub.poll_checks("fake/repo", "99999")
  end
end
