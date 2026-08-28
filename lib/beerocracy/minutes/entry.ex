defmodule Beerocracy.Minutes.Entry do
  @moduledoc """
  Where we actually went in one ISO week, as recorded by an admin.

  The ballot decides where we *said* we would go. This is the correction for
  every week where the plan and the evening parted company — the winning place
  turned out to be shut, six people walked past it and went next door, someone
  had a birthday. Without somewhere to write that down, the archive is a record
  of intentions, and "we were there two weeks ago" quietly stops being true.

  One entry per place per night. A week can hold several — an evening that moved
  on after the first round is two entries on the same weekday, and a week that
  went out twice is two entries on different ones. Weeks without any fall back
  to the vote, which is the usual case and stays the default.
  """

  use Ash.Resource,
    otp_app: :beerocracy,
    domain: Beerocracy.Minutes,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "minute_entries"
    repo Beerocracy.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :week_key, :string, allow_nil?: false, public?: true

    attribute :place_slug, :string,
      allow_nil?: false,
      public?: true,
      description: "Referenced by slug, like a vote — the catalogue is not in the database."

    attribute :weekday, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:monday, :tuesday, :wednesday, :thursday, :friday, :saturday]]

    attribute :recorded_by, :string,
      allow_nil?: false,
      public?: true,
      description: "The admin's display name, so the sheet can say whose word this is."

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    # A night is identified by where and when, so writing the same stop down
    # twice corrects it instead of doubling it — but a second pub on the same
    # evening, or the same pub on another evening, is a separate entry.
    identity :unique_visit, [:week_key, :weekday, :place_slug]
  end

  actions do
    defaults [:read, :destroy]

    create :record do
      description "Write down one stop. Writing the same one down again is not a second round."
      accept [:week_key, :place_slug, :weekday, :recorded_by]
      upsert? true
      upsert_identity :unique_visit
      upsert_fields [:recorded_by, :updated_at]
    end

    read :for_week do
      description "Every stop written down for one week, oldest first."
      argument :week_key, :string, allow_nil?: false
      filter expr(week_key == ^arg(:week_key))
      prepare build(sort: [inserted_at: :asc])
    end
  end
end
