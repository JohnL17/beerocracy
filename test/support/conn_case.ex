defmodule BeerocracyWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use BeerocracyWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint BeerocracyWeb.Endpoint

      use BeerocracyWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import BeerocracyWeb.ConnCase
      import Beerocracy.DataCase, only: [pin_today: 1]
    end
  end

  setup tags do
    Beerocracy.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Signs a voter in the way the GitHub round trip would, minus the round trip.

  Takes the same options as `Beerocracy.AccountsFixtures.user/1`, and returns
  `%{conn: conn, user: user}` so it can be used as a `setup` or called inline.
  """
  def sign_in(%{conn: conn} = context, attrs \\ []) do
    user = Beerocracy.AccountsFixtures.user(attrs)

    Map.merge(context, %{conn: sign_in_as(conn, user), user: user})
  end

  @doc """
  Puts an existing voter into a connection's session.

  Two connections signed in as the same user are the same person on two
  devices, which is the only way to test that the sheet remembers them.
  """
  def sign_in_as(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end
end
