defmodule Mom.HarnessRepoTest do
  use ExUnit.Case, async: true

  alias Mom.HarnessRepo

  test "confirm_and_record stores private harness repo metadata" do
    record_path = unique_record_path()

    fake_runner = fn
      "gh",
      ["repo", "view", "acme/harness", "--json", "nameWithOwner,isPrivate,url,visibility"] ->
        {:ok,
         ~s({"nameWithOwner":"acme/harness","isPrivate":true,"url":"https://github.com/acme/harness","visibility":"PRIVATE"})}
    end

    assert {:ok, record} =
             HarnessRepo.confirm_and_record("acme/harness", record_path,
               cmd_runner: fake_runner,
               recorded_at: "2026-02-19T00:00:00Z"
             )

    assert record.name_with_owner == "acme/harness"
    assert record.is_private
    assert record.visibility == "PRIVATE"
    assert File.exists?(record_path)

    assert {:ok, loaded} = HarnessRepo.load_record(record_path)
    assert loaded.name_with_owner == "acme/harness"
  end

  test "confirm_and_record rejects non-private harness repo" do
    record_path = unique_record_path()

    fake_runner = fn
      "gh",
      ["repo", "view", "acme/harness", "--json", "nameWithOwner,isPrivate,url,visibility"] ->
        {:ok,
         ~s({"nameWithOwner":"acme/harness","isPrivate":false,"url":"https://github.com/acme/harness","visibility":"PUBLIC"})}
    end

    assert {:error, "harness repository must be private"} =
             HarnessRepo.confirm_and_record("acme/harness", record_path, cmd_runner: fake_runner)
  end

  test "load_record validates required fields" do
    record_path = unique_record_path()
    File.write!(record_path, ~s({"name_with_owner":"acme/harness","is_private":true}))

    assert {:error, "harness record is missing required field: url"} =
             HarnessRepo.load_record(record_path)
  end

  defp unique_record_path do
    Path.join(System.tmp_dir!(), "mom-harness-record-#{System.unique_integer([:positive])}.json")
  end
end
