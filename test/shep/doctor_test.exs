defmodule Shep.DoctorTest do
  # Installs a :gh_runner adapter, so no concurrent cases. git runs for
  # real against scratch repos and a bare local remote; the operator's
  # global and system git config are shut out so a `gh auth setup-git`
  # on this machine cannot make a failing case pass.
  use ExUnit.Case, async: false

  alias Shep.Doctor
  alias Shep.Doctor.Check

  @isolated [{"GIT_CONFIG_GLOBAL", "/dev/null"}, {"GIT_CONFIG_NOSYSTEM", "1"}]

  setup do
    on_exit(fn -> Application.delete_env(:shep, :gh_runner) end)
    :ok
  end

  defp scratch do
    dir = Path.join(System.tmp_dir!(), "shep_doctor_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp git!(repo, args) do
    {out, code} = System.cmd("git", ["-C", repo | args], env: @isolated, stderr_to_stdout: true)
    assert code == 0, "git #{Enum.join(args, " ")} failed: #{out}"
    out
  end

  # A clone of a bare origin carrying a `staging` branch.
  defp repo_with_remote do
    base = scratch()
    origin = Path.join(base, "origin.git")
    repo = Path.join(base, "repo")
    {_, 0} = System.cmd("git", ["init", "--bare", "-q", origin])
    {_, 0} = System.cmd("git", ["clone", "-q", origin, repo], stderr_to_stdout: true)
    git!(repo, ["config", "user.email", "t@example.com"])
    git!(repo, ["config", "user.name", "T"])
    git!(repo, ["commit", "-q", "--allow-empty", "-m", "initial"])
    git!(repo, ["push", "-q", "origin", "HEAD:refs/heads/staging"])
    repo
  end

  defp doctor(overrides \\ %{}) do
    config = %{
      "workspace" => %{"repo" => Map.get(overrides, :repo, scratch()), "root" => scratch()},
      "tracker" => %{"kind" => "github", "repo" => "o/r"},
      "staging" => %{"base_branch" => "staging"},
      "agent" => %{"command" => "claude"}
    }

    config
    |> Doctor.new(git_env: @isolated)
    |> struct(Map.drop(overrides, [:repo]))
  end

  defp gh(fun), do: Application.put_env(:shep, :gh_runner, fun)

  defp assert_fix(%Check{ok?: false, fix: fix}, expected), do: assert(fix =~ expected)

  describe "gh_auth/1" do
    test "passes when gh reports a login, and fails with gh auth login otherwise" do
      gh(fn ["auth", "status" | _] -> {:ok, "Logged in"} end)
      assert %Check{ok?: true} = Doctor.gh_auth(doctor())

      gh(fn ["auth", "status" | _] -> {:error, "not logged in"} end)
      assert_fix(Doctor.gh_auth(doctor()), "gh auth login")
    end
  end

  describe "push_credentials/1" do
    test "fails with gh auth setup-git when no helper answers" do
      assert_fix(Doctor.push_credentials(doctor(%{repo: repo_with_remote()})), "gh auth setup-git")
    end

    test "passes when a configured helper supplies a credential" do
      repo = repo_with_remote()
      helper = "!f() { echo username=x; echo password=y; }; f"
      git!(repo, ["config", "credential.https://github.com.helper", helper])

      assert %Check{ok?: true} = Doctor.push_credentials(doctor(%{repo: repo}))
    end
  end

  describe "push_remote/1" do
    test "an https origin passes" do
      repo = repo_with_remote()
      git!(repo, ["remote", "set-url", "origin", "https://github.com/o/r.git"])
      assert %Check{ok?: true} = Doctor.push_remote(doctor(%{repo: repo}))
    end

    test "an SSH origin fails with the insteadOf rewrite, which then makes it pass" do
      repo = repo_with_remote()
      git!(repo, ["remote", "set-url", "origin", "git@github.com:o/r.git"])

      check = Doctor.push_remote(doctor(%{repo: repo}))
      assert_fix(check, ~s(url."https://github.com/o/".insteadOf "git@github.com:o/"))

      git!(repo, ["config", "url.https://github.com/o/.insteadOf", "git@github.com:o/"])

      assert %Check{ok?: true, detail: "https://github.com/o/r.git"} =
               Doctor.push_remote(doctor(%{repo: repo}))
    end
  end

  describe "email/1" do
    test "a noreply address passes" do
      repo = repo_with_remote()
      git!(repo, ["config", "user.email", "1+me@users.noreply.github.com"])
      assert %Check{ok?: true} = Doctor.email(doctor(%{repo: repo}))
    end

    test "a public address fails with the gh-derived noreply fix" do
      check = Doctor.email(doctor(%{repo: repo_with_remote()}))
      assert check.detail =~ "t@example.com"
      assert_fix(check, "config user.email \"$(gh api user")
    end
  end

  describe "labels/1" do
    test "all machine labels present and model labels valid: two passes" do
      names = Shep.Tracker.GitHub.machine_labels() ++ ["shep:model:sonnet"]

      gh(fn ["label", "list", "--repo", "o/r" | _] ->
        {:ok, Jason.encode!(Enum.map(names, &%{"name" => &1}))}
      end)

      assert [%Check{ok?: true}, %Check{ok?: true}] = Doctor.labels(doctor())
    end

    test "missing machine labels and a malformed model label each fail with a fix" do
      names = ["shep", "shep:model:bad name", "bug"]
      gh(fn ["label", "list" | _] -> {:ok, Jason.encode!(Enum.map(names, &%{"name" => &1}))} end)

      [missing, model] = Doctor.labels(doctor())
      assert missing.detail =~ "shep:in-progress"
      refute missing.detail =~ "shep, "
      assert_fix(missing, ~s(gh label create "$l" --repo o/r))
      assert_fix(model, ~s(gh label delete "shep:model:bad name" --repo o/r --yes))
    end

    test "a non-github tracker has no labels to check" do
      assert [%Check{ok?: true}] = Doctor.labels(doctor(%{tracker_kind: "memory"}))
    end
  end

  describe "agent_cli/1" do
    test "passes on a CLI that answers --version" do
      cli = Path.join(scratch(), "agent")
      File.write!(cli, "#!/bin/sh\necho 'agent 9.9.9'\n")
      File.chmod!(cli, 0o755)

      assert %Check{ok?: true, detail: detail} = Doctor.agent_cli(doctor(%{agent_command: cli}))
      assert detail =~ "agent 9.9.9"
    end

    test "fails when the CLI is not on PATH, or --version exits non-zero" do
      assert_fix(
        Doctor.agent_cli(doctor(%{agent_command: "claude-#{System.unique_integer()}"})),
        "agent.command"
      )

      cli = Path.join(scratch(), "broken")
      File.write!(cli, "#!/bin/sh\nexit 3\n")
      File.chmod!(cli, 0o755)
      assert %Check{ok?: false, detail: detail} = Doctor.agent_cli(doctor(%{agent_command: cli}))
      assert detail =~ "exited 3"
    end
  end

  describe "workspace_root/1" do
    test "an existing writable root passes; a missing one fails with mkdir -p" do
      assert %Check{ok?: true} = Doctor.workspace_root(doctor())

      missing = Path.join(scratch(), "nope")
      assert_fix(Doctor.workspace_root(doctor(%{root: missing})), "mkdir -p #{missing}")
    end

    test "a read-only root fails with chmod" do
      root = scratch()
      File.chmod!(root, 0o555)
      on_exit(fn -> File.chmod!(root, 0o755) end)

      assert_fix(Doctor.workspace_root(doctor(%{root: root})), "chmod u+w #{root}")
    end
  end

  describe "workspace_repo/1 and base_branch/1" do
    test "a clone whose origin carries the base branch passes both" do
      d = doctor(%{repo: repo_with_remote()})
      assert %Check{ok?: true} = Doctor.workspace_repo(d)
      assert %Check{ok?: true} = Doctor.base_branch(d)
    end

    test "an unreachable origin is reported as such, not as a missing branch" do
      repo = repo_with_remote()
      git!(repo, ["remote", "set-url", "origin", Path.join(scratch(), "gone.git")])

      check = Doctor.base_branch(doctor(%{repo: repo}))
      assert check.detail =~ "cannot reach origin"
      assert_fix(check, "ls-remote origin")
    end

    test "a plain directory is not a clone" do
      assert_fix(Doctor.workspace_repo(doctor()), "git clone https://github.com/o/r.git")
    end

    test "a base branch absent from origin fails with the push that creates it" do
      d = doctor(%{repo: repo_with_remote(), base_branch: "release"})
      assert_fix(Doctor.base_branch(d), "push origin HEAD:refs/heads/release")
    end
  end

  describe "run/2, ok?/1 and format/1" do
    test "every check reports one line, with the fix under each failure" do
      gh(fn _ -> {:error, "offline"} end)

      config = %{
        "workspace" => %{"repo" => scratch(), "root" => scratch()},
        "tracker" => %{"kind" => "github", "repo" => "o/r"},
        "agent" => %{"command" => "no-such-agent-#{System.unique_integer([:positive])}"}
      }

      checks = Doctor.run(config, git_env: @isolated)
      refute Doctor.ok?(checks)

      lines = checks |> Doctor.format() |> String.split("\n")
      assert Enum.count(lines, &String.starts_with?(&1, ["✓ ", "✗ "])) == length(checks)

      assert Enum.count(lines, &String.starts_with?(&1, "    fix: ")) ==
               Enum.count(checks, &(not &1.ok?))
    end

    test "ok?/1 holds only when every check passed" do
      pass = %Check{name: "a", ok?: true, detail: ""}
      assert Doctor.ok?([pass, pass])
      refute Doctor.ok?([pass, %{pass | ok?: false}])
    end
  end
end
