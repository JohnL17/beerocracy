defmodule Beerocracy.Accounts.GitHubDirectory do
  @moduledoc """
  Who a GitHub handle belongs to, for people who have not signed in here yet.

  A GitHub account id is public and permanent, so votes can be filed under
  somebody before they have ever visited the sheet — which is what stops the
  migration from depending on the whole office logging in first.

  Only ever used by `mix beerocracy.migrate_voters`. The sheet itself learns
  people's ids the ordinary way, by their signing in.
  """

  @type account :: %{id: String.t(), login: String.t(), name: String.t() | nil}

  @doc "The account behind a handle, or an error naming what went wrong."
  @callback fetch(handle :: String.t()) :: {:ok, account()} | {:error, term()}

  @doc "Looks a handle up through whichever directory is configured."
  @spec fetch(String.t()) :: {:ok, account()} | {:error, term()}
  def fetch(handle), do: source().fetch(handle)

  defp source do
    Application.get_env(:beerocracy, :github, [])[:directory] || __MODULE__.PublicApi
  end
end
