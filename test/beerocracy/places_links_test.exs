defmodule Beerocracy.PlacesLinksTest do
  # Not async: these swap the repository out from under the whole application,
  # and `Application.put_env/3` is global. Anything reading the catalogue links
  # concurrently would see the fork's URL instead of its own.
  use ExUnit.Case, async: false

  alias Beerocracy.Places

  describe "the GitHub links" do
    test "point at the catalogue on the configured branch" do
      assert Places.source_url() =~ ~r{^https://github\.com/[^/]+/[^/]+/blob/.+/priv/places\.yml$}
      assert Places.edit_url() =~ ~r{^https://github\.com/[^/]+/[^/]+/edit/.+/priv/places\.yml$}
    end

    test "follow the configured repository, so a fork links to itself" do
      with_repo("https://github.com/someone/fork", fn ->
        assert Places.source_url() == "https://github.com/someone/fork/blob/main/priv/places.yml"
        assert Places.edit_url() == "https://github.com/someone/fork/edit/main/priv/places.yml"
      end)
    end

    test "tolerate a trailing slash on the repository" do
      with_repo("https://github.com/someone/fork/", fn ->
        assert Places.source_url() == "https://github.com/someone/fork/blob/main/priv/places.yml"
      end)
    end

    test "are nil when no repository is configured, so no link is offered" do
      with_repo(nil, fn ->
        assert Places.source_url() == nil
        assert Places.edit_url() == nil
      end)
    end
  end

  defp with_repo(repo_url, fun) do
    previous = Application.get_env(:beerocracy, :repo_url)

    try do
      Application.put_env(:beerocracy, :repo_url, repo_url)
      fun.()
    after
      Application.put_env(:beerocracy, :repo_url, previous)
    end
  end
end
