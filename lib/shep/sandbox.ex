defmodule Shep.Sandbox do
  @moduledoc """
  Vercel Sandbox lifecycle over the `sandbox` CLI.

  A sandbox is the remote twin of a git worktree: somewhere to put a
  checkout and run an agent against it. Names derive from the task id, so
  a resumed or paused task finds its own sandbox again.

  Two capture modes matter here. The CLI echoes every command it runs to
  *stderr*, so anything whose stdout is parsed (`$HOME`, `git status`)
  must not merge the streams — `capture/1` keeps them apart, `run/1`
  merges them for side-effecting calls where the echo is just context.
  """

  require Logger

  @cli "sandbox"

  @doc "The sandbox name for a task. Deterministic, so resume finds it."
  @spec name(Shep.Task.t()) :: String.t()
  def name(%Shep.Task{id: id}) do
    "shep-" <> String.replace(to_string(id), ~r/[^a-zA-Z0-9_-]/, "-")
  end

  @doc "Whether a sandbox with this name is currently alive."
  @spec alive?(String.t()) :: boolean()
  def alive?(sandbox) when is_binary(sandbox) do
    match?({:ok, _}, capture(["exec", sandbox, "--", "true"]))
  end

  @doc """
  Provision a sandbox for a task: create it from the configured snapshot
  with a repo token in its environment, then forward the agent credential.
  """
  @spec provision(Shep.Task.t(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def provision(%Shep.Task{} = task, config) do
    sandbox = name(task)

    with {:ok, snapshot} <- snapshot(config),
         {:ok, token} <- github_token(config) do
      # A same-named sandbox from an earlier attempt would make `create`
      # fail; clearing it first makes provisioning idempotent.
      _ = rm(sandbox)

      args =
        ["create", "--name", sandbox, "--snapshot", snapshot] ++
          ["--timeout", timeout(config), "--tag", tag(config)] ++
          ["--env", "GH_TOKEN=" <> token, "--silent"]

      case run(args) do
        {:ok, _} ->
          Logger.info("Sandbox #{sandbox} created from #{snapshot}")
          with :ok <- forward_credentials(sandbox, config), do: {:ok, sandbox}

        {:error, out} ->
          {:error, "sandbox create failed: #{out}"}
      end
    end
  end

  @doc """
  Clone the tracker repo into the sandbox and cut the task branch.

  Every value travels as a positional argument to `sh -c`, so a branch or
  repo name is never spliced into the script text. `${GH_TOKEN}` expands
  on the remote, so the token never reaches a local log line.
  """
  @spec clone(String.t(), Shep.Task.t(), map()) :: :ok | {:error, String.t()}
  def clone(sandbox, %Shep.Task{} = task, config) do
    repo = get_in(config, ["tracker", "repo"])
    {email, author} = git_identity(config)

    script = """
    set -e
    rm -rf "$1"
    git clone --depth 1 --branch "$2" "https://x-access-token:${GH_TOKEN}@github.com/$3" "$1"
    git -C "$1" checkout -b "$4"
    git -C "$1" config user.email "$5"
    git -C "$1" config user.name "$6"
    """

    argv =
      ["exec", sandbox, "--", "sh", "-c", script, "shep-clone"] ++
        [remote_path(config), task.base_branch, repo, task.branch, email, author]

    case run(argv) do
      {:ok, _} -> :ok
      {:error, out} -> {:error, "clone into sandbox failed: #{out}"}
    end
  end

  @doc "Copy a local file into the sandbox at `dest`."
  @spec cp(String.t(), String.t(), String.t()) :: :ok | {:error, String.t()}
  def cp(sandbox, local_path, dest) do
    case run(["cp", local_path, "#{sandbox}:#{dest}"]) do
      {:ok, _} -> :ok
      {:error, out} -> {:error, out}
    end
  end

  @doc "Destroy a sandbox. Never raises; a missing sandbox is fine."
  @spec rm(String.t()) :: :ok
  def rm(sandbox) when is_binary(sandbox) do
    _ = run(["rm", sandbox])
    :ok
  end

  @doc "The remote checkout path."
  @spec remote_path(map()) :: String.t()
  def remote_path(config) do
    get_in(config, ["sandbox", "remote_path"]) || "/vercel/sandbox/app"
  end

  @doc "Run a CLI command, merging stderr. For side-effecting calls."
  @spec run([String.t()]) :: {:ok, String.t()} | {:error, String.t()}
  def run(args) when is_list(args), do: cmd(args, true)

  @doc "Run a CLI command, keeping stderr separate so stdout can be parsed."
  @spec capture([String.t()]) :: {:ok, String.t()} | {:error, String.t()}
  def capture(args) when is_list(args), do: cmd(args, false)

  # Unmerged stderr would otherwise inherit the daemon's, printing the
  # CLI's echo of every command straight into orchestrator.log. Dropping
  # it needs a shell, so the executable and its args go through argv
  # rather than into the script text.
  @discard_stderr ~S|"$0" "$@" 2>/dev/null|

  defp cmd(args, merge?) do
    case System.find_executable(@cli) do
      nil ->
        {:error, "`#{@cli}` CLI not found on PATH — install it and run `sandbox login`"}

      exe ->
        result =
          if merge? do
            System.cmd(exe, args, stderr_to_stdout: true)
          else
            System.cmd("/bin/sh", ["-c", @discard_stderr, exe | args])
          end

        case result do
          {out, 0} -> {:ok, String.trim(out)}
          {out, code} -> {:error, "exit #{code}: #{String.trim(out)}"}
        end
    end
  end

  defp snapshot(config) do
    case get_in(config, ["sandbox", "snapshot"]) do
      snap when is_binary(snap) and snap != "" -> {:ok, snap}
      _ -> {:error, "sandbox.snapshot is not set — a Vercel task needs a base snapshot"}
    end
  end

  defp timeout(config), do: get_in(config, ["sandbox", "timeout"]) || "45m"
  defp tag(config), do: get_in(config, ["sandbox", "tag"]) || "shep=1"

  # The token reaches the sandbox as an env var, so whatever command
  # produces it can be swapped for one minting a repo-scoped PAT without
  # touching this module.
  defp github_token(config) do
    command = get_in(config, ["sandbox", "github_token_command"]) || "gh auth token"

    case System.cmd("/bin/sh", ["-c", command], stderr_to_stdout: false) do
      {out, 0} ->
        case String.trim(out) do
          "" -> {:error, "sandbox.github_token_command produced no token: #{command}"}
          token -> {:ok, token}
        end

      {out, code} ->
        {:error, "sandbox.github_token_command failed (#{code}): #{String.trim(out)}"}
    end
  end

  # Commits made by the agent need an identity; the snapshot ships none.
  defp git_identity(config) do
    repo = get_in(config, ["workspace", "repo"]) || "."

    {local_config(repo, "user.email") || "shep@users.noreply.github.com",
     local_config(repo, "user.name") || "Shep"}
  end

  defp local_config(repo, key) do
    case System.cmd("git", ["-C", repo, "config", "--get", key], stderr_to_stdout: false) do
      {out, 0} -> String.trim(out) |> nil_if_empty()
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp nil_if_empty(""), do: nil
  defp nil_if_empty(value), do: value

  # The live Claude credential lives in the macOS Keychain; the copy in
  # ~/.claude/.credentials.json is stale and authenticates as nobody.
  # Linux has no Keychain, so the sandbox reads the file store instead.
  defp forward_credentials(sandbox, config) do
    with {:ok, credential} <- keychain_credential(),
         {:ok, home} <- remote_home(sandbox) do
      tmp = Path.join(System.tmp_dir!(), "shep-cred-#{System.unique_integer([:positive])}")
      File.write!(tmp, credential)
      File.chmod!(tmp, 0o600)

      _ = run(["exec", sandbox, "--", "sh", "-c", ~S|mkdir -p "$HOME/.claude"|])
      result = cp(sandbox, tmp, "#{home}/.claude/.credentials.json")
      File.rm(tmp)

      case result do
        :ok ->
          _ =
            run([
              "exec",
              sandbox,
              "--",
              "sh",
              "-c",
              ~S|chmod 600 "$HOME/.claude/.credentials.json"|
            ])

          seed_agent_settings(sandbox, home, config)

        {:error, out} ->
          {:error, "forwarding the Claude credential failed: #{out}"}
      end
    end
  end

  defp keychain_credential do
    case System.cmd("security", ["find-generic-password", "-s", "Claude Code-credentials", "-w"],
           stderr_to_stdout: false
         ) do
      {out, 0} -> {:ok, String.trim(out)}
      _ -> {:error, "no Claude credential in the Keychain — run `claude` and log in once"}
    end
  rescue
    _ -> {:error, "Keychain lookup is macOS-only; cannot forward a Claude credential from here"}
  end

  defp remote_home(sandbox) do
    case capture(["exec", sandbox, "--", "sh", "-c", ~S|printf %s "$HOME"|]) do
      {:ok, home} when home != "" -> {:ok, home}
      {:ok, _} -> {:error, "sandbox returned an empty $HOME"}
      {:error, out} -> {:error, out}
    end
  end

  # Just the two first-run gates — onboarding and the workspace-trust
  # prompt for the checkout — not the whole local config, which carries
  # every project's history.
  defp seed_agent_settings(sandbox, home, config) do
    settings =
      Jason.encode!(%{
        "hasCompletedOnboarding" => true,
        "bypassPermissionsModeAccepted" => true,
        "projects" => %{remote_path(config) => %{"hasTrustDialogAccepted" => true}}
      })

    tmp = Path.join(System.tmp_dir!(), "shep-claude-json-#{System.unique_integer([:positive])}")
    File.write!(tmp, settings)
    result = cp(sandbox, tmp, "#{home}/.claude.json")
    File.rm(tmp)

    case result do
      :ok -> :ok
      {:error, out} -> {:error, "seeding agent settings failed: #{out}"}
    end
  end
end
