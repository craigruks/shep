defmodule Shep.Tracker.GitHubTest do
  use ExUnit.Case, async: true

  alias Shep.Tracker.GitHub

  describe "parse_task_type/1" do
    test "extracts type from type: label" do
      labels = [%{"name" => "shep"}, %{"name" => "type:lint-fix"}]
      assert "lint-fix" == GitHub.parse_task_type(labels)
    end

    test "returns nil when no type label" do
      labels = [%{"name" => "shep"}, %{"name" => "bug"}]
      assert nil == GitHub.parse_task_type(labels)
    end

    test "handles empty labels" do
      assert nil == GitHub.parse_task_type([])
    end

    test "extracts custom type" do
      labels = [%{"name" => "type:custom"}]
      assert "custom" == GitHub.parse_task_type(labels)
    end
  end

  describe "no_merge?/1" do
    test "true when shep:no-merge label present" do
      labels = [
        %{"name" => "shep"},
        %{"name" => "shep:no-merge"},
        %{"name" => "type:lint-fix"}
      ]

      assert GitHub.no_merge?(labels)
    end

    test "false when no-merge label absent" do
      labels = [%{"name" => "shep"}, %{"name" => "type:lint-fix"}]
      refute GitHub.no_merge?(labels)
    end

    test "false for empty labels" do
      refute GitHub.no_merge?([])
    end
  end

  describe "parse_depends_on/1" do
    test "parses single dependency" do
      body = "Fix the bug\n\nDepends on: #42"
      assert ["42"] == GitHub.parse_depends_on(body)
    end

    test "parses multiple dependencies" do
      body = "Depends on: #12, #45, #100"
      assert ["12", "45", "100"] == GitHub.parse_depends_on(body)
    end

    test "returns empty for nil body" do
      assert [] == GitHub.parse_depends_on(nil)
    end

    test "returns empty when no depends line" do
      assert [] == GitHub.parse_depends_on("Just a regular issue body")
    end

    test "case insensitive" do
      body = "depends on: #7"
      assert ["7"] == GitHub.parse_depends_on(body)
    end

    test "handles extra whitespace" do
      body = "Depends on:   #3,  #5"
      assert ["3", "5"] == GitHub.parse_depends_on(body)
    end
  end
end

defmodule Shep.Tracker.GitHubLabelTest do
  # Installs a recording :gh_runner in the app env, so this module must
  # not run concurrently with other cases.
  use ExUnit.Case, async: false

  alias Shep.Tracker.GitHub

  setup do
    test_pid = self()

    Application.put_env(:shep, :gh_runner, fn args ->
      send(test_pid, {:gh, args})
      {:ok, ""}
    end)

    on_exit(fn -> Application.delete_env(:shep, :gh_runner) end)

    {:ok, repo: get_in(Shep.Config.current!(), ["tracker", "repo"])}
  end

  test "claim removes the queued label and adds in-progress", %{repo: repo} do
    assert :ok = GitHub.claim("42")

    assert [
             ["issue", "edit", "42", "--repo", ^repo, "--remove-label", "shep"],
             ["issue", "edit", "42", "--repo", ^repo, "--add-label", "shep:in-progress"]
           ] = collect_gh_calls()
  end

  test "update_status clears the other status labels before adding the new one", %{repo: repo} do
    assert :ok = GitHub.update_status("7", "pr-created")

    calls = collect_gh_calls()
    {removals, additions} = Enum.split_with(calls, &("--remove-label" in &1))

    removed = removals |> Enum.map(&List.last/1) |> Enum.sort()

    expected =
      ~w(shep shep:failed shep:in-progress shep:in-review shep:pr-created shep:promoted)

    assert expected == removed
    assert [["issue", "edit", "7", "--repo", ^repo, "--add-label", "shep:pr-created"]] = additions

    assert List.last(calls) == [
             "issue",
             "edit",
             "7",
             "--repo",
             repo,
             "--add-label",
             "shep:pr-created"
           ]
  end

  test "unknown status returns an error tuple without touching gh" do
    assert {:error, "unknown status: shipped"} = GitHub.update_status("7", "shipped")
    assert [] == collect_gh_calls()
  end

  defp collect_gh_calls(acc \\ []) do
    receive do
      {:gh, args} -> collect_gh_calls([args | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
