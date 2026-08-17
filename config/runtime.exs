import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/beerocracy start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :beerocracy, BeerocracyWeb.Endpoint, server: true
end

config :beerocracy, BeerocracyWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# Where the forecast above the weekdays is measured. Defaults to Bern. Only the
# keys actually given are set here; `config/2` deep-merges keyword lists, so the
# rest of the defaults from config.exs survive.
coordinate = fn name ->
  case System.get_env(name) do
    nil -> nil
    value -> value |> Float.parse() |> then(fn {number, _rest} -> number end)
  end
end

weather_overrides =
  [
    latitude: coordinate.("WEATHER_LATITUDE"),
    longitude: coordinate.("WEATHER_LONGITUDE"),
    timezone: System.get_env("WEATHER_TIMEZONE"),
    enabled: if(System.get_env("WEATHER") == "off", do: false)
  ]
  |> Enum.reject(fn {_key, value} -> is_nil(value) end)

if weather_overrides != [] do
  config :beerocracy, :weather, weather_overrides
end

# Point the "add a place" links at your own fork.
if repo_url = System.get_env("REPO_URL") do
  config :beerocracy, :repo_url, repo_url
end

if repo_branch = System.get_env("REPO_BRANCH") do
  config :beerocracy, :repo_branch, repo_branch
end

if config_env() == :prod do
  # The container mounts a volume at /data, so the ballots survive a redeploy.
  database_path = System.get_env("DATABASE_PATH") || "/data/beerocracy.db"

  config :beerocracy, Beerocracy.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5"),
    # SQLite lets one writer in at a time. A generous busy timeout is what keeps
    # a room full of people swiping at once from seeing "database is locked".
    busy_timeout: 5_000

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  # Beerocracy is usually parked behind a reverse proxy on somebody's own
  # domain, so the public URL is configured rather than assumed. Plain http on
  # a home network works too: set PHX_SCHEME=http and PHX_URL_PORT=80.
  host = System.get_env("PHX_HOST") || "localhost"
  scheme = System.get_env("PHX_SCHEME") || "https"

  # Phoenix checks the browser's Origin header against this host before it will
  # accept the LiveView socket. Get it wrong behind a reverse proxy and the page
  # still renders — it just quietly never connects, so no swiping and no live
  # tally, with nothing in the log to say why. Worth being loud about.
  if host == "localhost" do
    IO.puts(:stderr, """

    ┌──────────────────────────────────────────────────────────────────────┐
    │  PHX_HOST is not set, so it defaults to "localhost".                 │
    │                                                                      │
    │  If you reach Beerocracy on any other name — through Caddy, nginx,   │
    │  or just an IP on your network — set it to that name, or the live    │
    │  parts of the page will silently refuse to connect:                  │
    │                                                                      │
    │      PHX_HOST=beer.example.com                                       │
    └──────────────────────────────────────────────────────────────────────┘
    """)
  end

  url_port =
    String.to_integer(
      System.get_env("PHX_URL_PORT") || if(scheme == "https", do: "443", else: "80")
    )

  config :beerocracy, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :beerocracy, BeerocracyWeb.Endpoint,
    url: [host: host, port: url_port, scheme: scheme],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :beerocracy, BeerocracyWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :beerocracy, BeerocracyWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
