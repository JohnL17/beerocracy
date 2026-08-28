defmodule Beerocracy.MigrateVotersTest do
  use Beerocracy.DataCase, async: false

  import ExUnit.CaptureIO

  alias Beerocracy.Accounts.User
  alias Beerocracy.AccountsFixtures
  alias Beerocracy.Ballot
  alias Beerocracy.Voting
  alias Beerocracy.Week

  @task Mix.Tasks.Beerocracy.MigrateVoters

  setup do
    week = Week.current()

    # Two votes cast back when a voter was just the name they typed.
    Ballot.set_day(week, "Jonas", "jonas", :thursday, :yes)
    Ballot.swipe(week, "Jonas", "jonas", "shamrock", true)

    %{week: week, user: AccountsFixtures.user(name: "Hanni", login: "anehx")}
  end

  defp run(args), do: capture_io(fn -> @task.run(args) end)

  defp keys do
    (Voting.all_day_votes!() ++ Voting.all_place_votes!())
    |> Enum.map(& &1.voter_key)
    |> Enum.uniq()
    |> Enum.sort()
  end

  describe "the report" do
    test "names the voters with no account behind them" do
      output = run([])

      assert output =~ "1 voter(s) with no account"
      assert output =~ "jonas"
      assert output =~ "2 votes"
    end

    test "is also reachable as --list" do
      output = run(["--list"])

      assert output =~ "1 voter(s) with no account"
      assert output =~ "jonas"
    end

    test "--list never migrates, even alongside a mapping" do
      run(["jonas=anehx", "--list", "--commit"])

      assert keys() == ["jonas"]
    end

    test "says so when there is nothing to do", %{week: week, user: user} do
      Ballot.set_day(week, "Hanni", User.voter_key(user), :monday, :yes)

      Enum.each(Voting.all_day_votes!(), fn vote ->
        if vote.voter_key == "jonas", do: Voting.retract_day_vote!(vote)
      end)

      Enum.each(Voting.all_place_votes!(), &Voting.retract_place_vote!/1)

      assert run([]) =~ "Every vote already belongs to an account"
    end
  end

  describe "without --commit" do
    test "writes nothing" do
      output = run(["jonas=anehx"])

      assert output =~ "Dry run"
      assert output =~ "2 vote(s) would be adopted"
      assert keys() == ["jonas"]
    end
  end

  describe "with --commit" do
    test "moves the votes onto the account", %{user: user} do
      run(["jonas=anehx", "--commit"])

      assert keys() == [User.voter_key(user)]
    end

    test "brings the display name along", %{user: user} do
      run(["jonas=anehx", "--commit"])

      assert Voting.all_day_votes!() |> hd() |> Map.fetch!(:voter_name) == "Hanni"
      assert Ballot.voter_state(Week.current(), User.voter_key(user)).days == %{thursday: :yes}
    end

    test "matches the handle whatever its case" do
      run(["jonas=ANEHX", "--commit"])

      refute "jonas" in keys()
    end
  end

  describe "when the same person voted under both schemes" do
    setup %{week: week, user: user} do
      # They signed in and voted on the same day again, as themselves.
      Ballot.set_day(week, "Hanni", User.voter_key(user), :thursday, :maybe)
      :ok
    end

    test "keeps the vote they cast as themselves", %{week: week, user: user} do
      run(["jonas=anehx", "--commit"])

      assert Ballot.voter_state(week, User.voter_key(user)).days == %{thursday: :maybe}
    end

    test "counts them once, not twice", %{week: week} do
      run(["jonas=anehx", "--commit"])

      day = week |> Ballot.tally() |> Map.fetch!(:days) |> Enum.find(&(&1.weekday == :thursday))

      assert day.count == 1
    end

    test "says what it dropped" do
      assert run(["jonas=anehx", "--commit"]) =~ "1 superseded and dropped"
    end
  end

  describe "refusing" do
    test "will not invent an account for somebody who has never signed in" do
      assert_raise Mix.Error, ~r/no account for: ghost/, fn ->
        run(["jonas=ghost", "--commit"])
      end
    end

    test "rejects an argument that is not a mapping" do
      assert_raise Mix.Error, ~r/expected old_key=github_handle/, fn ->
        run(["jonas", "--commit"])
      end
    end
  end
end
