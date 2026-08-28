defmodule BeerocracyWeb.UserAuthTest do
  use BeerocracyWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  defp as_admin(context) do
    previous = Application.get_env(:beerocracy, :admins)
    Application.put_env(:beerocracy, :admins, ["anehx"])
    on_exit(fn -> Application.put_env(:beerocracy, :admins, previous || []) end)

    sign_in(context, login: "anehx", name: "Jonas")
  end

  describe "the admin dashboard" do
    test "turns a stranger away", %{conn: conn} do
      conn = get(conn, ~p"/admin/dashboard")

      assert redirected_to(conn) == ~p"/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "not yours to read"
    end

    test "turns away a voter who is not on the admin list", context do
      %{conn: conn} = sign_in(context, login: "somebody-else")

      assert redirected_to(get(conn, ~p"/admin/dashboard")) == ~p"/"
    end

    test "lets an admin in", context do
      %{conn: conn} = as_admin(context)

      # LiveDashboard sends the bare path on to its first page.
      conn = get(conn, ~p"/admin/dashboard")
      assert redirected_to(conn) == "/admin/dashboard/home"

      assert recycle(conn) |> get("/admin/dashboard/home") |> html_response(200) =~ "Dashboard"
    end
  end

  describe "the dashboard link on the sheet" do
    test "is shown to an admin", context do
      %{conn: conn} = as_admin(context)
      {:ok, view, _html} = live(conn, ~p"/")

      assert view |> element("a[href='/admin/dashboard']") |> has_element?()
    end

    test "is not shown to anybody else", context do
      %{conn: conn} = sign_in(context, login: "somebody-else")
      {:ok, view, _html} = live(conn, ~p"/")

      refute view |> element("a[href='/admin/dashboard']") |> has_element?()
    end

    test "is not shown to a stranger", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      refute view |> element("a[href='/admin/dashboard']") |> has_element?()
    end
  end

  describe "signing out" do
    test "empties the session and sends you back to the sheet", context do
      %{conn: conn} = sign_in(context, name: "Jonas")

      assert get(conn, ~p"/") |> html_response(200) =~ "Signed: Jonas"

      conn = delete(conn, ~p"/sign-out")
      assert redirected_to(conn) == ~p"/"

      refute get_session(conn, :user)
      refute recycle(conn) |> get(~p"/") |> html_response(200) =~ "Signed: Jonas"
    end
  end

  describe "the sign-in link" do
    test "points at the GitHub strategy", %{conn: conn} do
      assert get(conn, ~p"/") |> html_response(200) =~ ~s(href="/auth/user/github")
    end

    test "is gone once you are signed in", context do
      %{conn: conn} = sign_in(context, name: "Jonas")

      refute get(conn, ~p"/") |> html_response(200) =~ ~s(href="/auth/user/github")
    end
  end

  describe "a voter whose account has been deleted" do
    test "is treated as a stranger rather than an error", context do
      %{conn: conn, user: user} = sign_in(context, name: "Ghost")

      # The GitHub link points at the user row, so it goes first.
      Beerocracy.Accounts.UserIdentity |> Ash.read!() |> Enum.each(&Ash.destroy!/1)
      Ash.destroy!(user)

      html = get(conn, ~p"/") |> html_response(200)

      refute html =~ "Signed: Ghost"
      assert html =~ "Sign in with GitHub"
    end
  end
end
