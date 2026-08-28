defmodule Beerocracy.GitHubDirectoryStub do
  @moduledoc """
  A GitHub directory for the tests. Never touches the network.

  Handles are answered from whatever the test put there; anything else is an
  account that does not exist, which is the case worth getting right.
  """

  @behaviour Beerocracy.Accounts.GitHubDirectory

  @key :github_directory_stub

  @doc "Make `handle` resolve to `id`, optionally with a real name."
  @spec knows(String.t(), integer() | String.t(), String.t() | nil) :: :ok
  def knows(handle, id, name \\ nil) do
    accounts = Map.get(Process.get(@key, %{}), :accounts, %{})

    Process.put(@key, %{
      accounts:
        Map.put(accounts, String.downcase(handle), %{
          id: to_string(id),
          login: handle,
          name: name
        })
    })

    :ok
  end

  @impl true
  def fetch(handle) do
    Process.get(@key, %{})
    |> Map.get(:accounts, %{})
    |> Map.fetch(String.downcase(handle))
    |> case do
      {:ok, account} -> {:ok, account}
      :error -> {:error, :no_such_account}
    end
  end
end
