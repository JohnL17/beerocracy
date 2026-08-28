[
  import_deps: [
    :ecto,
    :ecto_sql,
    :phoenix,
    :ash,
    :ash_sqlite,
    :ash_authentication,
    :ash_authentication_phoenix
  ],
  subdirectories: ["priv/*/migrations"],
  # Spark.Formatter is deliberately absent: it only reorders DSL sections, and
  # it formats differently depending on MIX_ENV, so `mix format` in a test shell
  # would fight `mix format` in a dev one. `import_deps` above is what keeps the
  # Ash DSL free of parentheses, and that works in every environment.
  plugins: [Phoenix.LiveView.HTMLFormatter],
  inputs: ["*.{heex,ex,exs}", "{config,lib,test}/**/*.{heex,ex,exs}", "priv/*/seeds.exs"]
]
