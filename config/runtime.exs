import Config

config :shep,
  axiom_token: System.get_env("AXIOM_TOKEN"),
  slack_webhook_url: System.get_env("SLACK_WEBHOOK_URL")

# Shepherd a different flock without touching the repo's WORKFLOW.md.
# Never in test: the suite must stay hermetic, not inherit the config of
# whatever daemon the operator's shell is running (a dogfood WORKFLOW
# with max_concurrent: 1 turns orchestrator tests into order-dependent
# flakes).
if config_env() != :test do
  if workflow = System.get_env("SHEP_WORKFLOW") do
    config :shep, workflow_path: workflow
  end
end
