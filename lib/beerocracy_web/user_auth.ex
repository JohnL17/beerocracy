defmodule BeerocracyWeb.UserAuth do
  @moduledoc """
  Turns "who is signed in" into "what may they do".

  AshAuthentication does the signing in and leaves a `current_user` behind, on
  the connection and on the socket. Everything in the Beerocracy reads
  `current_scope` instead, which is that user plus the one thing the user
  resource cannot answer on its own: whether they are named in the admin list.
  """

  use BeerocracyWeb, :verified_routes

  import Phoenix.Component, only: [assign_new: 3]
  import Phoenix.Controller, only: [put_flash: 3, redirect: 2]
  import Plug.Conn, only: [assign: 3, halt: 1]

  alias AshAuthentication.Plug.Helpers
  alias Beerocracy.Accounts.Scope
  alias Beerocracy.Accounts.User

  @doc """
  Puts the current scope on the connection.

  Runs after `:load_from_session`, which is where `current_user` comes from.
  """
  @spec fetch_current_scope(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def fetch_current_scope(conn, _opts) do
    assign(conn, :current_scope, Scope.for_user(conn.assigns[:current_user]))
  end

  @doc """
  Turns away anybody who is not named in the admin list.

  Deliberately vague about why: an admin knows where the door is, and everybody
  else does not need to be told there is one.
  """
  @spec require_admin(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def require_admin(conn, _opts) do
    if conn.assigns.current_scope.admin? do
      conn
    else
      conn
      |> put_flash(:error, "That part of the sheet is not yours to read.")
      |> redirect(to: ~p"/")
      |> halt()
    end
  end

  @doc """
  The LiveView equivalents.

    * `:mount_current_scope` — assigns the scope and lets anybody through, which
      is what the ballot itself wants: the sheet is readable by strangers, they
      simply cannot mark it.
    * `:require_admin` — assigns it and turns away everybody else.
  """
  def on_mount(:mount_current_scope, _params, session, socket) do
    {:cont, mount_scope(socket, session)}
  end

  def on_mount(:require_admin, _params, session, socket) do
    socket = mount_scope(socket, session)

    if socket.assigns.current_scope.admin? do
      {:cont, socket}
    else
      {:halt,
       socket
       |> Phoenix.LiveView.put_flash(:error, "That part of the sheet is not yours to read.")
       |> Phoenix.LiveView.redirect(to: ~p"/")}
    end
  end

  defp mount_scope(socket, session) do
    socket
    |> assign_new(:current_user, fn -> user_from_session(session) end)
    |> then(
      &Phoenix.Component.assign(&1, :current_scope, Scope.for_user(&1.assigns.current_user))
    )
  end

  # Inside `ash_authentication_live_session` the user is already on the socket
  # and this never runs. The dashboard is not in that live session — it brings
  # its own — so there the session is all there is to go on.
  defp user_from_session(session) do
    case Helpers.authenticate_resource_from_session(User, session, :beerocracy, []) do
      {:ok, user} -> user
      _stranger -> nil
    end
  end
end
