defmodule Shep.Completion.Complete do
  @moduledoc "Agent completed the task successfully."
  @enforce_keys [:summary]
  defstruct [:summary, verify: []]

  @type t :: %__MODULE__{summary: String.t(), verify: [String.t()]}
end

defmodule Shep.Completion.Failed do
  @moduledoc "Agent could not complete the task."
  @enforce_keys [:reason, :recoverable]
  defstruct [:reason, :recoverable]

  @type t :: %__MODULE__{reason: String.t(), recoverable: boolean()}
end

defmodule Shep.Completion.Continue do
  @moduledoc "Agent wants another turn."
  defstruct []

  @type t :: %__MODULE__{}
end

defmodule Shep.IterationResult do
  @moduledoc "Result of a single agent CLI invocation."
  @enforce_keys [:stdout, :stderr, :exit_code, :completion, :duration_ms]
  defstruct [:stdout, :stderr, :exit_code, :completion, :duration_ms]

  @type completion :: Shep.Completion.Complete.t() | Shep.Completion.Failed.t() | nil

  @type t :: %__MODULE__{
          stdout: String.t(),
          stderr: String.t(),
          exit_code: non_neg_integer(),
          completion: completion(),
          duration_ms: non_neg_integer()
        }
end

defmodule Shep.RunResult do
  @moduledoc "Result of a full agent run (one or more iterations)."
  @enforce_keys [:iterations, :completion, :branch_name, :worktree_path, :duration_ms]
  defstruct [
    :iterations,
    :completion,
    :branch_name,
    :worktree_path,
    :duration_ms,
    :pr_url,
    commits: []
  ]

  @type completion ::
          Shep.Completion.Complete.t()
          | Shep.Completion.Failed.t()
          | Shep.Completion.Continue.t()

  @type t :: %__MODULE__{
          iterations: [Shep.IterationResult.t()],
          completion: completion(),
          branch_name: String.t(),
          worktree_path: String.t(),
          duration_ms: non_neg_integer(),
          pr_url: String.t() | nil,
          commits: [String.t()]
        }
end

defmodule Shep.Task do
  @moduledoc "A task to be executed by an agent."
  @enforce_keys [:id, :branch, :prompt]
  defstruct [
    :id,
    :branch,
    :prompt,
    :type,
    :depends_on,
    agent: :claude,
    base_branch: "staging",
    prompt_args: %{},
    no_merge: false,
    demo: false
  ]

  @type agent :: :claude | :codex

  @type t :: %__MODULE__{
          id: String.t(),
          branch: String.t(),
          base_branch: String.t(),
          prompt: String.t(),
          prompt_args: %{String.t() => String.t()},
          type: String.t() | nil,
          depends_on: [String.t()] | nil,
          agent: agent(),
          no_merge: boolean(),
          demo: boolean()
        }
end

defmodule Shep.PausedTask do
  @moduledoc "A task that has been paused for human intervention."
  @enforce_keys [:task, :worktree_path, :paused_at]
  defstruct [:task, :worktree_path, :paused_at, :session_name]

  @type t :: %__MODULE__{
          task: Shep.Task.t(),
          worktree_path: String.t(),
          paused_at: integer(),
          session_name: String.t() | nil
        }
end
