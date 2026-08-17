defmodule Beerocracy.Voting do
  @moduledoc """
  The ballot box. Everything the citizens of the Beerocracy commit to the
  database lives in here: which weekdays work for them, and which places they
  swiped right on.
  """

  use Ash.Domain, otp_app: :beerocracy

  resources do
    resource Beerocracy.Voting.DayVote do
      define :cast_day_vote, action: :cast
      define :day_votes_for_week, action: :for_week, args: [:week_key]
      define :retract_day_vote, action: :destroy
    end

    resource Beerocracy.Voting.PlaceVote do
      define :cast_place_vote, action: :cast
      define :place_votes_for_week, action: :for_week, args: [:week_key]
      define :all_place_votes, action: :read
      define :retract_place_vote, action: :destroy
    end
  end
end
