defmodule Shep.Doctor do
  @moduledoc """
  Pre-flight checks for the traps that otherwise surface only when the
  daemon first pushes: push auth a nohup'd process cannot reach, an
  SSH-only remote, a GH007-rejected `user.email`, labels the tracker
  lacks, a missing agent CLI, an unusable workspace.

  `run/2` returns one `Shep.Doctor.Check` per check; each failure carries
  the exact command that fixes it. Read-only: nothing here changes git
  config, labels, or the filesystem beyond a probe file it removes.

  `gh` goes through the `Shep.GH` seam; git runs for real with prompts
  disabled, and `:git_env` isolates it from the operator's git config.
  """

  alias Shep.Doctor.Check
  alias Shep.Tracker.GitHub

  @enforce_keys [:repo, :root, :tracker_kind, :tracker_repo, :base_branch, :agent_command]
  defstruct @enforce_keys ++ [workflow: "WORKFLOW.md", git_env: []]

  @type t :: %__MODULE__{}

  @noreply ~r/@users\.noreply\.github\.com$/
  @ssh_github ~r/^(?:ssh:\/\/)?git@github\.com[:\/]([^\/]+)\//
  @noreply_email ~S|"$(gh api user --jq '"\(.id)+\(.login)@users.noreply.github.com"')"|

  @doc """
  Build the check context from a validated config.

  Options: `:workflow` (the path named in fix commands), `:git_env`
  (extra environment for every git call).
  """
  @spec new(map(), keyword()) :: t()
  def new(config, opts \\ []) when is_map(config) and is_list(opts) do
    %__MODULE__{
      repo: get_in(config, ["workspace", "repo"]) |> Path.expand(),
      root: get_in(config, ["workspace", "root"]),
      tracker_kind: get_in(config, ["tracker", "kind"]),
      tracker_repo: get_in(config, ["tracker", "repo"]),
      base_branch: get_in(config, ["staging", "base_branch"]) || "staging",
      agent_command: get_in(config, ["agent", "command"]) || "claude",
      workflow: Keyword.get(opts, :workflow, "WORKFLOW.md"),
      git_env: Keyword.get(opts, :git_env, [])
    }
  end

  @doc "Run every check against `config`, in the order they are reported."
  @spec run(map(), keyword()) :: [Check.t()]
  def run(config, opts \\ []) when is_map(config) do
    d = new(config, opts)

    [gh_auth(d), push_credentials(d), push_remote(d), email(d)] ++
      labels(d) ++ [agent_cli(d), workspace_root(d), workspace_repo(d), base_branch(d)]
  end

  @doc "True only when every check passed."
  @spec ok?([Check.t()]) :: boolean()
  def ok?(checks) when is_list(checks), do: Enum.all?(checks, & &1.ok?)

  @doc "`gh` is logged in to github.com."
  @spec gh_auth(t()) :: Check.t()
  def gh_auth(%__MODULE__{}) do
    case Shep.GH.run(["auth", "status", "--hostname", "github.com"]) do
      {:ok, _} -> pass("gh authenticated", "github.com")
      {:error, _} -> fail("gh authenticated", "not logged in to github.com", "gh auth login")
    end
  end

  @doc """
  git can get GitHub https credentials with no human present.

  Asks the configured helpers exactly as a push would (`git credential
  fill`), with terminal and askpass prompts disabled. The credential
  itself is discarded unread.
  """
  @spec push_credentials(t()) :: Check.t()
  def push_credentials(%__MODULE__{} = d) do
    env = [{"GIT_ASKPASS", nil}, {"SSH_ASKPASS", nil} | git_env(d)]
    # `credential fill` reads its query on stdin, which System.cmd cannot feed.
    script = ~S(printf 'protocol=https\nhost=github.com\n\n' | git -C "$1" credential fill)

    case System.cmd("sh", ["-c", script, "sh", d.repo], env: env, stderr_to_stdout: true) do
      {_, 0} -> pass("push credentials", "a helper answers for github.com unprompted")
      {_, _} -> fail("push credentials", "no helper answers for github.com", "gh auth setup-git")
    end
  end

  @doc "pushes to `origin` go over https, directly or via an `insteadOf` rewrite."
  @spec push_remote(t()) :: Check.t()
  def push_remote(%__MODULE__{} = d) do
    case git(d, ["remote", "get-url", "--push", "origin"]) do
      {"https://" <> _ = url, 0} ->
        pass("push remote", url)

      {url, 0} ->
        fail(
          "push remote",
          "#{url} is not https; SSH agents do not reach the daemon",
          https_fix(d, url)
        )

      {_, _} ->
        fail("push remote", "no origin remote in #{d.repo}", set_url_fix(d))
    end
  end

  defp https_fix(d, url) do
    case Regex.run(@ssh_github, url) do
      [_, owner] ->
        ~s(git -C #{d.repo} config url."https://github.com/#{owner}/".insteadOf "git@github.com:#{owner}/")

      nil ->
        set_url_fix(d)
    end
  end

  defp set_url_fix(d), do: "git -C #{d.repo} remote add origin #{github_url(d)}"

  defp github_url(d), do: "https://github.com/#{d.tracker_repo || "<owner>/<repo>"}.git"

  @doc "`user.email` is a GitHub noreply address, so GH007 cannot reject a push."
  @spec email(t()) :: Check.t()
  def email(%__MODULE__{} = d) do
    fix = "git -C #{d.repo} config user.email #{@noreply_email}"

    case git(d, ["config", "user.email"]) do
      {email, 0} ->
        if Regex.match?(@noreply, email),
          do: pass("user.email", email),
          else: fail("user.email", "#{email} is not a noreply address (GH007)", fix)

      {_, _} ->
        fail("user.email", "unset in #{d.repo}", fix)
    end
  end

  @doc """
  The label checks: every machine label exists on `tracker.repo`, and
  every `shep:model:*` label defined there is a valid model name.
  """
  @spec labels(t()) :: [Check.t()]
  def labels(%__MODULE__{tracker_kind: kind}) when kind != "github",
    do: [pass("labels", "tracker.kind #{kind}: no labels to check")]

  def labels(%__MODULE__{tracker_repo: nil} = d),
    do: [fail("labels", "tracker.repo is not set", "$EDITOR #{d.workflow}")]

  def labels(%__MODULE__{tracker_repo: repo}) do
    case Shep.GH.run(["label", "list", "--repo", repo, "--limit", "500", "--json", "name"]) do
      {:ok, json} ->
        names = json |> Jason.decode!() |> Enum.map(& &1["name"])
        [machine_labels(repo, names), model_labels(repo, names)]

      {:error, reason} ->
        [fail("labels", "cannot list labels on #{repo}: #{reason}", "gh auth login")]
    end
  end

  defp machine_labels(repo, names) do
    case GitHub.machine_labels() -- names do
      [] ->
        pass("labels", "all #{length(GitHub.machine_labels())} on #{repo}")

      missing ->
        fail(
          "labels",
          "missing on #{repo}: #{Enum.join(missing, ", ")}",
          "for l in #{Enum.join(missing, " ")}; do gh label create \"$l\" --repo #{repo}; done"
        )
    end
  end

  defp model_labels(repo, names) do
    prefix = GitHub.model_label_prefix()

    bad =
      for name <- names,
          String.starts_with?(name, prefix),
          not GitHub.valid_model?(String.replace_prefix(name, prefix, "")),
          do: name

    case bad do
      [] ->
        pass("model labels", "every #{prefix}* label names a model")

      bad ->
        fail(
          "model labels",
          "not a model name: #{Enum.join(bad, ", ")}",
          Enum.map_join(bad, " && ", &~s(gh label delete "#{&1}" --repo #{repo} --yes))
        )
    end
  end

  @doc "`agent.command` is on PATH and answers `--version`."
  @spec agent_cli(t()) :: Check.t()
  def agent_cli(%__MODULE__{agent_command: cmd} = d) do
    case System.find_executable(cmd) do
      nil -> fail("agent CLI", "#{cmd} is not on PATH", install_fix(cmd, d))
      exe -> agent_version(cmd, exe, d)
    end
  end

  defp agent_version(cmd, exe, d) do
    case System.cmd(exe, ["--version"], stderr_to_stdout: true) do
      {out, 0} ->
        pass("agent CLI", "#{cmd} #{out |> String.split("\n") |> hd() |> String.trim()}")

      {out, code} ->
        fail(
          "agent CLI",
          "#{cmd} --version exited #{code}: #{String.trim(out)}",
          install_fix(cmd, d)
        )
    end
  end

  defp install_fix("claude", _d), do: "npm install -g @anthropic-ai/claude-code"
  defp install_fix("codex", _d), do: "npm install -g @openai/codex"
  defp install_fix(_cmd, d), do: "$EDITOR #{d.workflow}  # point agent.command at an installed CLI"

  @doc "`workspace.root` exists and a file can be written in it."
  @spec workspace_root(t()) :: Check.t()
  def workspace_root(%__MODULE__{root: root}) do
    probe = Path.join(root, ".shep_doctor_#{System.unique_integer([:positive])}")

    cond do
      not File.dir?(root) ->
        fail("workspace.root", "#{root} does not exist", "mkdir -p #{root}")

      File.write(probe, "") != :ok ->
        fail("workspace.root", "#{root} is not writable", "chmod u+w #{root}")

      true ->
        File.rm(probe)
        pass("workspace.root", root)
    end
  end

  @doc "`workspace.repo` is a git clone."
  @spec workspace_repo(t()) :: Check.t()
  def workspace_repo(%__MODULE__{} = d) do
    case git(d, ["rev-parse", "--git-dir"]) do
      {_, 0} ->
        pass("workspace.repo", d.repo)

      {_, _} ->
        fail(
          "workspace.repo",
          "#{d.repo} is not a git clone",
          "git clone #{github_url(d)} #{d.repo}"
        )
    end
  end

  @doc "`staging.base_branch` exists on `origin` (asked of the remote, not a stale ref)."
  @spec base_branch(t()) :: Check.t()
  def base_branch(%__MODULE__{base_branch: base} = d) do
    case git(d, ["ls-remote", "--exit-code", "--heads", "origin", base]) do
      {_, 0} ->
        pass("base branch", "#{base} on origin")

      # --exit-code: 2 means origin answered and has no such branch.
      {_, 2} ->
        fail(
          "base branch",
          "#{base} not found on origin",
          "git -C #{d.repo} push origin HEAD:refs/heads/#{base}"
        )

      {out, _} ->
        fail(
          "base branch",
          "cannot reach origin: #{out |> String.split("\n") |> List.last()}",
          "git -C #{d.repo} ls-remote origin  # fix the push remote and credentials first"
        )
    end
  end

  @doc "Render checks as one line per check, the fix indented under each failure."
  @spec format([Check.t()]) :: String.t()
  def format(checks) when is_list(checks), do: Enum.map_join(checks, "\n", &format_check/1)

  defp format_check(%Check{ok?: true} = c), do: "✓ #{c.name}: #{c.detail}"
  defp format_check(%Check{ok?: false} = c), do: "✗ #{c.name}: #{c.detail}\n    fix: #{c.fix}"

  defp pass(name, detail), do: %Check{name: name, ok?: true, detail: detail}
  defp fail(name, detail, fix), do: %Check{name: name, ok?: false, detail: detail, fix: fix}

  defp git_env(d), do: [{"GIT_TERMINAL_PROMPT", "0"} | d.git_env]

  defp git(d, args) do
    {out, code} = System.cmd("git", ["-C", d.repo | args], env: git_env(d), stderr_to_stdout: true)
    {String.trim(out), code}
  rescue
    ErlangError -> {"", 1}
  end
end
