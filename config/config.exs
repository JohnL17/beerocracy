# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :beerocracy,
  ecto_repos: [Beerocracy.Repo],
  ash_domains: [Beerocracy.Voting, Beerocracy.Accounts],
  generators: [timestamp_type: :utc_datetime]

# The catalogue of drinking establishments lives in a YAML file so that adding a
# place is a pull request, not a deployment concern. The repository is recorded
# here so the app can link people straight at the file they need to edit —
# override REPO_URL if you fork it.
config :beerocracy,
  places_file: "places.yml",
  repo_url: "https://github.com/anehx/beerocracy",
  repo_branch: "main"

# The forecast shown above each weekday. Coordinates default to Bern; override
# them if you drink somewhere else. Set `enabled: false` to switch the whole
# thing off — the tiles simply lose their weather line.
config :beerocracy, :weather,
  latitude: 46.948,
  longitude: 7.4474,
  timezone: "Europe/Zurich",
  refresh_every: :timer.hours(1)

# Signing in goes through a GitHub OAuth application. Register one at
# https://github.com/settings/developers with the callback URL
# <your host>/auth/user/github/callback, then set GITHUB_CLIENT_ID and
# GITHUB_CLIENT_SECRET. `redirect_uri` is the base of the auth routes, not the
# callback itself. Without credentials the app still runs — nobody can sign in,
# so nobody can vote, and the sheet says as much.
config :beerocracy, :github,
  client_id: nil,
  client_secret: nil,
  redirect_uri: nil

# Who may look behind the counter, by GitHub handle. Deliberately empty by
# default: an app that ships with an admin is an app with somebody else's admin.
# Set ADMIN_USERS to a comma-separated list of handles.
config :beerocracy, admins: []

# The hours a beer actually happens in. The forecast summarises exactly these,
# and a place whose opening hours miss them is no use however good the beer is.
config :beerocracy, :drinking_window, from: 16, to: 22

config :ash,
  default_page_type: :keyset,
  policies: [no_filter_static_forbidden_reads?: false]

# Configure the endpoint
config :beerocracy, BeerocracyWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: BeerocracyWeb.ErrorHTML, json: BeerocracyWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Beerocracy.PubSub,
  live_view: [signing_salt: "jw5XENCm"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  beerocracy: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  beerocracy: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
