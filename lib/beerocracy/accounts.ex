defmodule Beerocracy.Accounts do
  @moduledoc """
  Who is holding the pen.

  GitHub says who you are; this module decides what the sheet calls you and
  whether you are allowed to look behind the counter. Signing in is deliberately
  open — anybody with a GitHub account can vote — because the point of the login
  was never to keep people out, it was to stop two Jonases from overwriting each
  other's Thursday.
  """

  use Ash.Domain, otp_app: :beerocracy

  alias Beerocracy.Accounts.User

  resources do
    resource Beerocracy.Accounts.User do
      define :get_user_by_github_id, action: :by_github_id, args: [:github_id]
      define :list_users, action: :read
      define :rename_user, action: :rename, args: [:display_name]
    end

    resource Beerocracy.Accounts.Token
    resource Beerocracy.Accounts.UserIdentity
  end

  @name_limit 40

  @doc """
  Changes what the sheet calls somebody.

  Nothing is keyed on the display name, so this is a cosmetic change by design —
  every vote they have ever cast stays theirs. Names still have to be distinct,
  because a tally reading "Jonas, Jonas, Jonas" helps nobody.
  """
  @spec rename(User.t(), String.t() | nil) ::
          {:ok, User.t()} | {:error, :blank | :too_long | :taken}
  def rename(%User{} = user, display_name) do
    name = tidy(display_name)

    cond do
      name == "" -> {:error, :blank}
      String.length(name) > @name_limit -> {:error, :too_long}
      taken?(name, user) -> {:error, :taken}
      true -> rename_user(user, name)
    end
  end

  @doc "The longest a display name may be."
  @spec name_limit() :: pos_integer()
  def name_limit, do: @name_limit

  @doc """
  A display name for somebody arriving from GitHub for the first time.

  GitHub's `name` is the friendlier of the two it offers and is blank more often
  than you would think, so the handle is the fallback. Either may already be
  spoken for by somebody else, in which case we fall through rather than hand
  two people the same name — the handle is unique on GitHub, so the last resort
  always lands.

  Takes Assent's normalised profile, where the handle is `preferred_username`.
  Only ever consulted on the first sign-in; see `register_with_github`.
  """
  @spec available_name(map()) :: String.t()
  def available_name(user_info) do
    login = user_info["preferred_username"]
    proposed = user_info["name"] |> tidy() |> String.slice(0, @name_limit)
    taken = MapSet.new(list_users!(), &normalise_name(&1.display_name))

    Enum.find(
      [proposed, login],
      login,
      &(&1 not in [nil, ""] and not MapSet.member?(taken, normalise_name(&1)))
    )
  end

  @doc """
  Collapses a display name into the form two names are compared by.

  Case and stray whitespace are not a difference worth having an argument
  about — "Jonas" and "jonas " are the same person twice.
  """
  @spec normalise_name(String.t()) :: String.t()
  def normalise_name(name) do
    name |> tidy() |> String.downcase()
  end

  @doc """
  The GitHub handles that may look behind the counter.

  Configured rather than stored, so promoting somebody is a restart and not a
  database edit — and so an empty environment means an app with no admins at
  all rather than one with an accidental one.
  """
  @spec admins() :: [String.t()]
  def admins do
    :beerocracy
    |> Application.get_env(:admins, [])
    |> List.wrap()
    |> Enum.map(&String.downcase/1)
  end

  @doc "Whether this person is named in the admin list. Matched on their handle."
  @spec admin?(User.t() | nil) :: boolean()
  def admin?(%User{github_login: login}) when is_binary(login) do
    String.downcase(login) in admins()
  end

  def admin?(_nobody), do: false

  defp taken?(name, %User{id: id}) do
    normalised = normalise_name(name)

    Enum.any?(
      list_users!(),
      &(&1.id != id and normalise_name(&1.display_name) == normalised)
    )
  end

  defp tidy(nil), do: ""

  defp tidy(name) do
    name |> String.trim() |> String.replace(~r/\s+/u, " ")
  end
end
