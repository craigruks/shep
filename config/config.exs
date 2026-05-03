import Config

config :factory, workflow_path: "WORKFLOW.md"

config :logger, :console,
  format: "$time [$level] $metadata$message\n",
  metadata: [:task_id, :task_type],
  device: :standard_error

import_config "#{config_env()}.exs"
