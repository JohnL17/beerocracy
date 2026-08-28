defmodule Beerocracy.Voting.PlaceVote do
  @moduledoc """
  The outcome of one swipe: a voter's verdict on one place for one ISO week.

  Places themselves are not stored here — they live in `priv/places.yml` and are
  referenced by their slug, so the catalogue can grow through a pull request
  without a migration.
  """

  use Ash.Resource,
    otp_app: :beerocracy,
    domain: Beerocracy.Voting,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "place_votes"
    repo Beerocracy.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :week_key, :string, allow_nil?: false, public?: true
    attribute :voter_key, :string, allow_nil?: false, public?: true
    attribute :voter_name, :string, allow_nil?: false, public?: true
    attribute :place_slug, :string, allow_nil?: false, public?: true

    attribute :liked, :boolean,
      allow_nil?: false,
      public?: true,
      description: "true for a right swipe, false for a left swipe"

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_place_vote, [:week_key, :voter_key, :place_slug]
  end

  actions do
    defaults [:read, :destroy]

    create :cast do
      description "Record a swipe. Swiping the same place again overwrites the verdict."
      accept [:week_key, :voter_key, :voter_name, :place_slug, :liked]
      upsert? true
      upsert_identity :unique_place_vote
      upsert_fields [:liked, :voter_name, :updated_at]
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
