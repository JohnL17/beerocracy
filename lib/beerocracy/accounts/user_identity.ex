defmodule Beerocracy.Accounts.UserIdentity do
  @moduledoc """
  The link between an account here and the GitHub account behind it.

  This is what makes a returning voter the same person as last week: they are
  matched on the issuer and subject GitHub reports, never on a name or an email,
  either of which they are free to change on GitHub without becoming somebody
  else. The extension defines every attribute.
  """

  use Ash.Resource,
    otp_app: :beerocracy,
    domain: Beerocracy.Accounts,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshAuthentication.UserIdentity]

  user_identity do
    user_resource Beerocracy.Accounts.User
  end

  sqlite do
    table "user_identities"
    repo Beerocracy.Repo
  end
end
