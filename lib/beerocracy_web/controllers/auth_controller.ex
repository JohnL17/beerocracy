defmodule BeerocracyWeb.AuthController do
  @moduledoc """
  The door: where AshAuthentication hands back whoever GitHub just vouched for.

  There is only one strategy and it has no failure the visitor can act on, so
  both endings lead back to the sheet — one signed in, one with an apology.
  """

  use BeerocracyWeb, :controller
  use AshAuthentication.Phoenix.Controller

  require Logger

  def success(conn, _activity, user, _token) do
    conn
    |> store_in_session(user)
    |> assign(:current_user, user)
    |> put_flash(:info, "Signed in as #{user.display_name}.")
    |> redirect(to: ~p"/")
  end

  def failure(conn, activity, reason) do
    # The visitor gets the same apology whatever went wrong, so this log line is
    # the only place the actual cause is ever recorded. Without it a refused
    # sign-in is indistinguishable from a mistyped secret.
    Logger.error("""
    Sign-in failed during #{inspect(activity)}:

    #{inspect(reason, pretty: true, limit: :infinity, printable_limit: :infinity)}
    """)

    conn
    |> put_flash(:error, "GitHub would not confirm who you are. Nothing has changed.")
    |> redirect(to: ~p"/")
  end

  def sign_out(conn, _params) do
    conn
    |> clear_session(:beerocracy)
    |> put_flash(:info, "Signed out. Your votes stay on the sheet.")
    |> redirect(to: ~p"/")
  end
end
