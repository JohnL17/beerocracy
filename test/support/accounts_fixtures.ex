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
    login = Keyword.get(attrs, :login) || default_login(Keyword.get(attrs, :name), unique)

    # Derived from the handle rather than generated, so the same voter is dealt
    # the same deck on every run — the shuffle is seeded on the voter key, and a
    # random one would make any test that names a card flake.
    github_id = attrs |> Keyword.get(:github_id, :erlang.phash2(login)) |> to_string()

    # Exactly what `Assent.Strategy.Github.normalize/2` produces — the raw
    # GitHub body never reaches the action, and a fixture shaped like one only
    # proves the tests and the bug agree.
    user_info = %{
      "sub" => github_id,
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

  # A voter asked for by name gets a handle made from it, so "Jonas" is the same
  # person in every test that mentions him.
  defp default_login(nil, unique), do: "voter-#{unique}"

  defp default_login(name, _unique) do
    name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-")
  end
end
