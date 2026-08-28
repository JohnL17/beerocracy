defmodule Beerocracy.Accounts.GitHubDirectory.PublicApi do
  @moduledoc """
  The real GitHub, over its public user endpoint.

  Unauthenticated on purpose: this asks only for what any browser can see, and
  the sixty requests an hour that buys is far more than a one-off migration of
  an office needs.
  """

  @behaviour Beerocracy.Accounts.GitHubDirectory

  @impl true
  def fetch(handle) do
    "https://api.github.com/users/#{URI.encode_www_form(handle)}"
    |> Req.get(
      headers: [accept: "application/vnd.github+json"],
      receive_timeout: 10_000
    )
    |> case do
      {:ok, %{status: 200, body: %{"id" => id, "login" => login} = body}} ->
        {:ok, %{id: to_string(id), login: login, name: body["name"]}}

      {:ok, %{status: 404}} ->
        {:error, :no_such_account}

      {:ok, %{status: status}} ->
        {:error, {:status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
