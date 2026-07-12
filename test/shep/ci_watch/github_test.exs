defmodule Shep.CIWatch.GitHubTest do
  # Installs a scripted :gh_runner in the app env, so this module must
  # not run concurrently with other cases.
  use ExUnit.Case, async: false

  alias Shep.CIWatch.GitHub

  defp stub_gh(fun) do
    Application.put_env(:shep, :gh_runner, fun)
    on_exit(fn -> Application.delete_env(:shep, :gh_runner) end)
  end

  defp stub_checks(checks) do
    stub_gh(fn ["pr", "checks", _pr, "--repo", _repo, "--json", "name,state,bucket"] ->
      {:ok, Jason.encode!(checks)}
    end)
  end

  describe "poll_checks/2" do
    test "all passed checks return :passed" do
      stub_checks([
        %{"name" => "Quality", "state" => "COMPLETED", "bucket" => "pass"},
        %{"name" => "Build", "state" => "COMPLETED", "bucket" => "pass"}
      ])

      assert :passed == GitHub.poll_checks("org/repo", "7")
    end

    test "any failed check returns {:failed, name}" do
      stub_checks([
        %{"name" => "Quality", "state" => "COMPLETED", "bucket" => "pass"},
        %{"name" => "Build", "state" => "COMPLETED", "bucket" => "fail"}
      ])

      assert {:failed, "Build"} == GitHub.poll_checks("org/repo", "7")
    end

    test "pending check returns :pending" do
      stub_checks([
        %{"name" => "Quality", "state" => "IN_PROGRESS", "bucket" => ""},
        %{"name" => "Build", "state" => "COMPLETED", "bucket" => "pass"}
      ])

      assert :pending == GitHub.poll_checks("org/repo", "7")
    end

    test "empty checks returns :pending" do
      stub_checks([])
      assert :pending == GitHub.poll_checks("org/repo", "7")
    end

    test "skipping bucket treated as passed" do
      stub_checks([
        %{"name" => "Test", "state" => "COMPLETED", "bucket" => "skipping"},
        %{"name" => "Build", "state" => "COMPLETED", "bucket" => "pass"}
      ])

      assert :passed == GitHub.poll_checks("org/repo", "7")
    end

    test "check without bucket field treated as pending" do
      stub_checks([%{"name" => "Test", "state" => "IN_PROGRESS"}])
      assert :pending == GitHub.poll_checks("org/repo", "7")
    end

    test "gh failure returns {:error, reason}" do
      stub_gh(fn _args -> {:error, "boom"} end)
      assert {:error, "boom"} == GitHub.poll_checks("org/repo", "7")
    end
  end

  describe "watch/3" do
    test "returns :passed when the first poll is green" do
      stub_checks([%{"name" => "Quality", "state" => "COMPLETED", "bucket" => "pass"}])
      assert :passed == GitHub.watch("org/repo", "7", max_retries: 1)
    end

    test "returns the failing check name when retries are exhausted" do
      stub_checks([%{"name" => "Quality", "state" => "COMPLETED", "bucket" => "fail"}])
      assert {:failed, "Quality"} == GitHub.watch("org/repo", "7", max_retries: 1)
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
