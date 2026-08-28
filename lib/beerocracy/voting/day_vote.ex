defmodule Beerocracy.Voting.DayVote do
  @moduledoc """
  One voter saying "this weekday works for me" in a given ISO week.

  A voter may approve several days — the day with the most approvals wins.
  Un-approving a day destroys the row, so an empty tally really is empty.
  """

  use Ash.Resource,
    otp_app: :beerocracy,
    domain: Beerocracy.Voting,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "day_votes"
    repo Beerocracy.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :week_key, :string, allow_nil?: false, public?: true
    attribute :voter_key, :string, allow_nil?: false, public?: true
    attribute :voter_name, :string, allow_nil?: false, public?: true

    attribute :weekday, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:monday, :tuesday, :wednesday, :thursday, :friday]]

    attribute :stance, :atom,
      allow_nil?: false,
      public?: true,
      default: :yes,
      constraints: [one_of: [:yes, :maybe]],
      description: "a maybe still counts towards the day; it is just held less firmly"

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_day_vote, [:week_key, :voter_key, :weekday]
  end

  actions do
    defaults [:read, :destroy]

    create :cast do
      description "Record a stance on a weekday. Casting again changes it rather than erroring."
      accept [:week_key, :voter_key, :voter_name, :weekday, :stance]
      upsert? true
      upsert_identity :unique_day_vote
      upsert_fields [:stance, :voter_name, :updated_at]
    end

    update :rename_voter do
      description "Rewrite the display name copied onto this row when its owner renames themselves."
      accept [:voter_name]
    end

    update :reassign do
      description """
      Move this vote to a different voter key.

      For adopting votes cast before their owner had an account to file them
      under; see `mix beerocracy.migrate_voters`. Not something the ballot ever
      does on its own — a vote changing hands is an administrative act.
      """

      accept [:voter_key, :voter_name]
    end

    read :for_week do
      argument :week_key, :string, allow_nil?: false
      filter expr(week_key == ^arg(:week_key))
    end
  end
end
