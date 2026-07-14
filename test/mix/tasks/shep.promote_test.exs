defmodule Mix.Tasks.Shep.PromoteTest do
  # Installs the :gh_runner app env, so no concurrent cases.
  use ExUnit.Case, async: false

  alias Mix.Tasks.Shep.Promote

  setup do
    on_exit(fn -> Application.delete_env(:shep, :gh_runner) end)
    :ok
  end

  # A real repo with `main` plus `staging` carrying `extra` commits ahead of it.
  defp repo_with_staging_ahead(extra_subjects) do
    n = System.unique_integer([:positive])
    wt = Path.join(System.tmp_dir!(), "shep_promote_#{n}")
    File.mkdir_p!(wt)
    on_exit(fn -> File.rm_rf!(wt) end)

    git = fn args -> {_, 0} = System.cmd("git", ["-C", wt | args]) end
    git.(["init", "-q", "-b", "main"])
    git.(["config", "user.email", "test@example.com"])
    git.(["config", "user.name", "Test"])
    git.(["commit", "-q", "--allow-empty", "-m", "base"])
    git.(["checkout", "-q", "-b", "staging"])

    Enum.each(extra_subjects, fn subject ->
      git.(["commit", "-q", "--allow-empty", "-m", subject])
    end)

    wt
  end

  defp config,
    do: %{"tracker" => %{"repo" => "org/repo"}, "staging" => %{"base_branch" => "staging"}}

  test "opens a staging→main PR with an auto-generated Release title" do
    test_pid = self()

    Application.put_env(:shep, :gh_runner, fn
      ["pr", "list" | _] -> {:ok, "[]"}
      ["pr", "create" | _] = args -> send(test_pid, {:gh, args}) && {:ok, "https://x/pull/1"}
    end)

    wt = repo_with_staging_ahead(["add widget"])

    assert :ok = Promote.promote(config(), wt)

    assert_received {:gh, args}

    assert "--base" in args and
             "main" == Enum.at(args, Enum.find_index(args, &(&1 == "--base")) + 1)

    assert "--head" in args and
             "staging" == Enum.at(args, Enum.find_index(args, &(&1 == "--head")) + 1)

    title = Enum.at(args, Enum.find_index(args, &(&1 == "--title")) + 1)
    assert title =~ ~r/^Release v\d/
    assert title =~ "add widget"
  end

  test "never issues a merge command down any path" do
    test_pid = self()

    Application.put_env(:shep, :gh_runner, fn args ->
      send(test_pid, {:gh, args})
      if match?(["pr", "list" | _], args), do: {:ok, "[]"}, else: {:ok, "https://x/pull/2"}
    end)

    wt = repo_with_staging_ahead(["one", "two"])

    assert :ok = Promote.promote(config(), wt)

    captured = collect_gh([])
    refute Enum.any?(captured, fn args -> "merge" in args end)
  end

  test "reports and exits without opening a PR when nothing is ahead of main" do
    test_pid = self()

    Application.put_env(:shep, :gh_runner, fn args ->
      send(test_pid, {:gh, args})
      {:ok, "[]"}
    end)

    wt = repo_with_staging_ahead([])

    assert :ok = Promote.promote(config(), wt)
    refute_received {:gh, ["pr", "create" | _]}
  end

  test "reports the existing PR URL instead of opening a duplicate" do
    test_pid = self()

    Application.put_env(:shep, :gh_runner, fn
      ["pr", "list" | _] -> {:ok, ~s([{"url":"https://x/pull/7"}])}
      other -> send(test_pid, {:gh, other}) && {:ok, ""}
    end)

    wt = repo_with_staging_ahead(["something"])

    assert :ok = Promote.promote(config(), wt)
    refute_received {:gh, ["pr", "create" | _]}
  end

  defp collect_gh(acc) do
    receive do
      {:gh, args} -> collect_gh([args | acc])
    after
      0 -> acc
    end
  end
end
