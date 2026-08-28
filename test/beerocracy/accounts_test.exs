defmodule Beerocracy.AccountsTest do
  use Beerocracy.DataCase, async: false

  alias Beerocracy.Accounts
  alias Beerocracy.Accounts.User
  alias Beerocracy.AccountsFixtures

  describe "arriving from GitHub" do
    test "takes the display name from the GitHub profile name" do
      user = AccountsFixtures.user(name: "Jonas Metzener", login: "anehx")

      assert user.display_name == "Jonas Metzener"
      assert user.github_login == "anehx"
    end

    test "falls back to the handle when the profile has no name" do
      assert AccountsFixtures.user(name: nil, login: "anehx").display_name == "anehx"
    end

    test "does not hand two people the same name" do
      AccountsFixtures.user(name: "Jonas", login: "first")
      second = AccountsFixtures.user(name: "Jonas", login: "second")

      assert second.display_name == "second"
    end

    test "signing in again keeps the chosen name and refreshes the handle" do
      user = AccountsFixtures.user(name: "Jonas", login: "anehx", github_id: 7)
      {:ok, renamed} = Accounts.rename(user, "Hanni")

      again = AccountsFixtures.user(name: "Jonas Metzener", login: "renamed", github_id: 7)

      assert again.id == renamed.id
      assert again.display_name == "Hanni"
      assert again.github_login == "renamed"
    end

    test "reads the profile Assent normalises, not GitHub's raw body" do
      # The raw /user body has "id" and "login"; what actually arrives has "sub"
      # and "preferred_username". Reading the wrong pair is not a near miss — it
      # leaves both attributes nil, which is the whole of this failure.
      raw_github_body = %{"id" => 1234, "login" => "anehx", "name" => "Jonas"}

      assert {:error, _} =
               Ash.create(
                 User,
                 %{user_info: raw_github_body, oauth_tokens: %{}},
                 action: :register_with_github,
                 authorize?: false
               )
    end

    test "keys votes on the GitHub id, not on anything the person can change" do
      user = AccountsFixtures.user(name: "Jonas", login: "anehx", github_id: 7)
      {:ok, renamed} = Accounts.rename(user, "Hanni")

      assert User.voter_key(renamed) == "gh:7"
    end
  end

  describe "rename/2" do
    setup do
      %{user: AccountsFixtures.user(name: "Jonas")}
    end

    test "collapses whitespace", %{user: user} do
      assert {:ok, renamed} = Accounts.rename(user, "  Ada   Lovelace ")
      assert renamed.display_name == "Ada Lovelace"
    end

    test "refuses a blank name", %{user: user} do
      assert Accounts.rename(user, "   ") == {:error, :blank}
      assert Accounts.rename(user, nil) == {:error, :blank}
    end

    test "refuses a name that is too long", %{user: user} do
      assert Accounts.rename(user, String.duplicate("a", Accounts.name_limit() + 1)) ==
               {:error, :too_long}
    end

    test "refuses a name somebody else already goes by, whatever the case", %{user: user} do
      AccountsFixtures.user(name: "Mira")

      assert Accounts.rename(user, " MIRA ") == {:error, :taken}
    end

    test "lets you keep your own name", %{user: user} do
      assert {:ok, _} = Accounts.rename(user, "jonas")
    end
  end

  describe "admin?/1" do
    setup do
      previous = Application.get_env(:beerocracy, :admins)
      Application.put_env(:beerocracy, :admins, ["Anehx"])
      on_exit(fn -> Application.put_env(:beerocracy, :admins, previous || []) end)
    end

    test "matches the GitHub handle, ignoring case" do
      assert Accounts.admin?(AccountsFixtures.user(login: "anehx"))
      assert Accounts.admin?(AccountsFixtures.user(login: "ANEHX"))
    end

    test "is not fooled by a display name" do
      user = AccountsFixtures.user(name: "anehx", login: "somebody-else")

      refute Accounts.admin?(user)
    end

    test "nobody is an admin when nobody is listed" do
      Application.put_env(:beerocracy, :admins, [])

      refute Accounts.admin?(AccountsFixtures.user(login: "anehx"))
    end

    test "a stranger is not an admin" do
      refute Accounts.admin?(nil)
    end
  end
end
