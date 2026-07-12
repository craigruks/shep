import Config

config :shep,
  axiom_token: System.get_env("AXIOM_TOKEN"),
  slack_webhook_url: System.get_env("SLACK_WEBHOOK_URL")

# Shepherd a different flock without touching the repo's WORKFLOW.md
if workflow = System.get_env("SHEP_WORKFLOW") do
  config :shep, workflow_path: workflow
end
