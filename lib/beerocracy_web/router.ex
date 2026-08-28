defmodule BeerocracyWeb.Router do
  use BeerocracyWeb, :router
  use AshAuthentication.Phoenix.Router

  import AshAuthentication.Phoenix.Plug, only: [load_from_session: 2]
  import BeerocracyWeb.UserAuth
  import Phoenix.LiveDashboard.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {BeerocracyWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :load_from_session
    plug :fetch_current_scope
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", BeerocracyWeb do
    pipe_through :browser

    # The sheet is readable by anybody — you only have to say who you are to
    # make a mark on it — so there is one live session and no redirect for the
    # signed out.
    ash_authentication_live_session :ballot,
      on_mount: [{BeerocracyWeb.UserAuth, :mount_current_scope}] do
      live "/", BallotLive, :index
      live "/places", PlacesLive, :index
      live "/rules", RulesLive, :index
    end

    # Out to GitHub and back: /auth/user/github and /auth/user/github/callback.
    auth_routes AuthController, Beerocracy.Accounts.User, path: "/auth"

    # Signing out is a DELETE rather than a link, so that somebody else's page
    # cannot sign you out by embedding an image.
    delete "/sign-out", AuthController, :sign_out
  end

  # The one thing behind the counter. Guarded twice: the pipeline stops the
  # request that would render it, and the `on_mount` stops a socket that
  # somehow got a token for it anyway.
  scope "/admin" do
    pipe_through [:browser, :require_admin]

    live_dashboard "/dashboard",
      metrics: BeerocracyWeb.Telemetry,
      on_mount: [{BeerocracyWeb.UserAuth, :require_admin}]
  end

  # Other scopes may use custom stacks.
  # scope "/api", BeerocracyWeb do
  #   pipe_through :api
  # end
end
