defmodule Mix.Tasks.Shep.PromoteTest do
  # Installs the :gh_runner app env, so no concurrent cases.
  use ExUnit.Case, async: false

  alias Mix.Tasks.Shep.Promote

  setup do
    on_exit(fn -> Application.delete_env(:shep, :gh_runner) end)
    :ok
  end

  defp tmp_dir(prefix) do
    n = System.unique_integer([:positive])
    dir = Path.join(System.tmp_dir!(), "#{prefix}_#{n}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp git!(cwd, args), do: {_, 0} = System.cmd("git", ["-C", cwd | args])

  defp identify(cwd) do
    git!(cwd, ["config", "user.email", "test@example.com"])
    git!(cwd, ["config", "user.name", "Test"])
  end

  defp write_commit(cwd, file, content, subject) do
    File.write!(Path.join(cwd, file), content)
    git!(cwd, ["add", file])
    git!(cwd, ["commit", "-q", "-m", subject])
  end

  # A real repo with `main` plus `staging` carrying `extra` empty commits.
  defp repo_with_staging_ahead(extra_subjects) do
    wt = tmp_dir("shep_promote")
    git!(wt, ["init", "-q", "-b", "main"])
    identify(wt)
    git!(wt, ["commit", "-q", "--allow-empty", "-m", "base"])
    git!(wt, ["checkout", "-q", "-b", "staging"])

    Enum.each(extra_subjects, fn subject ->
      git!(wt, ["commit", "-q", "--allow-empty", "-m", subject])
    end)

    wt
  end

  defp config,
    do: %{"tracker" => %{"repo" => "org/repo"}, "staging" => %{"base_branch" => "staging"}}

  # Capture the args of a single `pr create` call, stubbing `pr list` as empty.
  defp capture_pr_create do
    test_pid = self()

    Application.put_env(:shep, :gh_runner, fn
      ["pr", "list" | _] -> {:ok, "[]"}
      ["pr", "create" | _] = args -> send(test_pid, {:gh, args}) && {:ok, "https://x/pull/1"}
    end)
  end

  defp arg_after(args, flag), do: Enum.at(args, Enum.find_index(args, &(&1 == flag)) + 1)

  test "opens a staging→main PR with an auto-generated Release title" do
    capture_pr_create()
    wt = repo_with_staging_ahead(["add widget"])

    assert :ok = Promote.promote(config(), wt)
    assert_received {:gh, args}

    assert arg_after(args, "--base") == "main"
    assert arg_after(args, "--head") == "staging"

    title = arg_after(args, "--title")
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

  test "drops a commit whose content already reached main under a different SHA" do
    capture_pr_create()

    # staging carries alpha + beta; alpha's content is separately squashed onto
    # main (different SHA), so only beta is genuinely being promoted.
    wt = tmp_dir("shep_promote_squash")
    git!(wt, ["init", "-q", "-b", "main"])
    identify(wt)
    git!(wt, ["commit", "-q", "--allow-empty", "-m", "base"])
    git!(wt, ["checkout", "-q", "-b", "staging"])
    write_commit(wt, "alpha.txt", "alpha\n", "feat: add alpha (#1)")
    write_commit(wt, "beta.txt", "beta\n", "feat: add beta (#2)")
    git!(wt, ["checkout", "-q", "main"])
    write_commit(wt, "alpha.txt", "alpha\n", "promote alpha to main (#9)")

    assert :ok = Promote.promote(config(), wt)
    assert_received {:gh, args}

    body = arg_after(args, "--body")
    assert body =~ "add beta"
    refute body =~ "add alpha"
    assert arg_after(args, "--title") =~ "add beta"
  end

  test "resolves against fetched remote refs, not a stale local main" do
    capture_pr_create()

    # Bare remote + working clone. alpha lands on staging AND (later, via a
    # separate clone) is squashed onto remote main. The working clone's local
    # main stays behind; only after the task's fetch does the squash show up on
    # the tracking ref that `git cherry` compares against.
    root = tmp_dir("shep_promote_remote")
    bare = Path.join(root, "origin.git")
    git!(root, ["init", "-q", "--bare", "-b", "main", bare])

    work = Path.join(root, "work")
    git!(root, ["clone", "-q", bare, work])
    identify(work)
    git!(work, ["commit", "-q", "--allow-empty", "-m", "base"])
    git!(work, ["push", "-q", "origin", "main"])
    git!(work, ["checkout", "-q", "-b", "staging"])
    write_commit(work, "alpha.txt", "alpha\n", "feat: add alpha (#1)")
    write_commit(work, "beta.txt", "beta\n", "feat: add beta (#2)")
    git!(work, ["push", "-q", "origin", "staging"])

    # Advance remote main from another clone: alpha squashed under a new SHA.
    other = Path.join(root, "other")
    git!(root, ["clone", "-q", bare, other])
    identify(other)
    write_commit(other, "alpha.txt", "alpha\n", "promote alpha to main (#9)")
    git!(other, ["push", "-q", "origin", "main"])

    # `work` never fetched: local main and origin/main are both stale here.
    assert :ok = Promote.promote(config(), work)
    assert_received {:gh, args}

    body = arg_after(args, "--body")
    assert body =~ "add beta"
    refute body =~ "add alpha"
  end

  test "derives the headline from PR titles, not an N-changes count" do
    capture_pr_create()

    wt = tmp_dir("shep_promote_headline")
    git!(wt, ["init", "-q", "-b", "main"])
    identify(wt)
    git!(wt, ["commit", "-q", "--allow-empty", "-m", "base"])
    git!(wt, ["checkout", "-q", "-b", "staging"])
    write_commit(wt, "a.txt", "a\n", "feat: rewrite promote flow (#41)")
    write_commit(wt, "b.txt", "b\n", "chore(release): 0.3.3 (#42)")
    write_commit(wt, "c.txt", "c\n", "docs: update guide (#38)")

    assert :ok = Promote.promote(config(), wt)
    assert_received {:gh, args}

    title = arg_after(args, "--title")
    assert title =~ "rewrite promote flow"
    refute title =~ ~r/\d+ changes/
  end

  defp collect_gh(acc) do
    receive do
      {:gh, args} -> collect_gh([args | acc])
    after
      0 -> acc
    end
  end
end
