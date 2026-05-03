import Config

config :factory,
  axiom_token: System.get_env("AXIOM_TOKEN"),
  slack_webhook_url: System.get_env("SLACK_WEBHOOK_URL")
