defmodule Beerocracy.Secrets do
  @moduledoc """
  Where AshAuthentication goes for the things that must not be compiled in.

  Everything is read from the application environment, which `config/runtime.exs`
  fills from the environment variables at boot — so the same release runs against
  a development GitHub application and a production one without a rebuild.
  """

  use AshAuthentication.Secret

  alias Beerocracy.Accounts.User

  def secret_for([:authentication, :strategies, :github, :client_id], User, _opts, _context) do
    github(:client_id)
  end

  def secret_for([:authentication, :strategies, :github, :client_secret], User, _opts, _context) do
    github(:client_secret)
  end

  def secret_for([:authentication, :strategies, :github, :redirect_uri], User, _opts, _context) do
    github(:redirect_uri)
  end

  def secret_for([:authentication, :tokens, :signing_secret], User, _opts, _context) do
    Application.fetch_env(:beerocracy, :token_signing_secret)
  end

  defp github(key) do
    :beerocracy
    |> Application.get_env(:github, [])
    |> Keyword.fetch(key)
  end
end
