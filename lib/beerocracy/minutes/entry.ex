defmodule Beerocracy.Minutes.Entry do
  @moduledoc """
  Where we actually went in one ISO week, as recorded by an admin.

  The ballot decides where we *said* we would go. This is the correction for
  every week where the plan and the evening parted company — the winning place
  turned out to be shut, six people walked past it and went next door, someone
  had a birthday. Without somewhere to write that down, the archive is a record
  of intentions, and "we were there two weeks ago" quietly stops being true.

  One entry per week, at most. Weeks without one fall back to the vote, which is
  the usual case and stays the default.
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
      constraints: [one_of: [:monday, :tuesday, :wednesday, :thursday, :friday]]

    attribute :recorded_by, :string,
      allow_nil?: false,
      public?: true,
      description: "The admin's display name, so the sheet can say whose word this is."

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_week, [:week_key]
  end

  actions do
    defaults [:read, :destroy]

    create :record do
      description "Write down where we went. Recording again corrects it rather than erroring."
      accept [:week_key, :place_slug, :weekday, :recorded_by]
      upsert? true
      upsert_identity :unique_week
      upsert_fields [:place_slug, :weekday, :recorded_by, :updated_at]
    end

    read :for_week do
      argument :week_key, :string, allow_nil?: false
      get? true
      filter expr(week_key == ^arg(:week_key))
    end
  end
end
