defmodule Beerocracy.Accounts.Token do
  @moduledoc """
  The tokens AshAuthentication issues, and the ones it has since torn up.

  Nothing in the Beerocracy reads this table directly — it exists so that
  signing out actually revokes something, rather than politely asking the
  browser to forget.
  """

  use Ash.Resource,
    otp_app: :beerocracy,
    domain: Beerocracy.Accounts,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshAuthentication.TokenResource]

  sqlite do
    table "tokens"
    repo Beerocracy.Repo
  end
end
