defmodule Beerocracy.AccountsFixtures do
  @moduledoc """
  Voters, without the trip to GitHub.

  Calls the same registration action the GitHub strategy calls, so a fixture
  user is the real thing — including the token `store_in_session/2` needs.
  """

  alias Beerocracy.Accounts.User

  @doc """
  A signed-up voter.

  Takes `:name` (what the sheet will call them), `:login` (their GitHub handle,
  which is what the admin list is matched against) and `:github_id`. Anything
  left out is generated, so two fixtures are never the same person by accident.
  """
  @spec user(keyword()) :: User.t()
  def user(attrs \\ []) do
    unique = System.unique_integer([:positive])
    login = Keyword.get(attrs, :login, "voter-#{unique}")

    # Exactly what `Assent.Strategy.Github.normalize/2` produces — the raw
    # GitHub body never reaches the action, and a fixture shaped like one only
    # proves the tests and the bug agree.
    user_info = %{
      "sub" => attrs |> Keyword.get(:github_id, unique) |> to_string(),
      "preferred_username" => login,
      "name" => Keyword.get(attrs, :name),
      "email" => Keyword.get(attrs, :email),
      "email_verified" => Keyword.get(attrs, :email_verified, false),
      "picture" => "https://avatars.githubusercontent.com/u/#{unique}?v=4",
      "profile" => "https://github.com/#{login}"
    }

    Ash.create!(User, %{user_info: user_info, oauth_tokens: %{}},
      action: :register_with_github,
      authorize?: false
    )
  end
end
