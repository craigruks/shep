defmodule Shep.Workspace do
  @moduledoc """
  Where a task's code lives, and where its commands run.

  Two locations: a local git worktree (the default) and a Vercel sandbox.
  Everything the run loop does to a checkout — prepare it, run the agent
  against it, run the verify command, run git, tear it down — goes through
  here, so the agent runner never branches on location itself.

  The agent invocation is the whole trick: `sandbox exec` streams output
  line by line and propagates the exit code, so a remote turn is the same
  Port with a different command. `Shep.AgentRunner.Exec` is untouched.
  """

  require Logger

  alias Shep.Sandbox

  @enforce_keys [:location, :path]
  defstruct [:location, :path, :sandbox]

  @type location :: :local | :vercel
  @type t :: %__MODULE__{
          location: location(),
          path: String.t(),
          sandbox: String.t() | nil
        }

  # `sh -c script name file cmd args…`: read the prompt out of a file the
  # sandbox already holds, then exec the agent with it as one argument.
  # Keeping the prompt off the command line matters because the CLI echoes
  # every command it runs — an echoed issue body would land back in the
  # agent's own output stream.
  @prompt_script ~S|f="$1"; shift; exec "$@" -p "$(cat "$f")"|

  @doc "A workspace for an existing local checkout."
  @spec local(String.t()) :: t()
  def local(path) when is_binary(path), do: %__MODULE__{location: :local, path: path}

  @doc "Prepare a fresh workspace for a task."
  @spec prepare(Shep.Task.t(), map()) :: {:ok, t()} | {:error, String.t()}
  def prepare(%Shep.Task{location: :vercel, agent: :codex}, _config) do
    {:error, "codex is not supported in a sandbox: no Codex credential is forwarded (see #65)"}
  end

  def prepare(%Shep.Task{location: :vercel} = task, config) do
    with {:ok, sandbox} <- Sandbox.provision(task, config),
         :ok <- Sandbox.clone(sandbox, task, config) do
      {:ok, %__MODULE__{location: :vercel, path: Sandbox.remote_path(config), sandbox: sandbox}}
    end
  end

  def prepare(%Shep.Task{} = task, config) do
    root = get_in(config, ["workspace", "root"])
    repo = get_in(config, ["workspace", "repo"]) || "."
    File.mkdir_p!(root)

    case Shep.Worktree.create(task.branch, task.base_branch, root, repo) do
      {:ok, path} -> {:ok, %__MODULE__{location: :local, path: path}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Re-attach to the workspace of a task being resumed.

  A local task re-attaches to the preserved worktree path; a sandbox task
  re-attaches by name, and fails cleanly if the sandbox has since expired
  (its checkout, session, and branch all die with it).
  """
  @spec reattach(Shep.Task.t(), String.t() | nil, map()) :: {:ok, t()} | {:error, String.t()}
  def reattach(%Shep.Task{location: :vercel} = task, _path, config) do
    sandbox = Sandbox.name(task)

    if Sandbox.alive?(sandbox) do
      {:ok, %__MODULE__{location: :vercel, path: Sandbox.remote_path(config), sandbox: sandbox}}
    else
      {:error, "sandbox #{sandbox} is gone (expired or removed) — its work cannot be resumed"}
    end
  end

  def reattach(%Shep.Task{}, path, _config) when is_binary(path) do
    if File.dir?(path) do
      {:ok, %__MODULE__{location: :local, path: path}}
    else
      {:error, "resume worktree not found: #{path}"}
    end
  end

  @doc """
  The executable, argv, and local working directory for one agent turn.

  Local runs resolve the agent on this machine; sandbox runs resolve the
  `sandbox` CLI instead and hand it the agent name to resolve remotely.
  """
  @spec agent_spec(t(), String.t(), [String.t()]) ::
          {:ok, String.t(), [String.t()], String.t()} | {:error, String.t()}
  def agent_spec(%__MODULE__{location: :vercel} = workspace, agent_cmd, args) do
    case Shep.AgentRunner.Exec.resolve_executable("sandbox") do
      nil ->
        {:error, "sandbox"}

      exe ->
        {:ok, exe, remote_argv(workspace, agent_cmd, args), System.tmp_dir!()}
    end
  end

  def agent_spec(%__MODULE__{path: path}, agent_cmd, args) do
    case Shep.AgentRunner.Exec.resolve_executable(agent_cmd) do
      nil -> {:error, agent_cmd}
      exe -> {:ok, exe, args, path}
    end
  end

  defp remote_argv(workspace, agent_cmd, args) do
    case split_prompt(args) do
      {leading, nil} ->
        remote_argv(workspace, agent_cmd, leading, nil)

      {leading, prompt} ->
        remote_argv(workspace, agent_cmd, leading, stage_prompt(workspace, prompt))
    end
  end

  @doc """
  The `sandbox exec` argv for one agent turn, given an already-staged
  prompt file (or nil for a turn that carries no prompt).

  Split out from staging so the command shape is inspectable — and
  testable — without a live sandbox.
  """
  @spec remote_argv(t(), String.t(), [String.t()], String.t() | nil) :: [String.t()]
  def remote_argv(%__MODULE__{sandbox: sandbox, path: path}, agent_cmd, args, nil) do
    ["exec", sandbox, "-w", path, "--", agent_cmd | args]
  end

  def remote_argv(%__MODULE__{sandbox: sandbox, path: path}, agent_cmd, args, prompt_file) do
    ["exec", sandbox, "-w", path, "--"] ++
      ["sh", "-c", @prompt_script, "shep-agent", prompt_file, agent_cmd | args]
  end

  # Claude's arg builders put the prompt last, behind `-p`.
  defp split_prompt(args) do
    case Enum.split(args, -2) do
      {leading, ["-p", prompt]} -> {leading, prompt}
      _ -> {args, nil}
    end
  end

  defp stage_prompt(%{sandbox: sandbox}, prompt) do
    remote = "/tmp/#{sandbox}.prompt"
    local = Path.join(System.tmp_dir!(), "#{sandbox}-#{System.unique_integer([:positive])}.prompt")
    File.write!(local, prompt)
    _ = Sandbox.cp(sandbox, local, remote)
    File.rm(local)
    remote
  end

  @doc "Run a shell command in the workspace. Returns output either way."
  @spec shell(t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def shell(%__MODULE__{location: :vercel, sandbox: sandbox, path: path}, command) do
    Sandbox.run(["exec", sandbox, "-w", path, "--", "sh", "-lc", command])
  end

  def shell(%__MODULE__{path: path}, command) do
    case System.cmd("/bin/sh", ["-c", command], cd: path, stderr_to_stdout: true) do
      {out, 0} -> {:ok, out}
      {out, _code} -> {:error, out}
    end
  end

  @doc """
  Run git in the workspace checkout.

  Output is merged stderr-into-stdout for logging, and a sandbox prefixes
  it with the CLI's echo of the command — use `Sandbox.capture/1` when
  stdout has to be parsed, as `dirty?/1` does.
  """
  @spec git(t(), [String.t()]) :: {:ok, String.t()} | {:error, String.t()}
  def git(%__MODULE__{location: :vercel, sandbox: sandbox, path: path}, args) do
    Sandbox.run(["exec", sandbox, "-w", path, "--", "git" | args])
  end

  def git(%__MODULE__{path: path}, args) do
    case System.cmd("git", ["-C", path | args], stderr_to_stdout: true) do
      {out, 0} -> {:ok, out}
      {out, _code} -> {:error, out}
    end
  end

  @doc "Whether the checkout has uncommitted changes. Unreadable counts as dirty."
  @spec dirty?(t()) :: boolean()
  def dirty?(%__MODULE__{location: :vercel, sandbox: sandbox, path: path}) do
    case Sandbox.capture(["exec", sandbox, "-w", path, "--", "git", "status", "--porcelain"]) do
      {:ok, out} -> String.trim(out) != ""
      {:error, _} -> true
    end
  end

  def dirty?(%__MODULE__{path: path}), do: Shep.Worktree.has_uncommitted_changes?(path)

  @doc """
  Where trusted prompt templates expand their shell blocks.

  Sandbox tasks expand against the local checkout: the templates probe
  repo context (a CLAUDE.md, a file listing) and the local repo is the
  same codebase, which keeps expansion off the remote hot path.
  """
  @spec prompt_cwd(t(), map()) :: String.t()
  def prompt_cwd(%__MODULE__{location: :vercel}, config) do
    get_in(config, ["workspace", "repo"]) || File.cwd!()
  end

  def prompt_cwd(%__MODULE__{path: path}, _config), do: path

  @doc "Run the configured lifecycle hook inside the workspace."
  @spec run_hook(t(), map(), String.t()) :: :ok
  def run_hook(%__MODULE__{location: :vercel} = workspace, config, event) do
    case get_in(config, ["hooks", event]) do
      command when is_binary(command) and command != "" ->
        case shell(workspace, command) do
          {:ok, _} ->
            :ok

          {:error, out} ->
            Logger.warning("Hook #{event} failed in sandbox: #{Shep.Goal.tail(out, 400)}")
        end

        :ok

      _ ->
        :ok
    end
  end

  def run_hook(%__MODULE__{path: path}, config, event) do
    Shep.Hooks.run_lifecycle(config, event, path)
  end

  @doc """
  Tear down the workspace once a task is over.

  A local worktree is preserved after a failure: it is free to keep and
  it is where you go to diagnose. A sandbox is not free, so a failed one
  is rescued rather than kept — the task branch is pushed so the agent's
  commits survive as a remote branch, then the machine is destroyed. Set
  `sandbox.keep_on_failure` to hold it open for live debugging instead,
  remembering it still dies at its own timeout.
  """
  @spec cleanup(t(), Shep.Task.t(), struct(), map()) :: :ok
  def cleanup(
        %__MODULE__{location: :vercel, sandbox: sandbox} = workspace,
        %Shep.Task{} = task,
        %Shep.Completion.Failed{},
        config
      ) do
    if get_in(config, ["sandbox", "keep_on_failure"]) do
      Logger.info("Keeping sandbox #{sandbox} for diagnosis (expires at its timeout)")
    else
      rescue_branch(workspace, task)
      Sandbox.rm(sandbox)
      Logger.info("Removed sandbox after failure: #{sandbox}")
    end

    :ok
  end

  def cleanup(%__MODULE__{location: :vercel, sandbox: sandbox}, _task, _completion, _config) do
    Sandbox.rm(sandbox)
    Logger.info("Removed sandbox: #{sandbox}")
    :ok
  end

  def cleanup(%__MODULE__{path: path}, _task, %Shep.Completion.Failed{}, _config) do
    Logger.info("Preserving worktree for failed task: #{path}")
    :ok
  end

  def cleanup(%__MODULE__{path: path}, _task, _completion, config) do
    repo = get_in(config, ["workspace", "repo"]) || "."
    Shep.Worktree.remove(path, repo)
    :ok
  end

  # Best effort by design: the sandbox is going away either way, and a
  # failed task often has nothing to push. CI runs on pull requests and
  # pushes to main, so a task branch with no PR triggers nothing.
  defp rescue_branch(workspace, %Shep.Task{branch: branch}) do
    case git(workspace, ["push", "origin", branch]) do
      {:ok, _} ->
        Logger.info("Pushed #{branch} before releasing the sandbox")

      {:error, out} ->
        Logger.info("Nothing rescued from #{branch}: #{Shep.Goal.tail(out, 200)}")
    end
  end

  @doc "Human-readable location of the workspace, for logs and status."
  @spec describe(t()) :: String.t()
  def describe(%__MODULE__{location: :vercel, sandbox: sandbox, path: path}),
    do: "vercel:#{sandbox}:#{path}"

  def describe(%__MODULE__{path: path}), do: path
end
