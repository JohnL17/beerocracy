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
      define :all_day_votes, action: :read
      define :rename_day_voter, action: :rename_voter, args: [:voter_name]
      define :reassign_day_vote, action: :reassign
      define :retract_day_vote, action: :destroy
    end

    resource Beerocracy.Voting.PlaceVote do
      define :cast_place_vote, action: :cast
      define :place_votes_for_week, action: :for_week, args: [:week_key]
      define :all_place_votes, action: :read
      define :rename_place_voter, action: :rename_voter, args: [:voter_name]
      define :reassign_place_vote, action: :reassign
      define :retract_place_vote, action: :destroy
    end
  end
end
