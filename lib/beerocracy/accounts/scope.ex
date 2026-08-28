defmodule Beerocracy.Accounts.Scope do
  @moduledoc """
  Who the current request or LiveView belongs to, and what they may do.

  There is always a scope, even for somebody who has not signed in — the sheet
  is readable by anyone, so "signed out" is a state to render rather than a
  reason to redirect. `user` is `nil` for those, which is the one check the
  templates make.
  """

  alias Beerocracy.Accounts
  alias Beerocracy.Accounts.User

  defstruct user: nil, admin?: false

  @type t :: %__MODULE__{user: User.t() | nil, admin?: boolean()}

  @doc "The scope for a signed-in user, or the empty one for a stranger."
  @spec for_user(User.t() | nil) :: t()
  def for_user(%User{} = user), do: %__MODULE__{user: user, admin?: Accounts.admin?(user)}
  def for_user(nil), do: %__MODULE__{}

  @doc "Whether anybody is signed in at all."
  @spec signed_in?(t()) :: boolean()
  def signed_in?(%__MODULE__{user: user}), do: not is_nil(user)

  @doc "The key this scope's votes are filed under, or `nil` when signed out."
  @spec voter_key(t()) :: String.t() | nil
  def voter_key(%__MODULE__{user: nil}), do: nil
  def voter_key(%__MODULE__{user: user}), do: User.voter_key(user)

  @doc "The name the sheet shows for this scope, or `nil` when signed out."
  @spec voter_name(t()) :: String.t() | nil
  def voter_name(%__MODULE__{user: nil}), do: nil
  def voter_name(%__MODULE__{user: user}), do: user.display_name
end
